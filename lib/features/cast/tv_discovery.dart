import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../discovery/data/subnet_detector.dart';
import '../discovery/data/parallel.dart';
import 'receiver_service.dart';

class TVDevice {
  final String ip;
  final String type; // 'webos', 'tizen' or 'flux_app'
  final String name;

  TVDevice({required this.ip, required this.type, required this.name});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TVDevice &&
          runtimeType == other.runtimeType &&
          ip == other.ip &&
          type == other.type;

  @override
  int get hashCode => ip.hashCode ^ type.hashCode;
}

final tvDiscoveryProvider =
    NotifierProvider<TVDiscoveryNotifier, List<TVDevice>>(() {
      return TVDiscoveryNotifier();
    });

class TVDiscoveryNotifier extends Notifier<List<TVDevice>> {
  @override
  List<TVDevice> build() {
    ref.onDispose(stopDiscovery);
    return [];
  }

  bool _active = false;
  bool _scanning = false;
  RawDatagramSocket? _udpSocket;

  /// IPs locales del dispositivo (todas las interfaces), para excluirlas de
  /// los resultados y no detectarnos a nosotros mismos.
  final _localIps = <String>{};

  void startDiscovery() {
    _active = true;
    _scan();
  }

  void stopDiscovery() {
    _active = false;
    _udpSocket?.close();
    _udpSocket = null;
  }

  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      // Averiguar nuestras propias IPs para no detectarnos a nosotros mismos.
      await _detectLocalIps();

      final subnet = await SubnetDetector().preferred();
      if (subnet == null || !_active) return;

      // También añadir la IP local de la subred preferida por si no estaba.
      _localIps.add(subnet.localIp);

      final hosts = subnet
          .hosts()
          .where((h) => !_localIps.contains(h))
          .toList();

      // 1. UDP Broadcast para Android TVs (Flux Receivers)
      await _discoverAndroidTVs();

      // 2. TCP: detectar otros Flux vía HTTP /info (puerto 8080)
      final receivers = _discoverFluxReceivers(hosts);

      // 3. TCP Port Scan para webOS (puerto 3000 SSAP) y Tizen (puerto 8001/8002 MSF)
      await Future.wait([receivers, _discoverSmartTVs(hosts)]);
    } finally {
      _scanning = false;
    }
  }

  /// Obtiene las IPs locales del dispositivo para filtrar auto-detección.
  Future<void> _detectLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      _localIps.clear();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          _localIps.add(addr.address);
        }
      }
    } catch (e) {
      debugPrint('[Flux] Error detectando IPs locales: $e');
    }
  }

  Future<void> _discoverAndroidTVs() async {
    try {
      if (_udpSocket == null) {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        if (!_active) {
          _udpSocket!.close();
          _udpSocket = null;
          return;
        }
        _udpSocket!.broadcastEnabled = true;
        _udpSocket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg = _udpSocket!.receive();
            if (dg != null) {
              final msg = utf8.decode(dg.data);
              if (msg.startsWith('FLUX_RECEIVER:')) {
                final parts = msg.split(':');
                // parts[0] = FLUX_RECEIVER
                // parts[1] = port (8080)
                // parts[2] = OS (optional)
                // parts[3] = instanceId (optional)
                String os = parts.length > 2 ? parts[2] : '';
                String instanceId = parts.length > 3 ? parts[3] : '';

                // Evitar agregarnos a nosotros mismos — por instanceId y por IP.
                if (instanceId == appInstanceId) return;
                if (_localIps.contains(dg.address.address)) return;

                String deviceName = 'Flux App';
                if (os.isNotEmpty) {
                  // Capitalize OS name
                  os = os[0].toUpperCase() + os.substring(1);
                  deviceName = 'Flux ($os)';
                } else {
                  deviceName = 'Flux TV Box';
                }

                _addDevice(
                  TVDevice(
                    ip: dg.address.address,
                    type: 'flux_app',
                    name: deviceName,
                  ),
                );
              }
            }
          }
        });
      }

      // Enviar a todos los puertos UDP posibles del rango del receiver,
      // ya que el otro Flux podría estar en cualquiera de ellos.
      final msg = utf8.encode('FLUX_DISCOVER');
      for (
        var port = CastReceiverService.udpPortStart;
        port <= CastReceiverService.udpPortEnd;
        port++
      ) {
        _udpSocket!.send(msg, InternetAddress('255.255.255.255'), port);
      }
    } catch (e) {
      debugPrint('[Flux] Error en UDP discovery: $e');
    }
  }

  /// Descubre Flux receivers vía TCP: consulta GET /info en el puerto 8080.
  /// Esto funciona incluso cuando el UDP falló por conflicto de puertos.
  Future<void> _discoverFluxReceivers(List<String> hosts) async {
    final gate = Semaphore(32);

    await Future.wait([
      for (final host in hosts)
        gate.run(() async {
          if (!_active) return;
          final client = HttpClient()
            ..connectionTimeout = const Duration(milliseconds: 500);
          try {
            final request = await client.getUrl(
              Uri.parse('http://$host:8080/info'),
            );
            final response = await request.close().timeout(
              const Duration(seconds: 2),
            );
            if (response.statusCode == 200) {
              final body = await response
                  .transform(utf8.decoder)
                  .join()
                  .timeout(const Duration(seconds: 2));
              try {
                final data = jsonDecode(body);
                if (data is Map &&
                    data['app'] == 'Flux' &&
                    data['type'] == 'receiver') {
                  // Verificar que no somos nosotros mismos.
                  final remoteId = data['instanceId'] as String? ?? '';
                  if (remoteId == appInstanceId) return;

                  final os = data['os'] as String? ?? '';
                  String deviceName;
                  if (os.isNotEmpty) {
                    final capitalized = os[0].toUpperCase() + os.substring(1);
                    deviceName = 'Flux ($capitalized)';
                  } else {
                    deviceName = 'Flux TV Box';
                  }

                  _addDevice(
                    TVDevice(ip: host, type: 'flux_app', name: deviceName),
                  );
                }
              } catch (_) {
                // Respuesta no es JSON válido — ignorar.
              }
            }
          } on Object {
            // Puerto cerrado, timeout o error de red — continuar.
          } finally {
            client.close(force: true);
          }
        }),
    ]);
  }

  Future<void> _discoverSmartTVs(List<String> hosts) async {
    final gate = Semaphore(32);
    final ports = [3000, 8001, 8002];

    await Future.wait([
      for (final host in hosts)
        gate.run(() async {
          if (!_active) return;
          for (final port in ports) {
            try {
              final socket = await Socket.connect(
                host,
                port,
                timeout: const Duration(milliseconds: 400),
              );
              socket.destroy();

              if (port == 3000) {
                _addDevice(
                  TVDevice(ip: host, type: 'webos', name: 'LG webOS TV'),
                );
                break;
              } else {
                // Tizen MSF API (8001/8002)
                final client = HttpClient()
                  ..connectionTimeout = const Duration(seconds: 2);
                try {
                  final protocol = port == 8002 ? 'https' : 'http';
                  client.badCertificateCallback = (cert, h, p) => true;
                  final request = await client.getUrl(
                    Uri.parse('$protocol://$host:$port/api/v2/'),
                  );
                  final response = await request.close().timeout(
                    const Duration(seconds: 2),
                  );
                  if (response.statusCode == 200) {
                    final body = await response
                        .transform(utf8.decoder)
                        .join()
                        .timeout(const Duration(seconds: 2));
                    final data = jsonDecode(body);
                    final name = data['device']?['name'] ?? 'Samsung Tizen TV';
                    _addDevice(TVDevice(ip: host, type: 'tizen', name: name));
                    break;
                  }
                } catch (_) {
                  // Fallback if API fails but port is open
                  _addDevice(
                    TVDevice(ip: host, type: 'tizen', name: 'Samsung Tizen TV'),
                  );
                  break;
                } finally {
                  client.close(force: true);
                }
              }
            } on Object {
              // Port closed or unreachable, continue
            }
          }
        }),
    ]);
  }

  void _addDevice(TVDevice device) {
    if (_active && ref.mounted && !state.contains(device)) {
      state = [...state, device];
    }
  }
}
