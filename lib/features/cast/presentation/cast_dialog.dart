import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discovery/domain/stream_candidate.dart';
import '../ssap_client.dart';
import '../tizen_client.dart';
import '../tv_discovery.dart';

class CastDialog extends ConsumerStatefulWidget {
  const CastDialog({super.key, this.candidate});

  final StreamCandidate? candidate;

  static Future<void> show(BuildContext context, StreamCandidate candidate) {
    return showDialog(
      context: context,
      builder: (context) => CastDialog(candidate: candidate),
    );
  }

  @override
  ConsumerState<CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends ConsumerState<CastDialog> {
  late TVDiscoveryNotifier _discovery;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _discovery = ref.read(tvDiscoveryProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _discovery.startDiscovery();
    });
  }

  @override
  void dispose() {
    _discovery.stopDiscovery();
    super.dispose();
  }

  Future<void> _castTo(TVDevice tv) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final candidate = widget.candidate;
    final params = <String, dynamic>{
      if (candidate != null) ...{
        'host': candidate.host,
        'port': candidate.port,
        'url': candidate.uri.toString(),
        'isExternal': candidate.isExternal,
        if (candidate.httpHeaders?.isNotEmpty ?? false)
          'headers': candidate.httpHeaders,
      },
    };
    try {
      if (tv.type == 'webos') {
        final client = SSAPClient(ip: tv.ip);
        try {
          await client.connect();
          await client.launchApp('com.aur.flux', params);
        } finally {
          client.disconnect();
        }
      } else if (tv.type == 'tizen') {
        final sent = await TizenClient(tv.ip).launchApp('com.aur.flux', params);
        if (!sent) throw StateError('No se pudo enviar el comando a Samsung.');
      } else {
        if (candidate == null) {
          throw StateError(
            'En Android TV abre Flux con el mando de la TV primero. Luego puedes enviar videos desde aquí.',
          );
        }
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4);
        try {
          final request = await client
              .postUrl(Uri.parse('http://${tv.ip}:8080/launch'))
              .timeout(const Duration(seconds: 4));
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(params));
          final response = await request.close().timeout(
            const Duration(seconds: 6),
          );
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'La TV rechazó el comando (${response.statusCode}).',
            );
          }
        } finally {
          client.close(force: true);
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted)
        setState(
          () => _error =
              'No se pudo abrir Flux. Verifica que esté instalado y acepta el emparejamiento en la TV.\n$e',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(tvDiscoveryProvider);

    return AlertDialog(
      title: Text(
        widget.candidate == null ? 'Abrir Flux en TV' : 'Transmitir a...',
      ),
      content: SizedBox(
        width: 300,
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Acepta la conexión en tu TV…'),
                  ],
                ),
              )
            : devices.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Buscando dispositivos en la red...',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final tv = devices[index];
                  return ListTile(
                    leading: Icon(
                      (tv.type == 'webos' || tv.type == 'tizen')
                          ? Icons.tv
                          : Icons.ad_units,
                    ),
                    title: Text(tv.name),
                    subtitle: Text(tv.ip),
                    onTap: () => _castTo(tv),
                  );
                },
              ),
      ),
      actions: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: _busy ? null : _discovery.startDiscovery,
          child: const Text('Buscar de nuevo'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
