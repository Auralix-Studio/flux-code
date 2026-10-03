import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class SSAPClient {
  final String ip;
  final int port;
  WebSocket? _socket;
  bool _isConnected = false;
  Completer<void>? _launch;

  SSAPClient({required this.ip, this.port = 3000});

  Future<void> connect() async {
    if (_isConnected) return;
    try {
      _socket = await WebSocket.connect(
        'ws://$ip:$port',
      ).timeout(const Duration(seconds: 5));
      _isConnected = true;

      final completer = Completer<void>();

      _socket!.listen(
        (data) {
          final Map<String, dynamic> response =
              jsonDecode(data as String) as Map<String, dynamic>;
          if (response['id'] == 'launch_0' &&
              _launch != null &&
              !_launch!.isCompleted) {
            if (response['type'] == 'response' &&
                (response['payload'] as Map?)?['returnValue'] == true) {
              _launch!.complete();
            } else {
              _launch!.completeError(
                StateError(
                  'La TV rechazó abrir Flux: ${response['error'] ?? response['payload']}',
                ),
              );
            }
          }

          if (response['type'] == 'registered') {
            final key =
                (response['payload'] as Map<String, dynamic>?)?['client-key']
                    as String?;
            if (key != null) {
              SharedPreferences.getInstance().then(
                (p) => p.setString('webos_client_key_$ip', key),
              );
            }
            if (!completer.isCompleted) completer.complete();
          } else if (response['type'] == 'error' && !completer.isCompleted) {
            completer.completeError(
              StateError('La TV rechazó el emparejamiento.'),
            );
          }
        },
        onDone: () {
          _isConnected = false;
          if (!completer.isCompleted)
            completer.completeError(
              StateError('Conexión con la TV interrumpida.'),
            );
          if (_launch != null && !_launch!.isCompleted)
            _launch!.completeError(
              StateError('Conexión con la TV interrumpida.'),
            );
        },
        onError: (e) {
          _isConnected = false;
          if (!completer.isCompleted)
            completer.completeError(
              StateError('Conexión con la TV interrumpida.'),
            );
          if (_launch != null && !_launch!.isCompleted)
            _launch!.completeError(
              StateError('Conexión con la TV interrumpida.'),
            );
        },
      );

      await _register();

      // Wait for registration to complete or timeout
      await completer.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _isConnected = false;
      disconnect();
      rethrow;
    }
  }

  Future<void> _register() async {
    final prefs = await SharedPreferences.getInstance();
    final clientKey = prefs.getString('webos_client_key_$ip');

    final payload = {
      'type': 'register',
      'id': 'register_0',
      'payload': {
        'forcePairing': false,
        'manifest': {
          'manifestVersion': 1,
          'appVersion': '1.0.0',
          'signatures': [
            {'signatureVersion': 1, 'signature': 'Flux'},
          ],
          'permissions': [
            'LAUNCH',
            'LAUNCH_WEBAPP',
            'APP_TO_APP',
            'CLOSE',
            'TEST_OPEN',
            'TEST_PROTECTED',
            'CONTROL_AUDIO',
            'CONTROL_DISPLAY',
            'CONTROL_INPUT_JOYSTICK',
            'CONTROL_INPUT_MEDIA_RECORDING',
            'CONTROL_INPUT_MEDIA_PLAYBACK',
            'CONTROL_INPUT_TV',
            'CONTROL_POWER',
            'READ_APP_STATUS',
            'READ_CURRENT_CHANNEL',
            'READ_INPUT_DEVICE_LIST',
            'READ_NETWORK_STATE',
            'READ_RUNNING_APPS',
            'READ_TV_CHANNEL_LIST',
            'WRITE_NOTIFICATION_TOAST',
            'WRITE_SETTINGS',
          ],
        },
        if (clientKey != null) 'client-key': clientKey,
      },
    };

    _socket?.add(jsonEncode(payload));
  }

  Future<void> launchApp(String appId, Map<String, dynamic> params) async {
    if (!_isConnected) await connect();
    if (!_isConnected) throw StateError('TV desconectada.');

    final payload = {
      'type': 'request',
      'id': 'launch_0',
      'uri': 'ssap://system.launcher/launch',
      'payload': {'id': appId, 'params': params},
    };

    _launch = Completer<void>();
    _socket!.add(jsonEncode(payload));
    await _launch!.future.timeout(const Duration(seconds: 8));
  }

  void disconnect() {
    _socket?.close();
    _isConnected = false;
  }
}
