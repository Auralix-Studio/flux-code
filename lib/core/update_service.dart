import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'update_manifest.dart';

class UpdateService extends ChangeNotifier {
  static final instance = UpdateService();
  static const _channel = MethodChannel('flux/updater');
  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isWindows) &&
      !const bool.fromEnvironment('STORE_BUILD');
  UpdateManifest? available;
  bool busy = false;
  String? message;
  String? _downloadedPath;

  Future<void> check() async {
    if (!supported || busy) return;
    busy = true;
    message = null;
    notifyListeners();
    final client = http.Client();
    try {
      var target = 'android-universal';
      if (Platform.isAndroid) {
        try {
          target = await _channel.invokeMethod<String>('target') ?? target;
        } catch (_) {
          /* The universal APK also works when ABI detection fails. */
        }
      }
      UpdateManifest? manifest;
      for (final url in const [
        'https://auralix-studio.github.io/flux/version.json',
        'https://github.com/Auralix-Studio/flux/releases/latest/download/version.json',
      ]) {
        try {
          final response = await client
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 15));
          if (response.statusCode == 200 &&
              response.bodyBytes.length <= 1048576) {
            manifest = UpdateManifest.parse(
              jsonDecode(response.body),
              windows: Platform.isWindows,
              androidTarget: target,
            );
            if (manifest != null) break;
          }
        } catch (_) {
          /* Try release fallback when Pages is unavailable. */
        }
      }
      if (manifest == null) {
        message = 'No se pudo comprobar la actualización. Inténtalo de nuevo.';
      } else if (manifest.isNewerThan(AppVersion.name, AppVersion.build)) {
        if (available?.sha256 != manifest.sha256) _downloadedPath = null;
        available = manifest;
      } else {
        available = null;
        _downloadedPath = null;
        message = 'Flux está actualizado (${AppVersion.full}).';
      }
    } finally {
      client.close();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    final update = available;
    if (!supported || busy || update == null) return;
    busy = true;
    message = Platform.isWindows
        ? 'Abriendo la descarga para Windows…'
        : 'Descargando y verificando la actualización…';
    notifyListeners();
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [update.url]);
        message =
            'Descarga el ZIP, cierra Flux y extrae todo su contenido para reemplazar la instalación. SHA-256: ${update.sha256}';
        return;
      }
      final arguments = <String, Object>{
        'url': update.url,
        'sha256': update.sha256,
        'size': update.size,
      };
      _downloadedPath ??= await _channel.invokeMethod<String>(
        'download',
        arguments,
      );
      if (_downloadedPath == null) throw StateError('Missing APK');
      final result = await _channel.invokeMethod<String>('install', {
        ...arguments,
        'path': _downloadedPath!,
      });
      if (result == 'needs_permission') {
        await _channel.invokeMethod<void>('openInstallSettings');
        message =
            'Permite instalar actualizaciones de Flux y vuelve a pulsar Actualizar.';
      } else if (result == 'started') {
        message = 'Confirma la actualización en el instalador de Android.';
      } else {
        _downloadedPath = null;
        message =
            'Android rechazó el APK. Revisa su versión y firma de distribución.';
      }
    } catch (_) {
      _downloadedPath = null;
      message =
          'No se pudo descargar o verificar la actualización. Inténtalo de nuevo.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
