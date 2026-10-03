import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final String appInstanceId = DateTime.now().millisecondsSinceEpoch.toString();

final castReceiverProvider = Provider<CastReceiverService>((ref) {
  return CastReceiverService();
});

class CastReceiverService {
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Function(String host, int port, {String? url, Map<String, String>? headers})? onPlayCommand;

  /// Rango de puertos UDP a intentar para discovery. Si el primero está
  /// ocupado (otra instancia de Flux en la misma máquina, o test local)
  /// probamos los siguientes para que al menos el HTTP /info siga disponible.
  static const udpPortStart = 8081;
  static const udpPortEnd = 8089;

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      debugPrint('[Flux] CastReceiverService escuchando en puerto ${_server!.port}');
      
      _server!.listen((HttpRequest request) async {
        // Soporte básico CORS
        if (request.method == 'OPTIONS') {
           request.response
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..headers.add('Access-Control-Allow-Methods', 'POST, OPTIONS')
            ..headers.add('Access-Control-Allow-Headers', 'Content-Type')
            ..statusCode = HttpStatus.ok;
           await request.response.close();
           return;
        }

        if (request.method == 'POST' && request.uri.path == '/launch') {
          final content = await utf8.decoder.bind(request).join();
          try {
            final data = jsonDecode(content);
            final host = data['host'] as String?;
            final port = data['port'] as int?;
            final url = data['url'] as String?;
            
            Map<String, String>? headers;
            if (data['headers'] != null) {
              headers = Map<String, String>.from(data['headers']);
            }
            
            if (host != null && port != null && onPlayCommand != null) {
              onPlayCommand!(host, port, url: url, headers: headers);
              request.response
                ..headers.add('Access-Control-Allow-Origin', '*')
                ..statusCode = HttpStatus.ok
                ..write('{"status": "ok"}');
            } else {
              request.response
                ..headers.add('Access-Control-Allow-Origin', '*')
                ..statusCode = HttpStatus.badRequest
                ..write('{"error": "invalid payload"}');
            }
          } catch (e) {
            request.response
              ..headers.add('Access-Control-Allow-Origin', '*')
              ..statusCode = HttpStatus.internalServerError
              ..write('{"error": "failed to parse JSON"}');
          }
        } else if (request.method == 'GET' && request.uri.path == '/info') {
           // Endpoint para descubrimiento — incluye instanceId para que el
           // discovery TCP pueda filtrar auto-detección.
           final info = jsonEncode({
             'app': 'Flux',
             'type': 'receiver',
             'os': Platform.operatingSystem,
             'instanceId': appInstanceId,
           });
           request.response
              ..headers.add('Access-Control-Allow-Origin', '*')
              ..headers.contentType = ContentType.json
              ..statusCode = HttpStatus.ok
              ..write(info);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found');
        }
        await request.response.close();
      });
    } catch (e) {
      debugPrint('[Flux] Error al iniciar servidor HTTP para Cast: $e');
    }

    // Intentar bind UDP en varios puertos para tolerar que otro Flux ya
    // tenga tomado el primero.
    for (var port = udpPortStart; port <= udpPortEnd; port++) {
      try {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
        _udpSocket!.broadcastEnabled = true;
        _udpSocket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg = _udpSocket!.receive();
            if (dg != null) {
              final msg = utf8.decode(dg.data);
              if (msg == 'FLUX_DISCOVER') {
                // Responder al emisor que somos un receptor Flux (incluyendo OS e instanceId)
                final reply = utf8.encode('FLUX_RECEIVER:${_server?.port ?? 8080}:${Platform.operatingSystem}:$appInstanceId');
                _udpSocket!.send(reply, dg.address, dg.port);
              }
            }
          }
        });
        debugPrint('[Flux] CastReceiverService escuchando UDP discovery en puerto $port');
        break; // Éxito — no probar más puertos.
      } catch (e) {
        debugPrint('[Flux] Puerto UDP $port ocupado, intentando siguiente... ($e)');
        if (port == udpPortEnd) {
          debugPrint('[Flux] No se pudo iniciar UDP discovery en ningún puerto '
              '($udpPortStart-$udpPortEnd). El descubrimiento TCP /info sigue activo.');
        }
      }
    }
  }

  void stop() {
    _server?.close(force: true);
    _udpSocket?.close();
  }
}
