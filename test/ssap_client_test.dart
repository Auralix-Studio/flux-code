import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flux/features/cast/ssap_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final accepted in [true, false]) {
    test('Launch waits for TV response: accepted=$accepted', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) {
          final data = jsonDecode(raw as String);
          if (data['type'] == 'register') {
            socket.add(
              jsonEncode({
                'type': 'registered',
                'payload': {'client-key': 'test'},
              }),
            );
          } else {
            socket.add(
              jsonEncode({
                'id': 'launch_0',
                'type': accepted ? 'response' : 'error',
                'payload': {'returnValue': accepted},
              }),
            );
          }
        });
      });
      final client = SSAPClient(ip: '127.0.0.1', port: server.port);
      try {
        await client.connect();
        final launch = client.launchApp('com.aur.flux', {});
        if (accepted) {
          await launch;
        } else {
          await expectLater(launch, throwsStateError);
        }
      } finally {
        client.disconnect();
        await server.close(force: true);
      }
    });
  }
}
