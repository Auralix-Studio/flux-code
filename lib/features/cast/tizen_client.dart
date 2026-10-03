import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Cliente minimalista para Tizen MSF (MultiScreen Framework)
/// Se conecta al API v2 de Samsung SmartView y emite el comando de lanzamiento.
class TizenClient {
  final String ip;

  TizenClient(this.ip);

  Future<bool> launchApp(String appId, Map<String, dynamic> params) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    WebSocket? ws;
    StreamSubscription<dynamic>? subscription;
    try {
      // 1. Obtener los detalles del API MSF (usamos port 8002 HTTPS si es reciente, o 8001 HTTP)
      int port = 8002;
      String protocol = 'https';

      client.badCertificateCallback = (cert, host, port) => true;

      try {
        final req = await client.getUrl(
          Uri.parse('$protocol://$ip:$port/api/v2/'),
        );
        final res = await req.close().timeout(const Duration(seconds: 2));
        if (res.statusCode != 200) {
          port = 8001;
          protocol = 'http';
        }
      } catch (_) {
        port = 8001;
        protocol = 'http';
      }

      // 2. Conectar al WebSocket
      final wsUrl = port == 8002
          ? 'wss://$ip:8002/api/v2/channels/samsung.remote.control?name=${base64Encode(utf8.encode('Flux'))}'
          : 'ws://$ip:8001/api/v2/channels/samsung.remote.control?name=${base64Encode(utf8.encode('Flux'))}';

      // Importante para Samsung HTTPS WSS: hay que ignorar certificados autofirmados.
      // En Dart `WebSocket.connect` usa customClient si pasamos uno.
      ws = await WebSocket.connect(
        wsUrl,
        customClient: client,
      ).timeout(const Duration(seconds: 5));

      // Wait for the TV to accept pairing before sending the launch request.
      final paired = Completer<void>();
      subscription = ws.listen(
        (raw) {
          try {
            final event = jsonDecode(raw as String) as Map<String, dynamic>;
            if (paired.isCompleted) return;
            if (event['event'] == 'ms.channel.connect') {
              paired.complete();
            } else if (event['event'] == 'ms.channel.unauthorized' ||
                event['event'] == 'ms.error') {
              paired.completeError(
                StateError('Samsung no autorizó la conexión.'),
              );
            }
          } catch (e) {
            if (!paired.isCompleted) paired.completeError(e);
          }
        },
        onError: (Object e) {
          if (!paired.isCompleted) paired.completeError(e);
        },
        onDone: () {
          if (!paired.isCompleted)
            paired.completeError(StateError('TV desconectada.'));
        },
      );
      await paired.future.timeout(const Duration(seconds: 30));

      // 3. Emitir el evento de lanzamiento
      final payload = {
        "method": "ms.channel.emit",
        "params": {
          "event": "ed.apps.launch",
          "to": "host",
          "data": {
            "appId": appId,
            "action_type": "DEEP_LINK",
            "metaTag": jsonEncode(
              params,
            ), // Tizen pasa los parámetros aquí o en PAYLOAD
          },
        },
      };

      ws.add(jsonEncode(payload));

      // Esperar brevemente para que el comando se envíe
      await Future.delayed(const Duration(milliseconds: 500));
      await ws.close();

      return true;
    } catch (e) {
      debugPrint('[Tizen] Error lanzando app: $e');
      return false;
    } finally {
      await subscription?.cancel();
      await ws?.close();
      client.close(force: true);
    }
  }
}
