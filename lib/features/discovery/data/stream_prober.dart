import 'dart:async';
import 'dart:io';

import '../../../core/net/lan_guard.dart';
import '../domain/stream_candidate.dart';
import 'scan_config.dart';

/// Resultado crudo de una lectura cronometrada.
class _TimedRead {
  const _TimedRead({
    required this.status,
    required this.timeToFirstByte,
    required this.bytes,
    required this.transferTime,
  });

  final int status;
  final Duration timeToFirstByte;
  final int bytes;

  /// Tiempo de transferencia **descontando** el TTFB. Sin esta resta, un
  /// servidor que tarda 1,5 s en abrir el archivo pero luego va a 20 MB/s
  /// parecería ir a 0,15 MB/s.
  final Duration transferTime;

  double get bytesPerSecond {
    final micros = transferTime.inMicroseconds;
    if (bytes <= 0 || micros <= 0) return 0;
    return bytes * 1000000 / micros;
  }
}

/// Convierte un puerto abierto en un stream de video validado, y mide cómo de
/// bien va.
class StreamProber {
  StreamProber({this.config = const ScanConfig()});

  final ScanConfig config;

  late final HttpClient _client = HttpClient()
    ..connectionTimeout = config.probeTimeout
    ..idleTimeout = const Duration(seconds: 3)
    ..autoUncompress =
        false // los bytes medidos deben ser los bytes reales
    ..userAgent = 'Flux/1.0';

  void dispose() => _client.close(force: true);

  /// Extensiones que aceptamos cuando el servidor no se moja con el
  /// Content-Type y manda `application/octet-stream`.
  static final _videoExtensions = RegExp(
    r'\.(mkv|mp4|m4v|avi|mov|wmv|flv|webm|mpg|mpeg|ts|m2ts|mts|ogv|3gp|divx|vob|rmvb|asf)$',
    caseSensitive: false,
  );

  /// ¿Hay un video servible en `http://host:port/`?
  ///
  /// El servidor de Movie Plus ignora la ruta por completo — `/`, `/v.mkv` y
  /// `/loquesea` devuelven el mismo archivo — así que basta con pedir la raíz.
  /// Eso elimina la necesidad de adivinar nombres de archivo.
  Future<StreamCandidate?> probe(
    String host,
    int port, {
    DiscoverySource source = DiscoverySource.quickScan,
  }) async {
    if (!LanGuard.isAllowedTarget(host) || !LanGuard.isAllowedPort(port)) {
      return null;
    }
    final uri = Uri.parse('http://$host:$port/');

    HttpClientResponse? response;
    try {
      response = await _head(uri);
      // Algunos servidores embebidos no implementan HEAD. Reintentamos con un
      // GET mínimo (un solo byte) antes de descartar el host.
      if (response == null || !_isUsableStatus(response.statusCode)) {
        await response?.listen(null).cancel().catchError((_) {});
        response = await _rangeHead(uri);
      }
      if (response == null || !_isUsableStatus(response.statusCode))
        return null;

      return _fromHeaders(host, port, response.headers, source);
    } on Object {
      return null;
    } finally {
      // Nunca dejamos una conexión colgando en el teléfono que sirve el video.
      unawaited(
        response?.listen(null).cancel().catchError((_) {}) ?? Future.value(),
      );
    }
  }

  static bool _isUsableStatus(int status) =>
      status == HttpStatus.ok || status == HttpStatus.partialContent;

  Future<HttpClientResponse?> _head(
    Uri uri, {
    Map<String, String>? httpHeaders,
  }) async {
    final request = await _client.headUrl(uri).timeout(config.probeTimeout);
    request.followRedirects = false;
    request.persistentConnection = false;
    httpHeaders?.forEach((key, value) {
      request.headers.set(key, value);
    });
    return request.close().timeout(config.probeTimeout);
  }

  Future<HttpClientResponse?> _rangeHead(
    Uri uri, {
    Map<String, String>? httpHeaders,
  }) async {
    final request = await _client.getUrl(uri).timeout(config.probeTimeout);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    httpHeaders?.forEach((key, value) {
      request.headers.set(key, value);
    });
    final response = await request.close().timeout(config.probeTimeout);
    return response;
  }

  /// Comprueba una URL de Internet directamente, sin usar `isAllowedTarget`
  /// (porque ya se validó con `isAllowedExternalUri`) y usando un timeout más largo.
  Future<StreamCandidate?> probeExternal(
    Uri uri, {
    DiscoverySource source = DiscoverySource.directLink,
    Map<String, String>? httpHeaders,
  }) async {
    HttpClientResponse? response;
    try {
      response = await _head(uri, httpHeaders: httpHeaders);
      if (response == null || !_isUsableStatus(response.statusCode)) {
        await response?.listen(null).cancel().catchError((_) {});
        response = await _rangeHead(uri, httpHeaders: httpHeaders);
      }
      if (response == null || !_isUsableStatus(response.statusCode))
        return null;

      final host = uri.host;
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

      var candidate = _fromHeaders(
        host,
        port,
        response.headers,
        source,
        explicitUri: uri,
        httpHeaders: httpHeaders,
      );

      // Si fallan las cabeceras HTTP pero la URL claramente apunta a un video,
      // lo aceptamos de todos modos (muchos servidores son vagos con el Content-Type).
      if (candidate == null && _videoExtensions.hasMatch(uri.path)) {
        final headers = response.headers;
        final disposition = headers.value('content-disposition');
        final acceptRanges =
            headers.value(HttpHeaders.acceptRangesHeader)?.toLowerCase() ?? '';

        candidate = StreamCandidate(
          host: host,
          port: port,
          source: source,
          explicitUri: uri,
          fileName: fileNameFrom(disposition),
          contentType: headers
              .value(HttpHeaders.contentTypeHeader)
              ?.toLowerCase()
              .trim(),
          sizeBytes: _contentLength(headers),
          seekable: acceptRanges.contains('bytes'),
          lastModified: _lastModified(headers),
          discoveredAt: DateTime.now(),
          httpHeaders: httpHeaders,
        );
      }
      return candidate;
    } on Object {
      return null;
    } finally {
      unawaited(
        response?.listen(null).cancel().catchError((_) {}) ?? Future.value(),
      );
    }
  }

  StreamCandidate? _fromHeaders(
    String host,
    int port,
    HttpHeaders headers,
    DiscoverySource source, {
    Uri? explicitUri,
    Map<String, String>? httpHeaders,
  }) {
    final contentType = headers
        .value(HttpHeaders.contentTypeHeader)
        ?.toLowerCase()
        .trim();
    final disposition = headers.value('content-disposition');
    final fileName = fileNameFrom(disposition);
    final length = _contentLength(headers);
    final acceptRanges =
        headers.value(HttpHeaders.acceptRangesHeader)?.toLowerCase() ?? '';

    final kind = _classify(contentType, fileName);
    if (kind == _MediaKind.none) return null;

    // Un video de verdad ocupa megas. Si el servidor dice que son 2 KB, es una
    // página de error disfrazada.
    if (kind == _MediaKind.file && length != null && length < 512 * 1024) {
      return null;
    }

    return StreamCandidate(
      host: host,
      port: port,
      source: source,
      explicitUri: explicitUri,
      fileName: fileName,
      contentType: contentType,
      sizeBytes: length,
      seekable: acceptRanges.contains('bytes'),
      isLiveStream: kind == _MediaKind.playlist,
      lastModified: _lastModified(headers),
      discoveredAt: DateTime.now(),
      httpHeaders: httpHeaders,
    );
  }

  /// Tercera pata de la huella del archivo, junto al nombre y el tamaño. Dos
  /// capítulos de la misma serie pueden pesar casi lo mismo; la fecha del
  /// archivo los separa.
  static DateTime? _lastModified(HttpHeaders headers) {
    final raw = headers.value(HttpHeaders.lastModifiedHeader);
    if (raw == null) return null;
    try {
      return HttpDate.parse(raw);
    } on Object {
      return null;
    }
  }

  static int? _contentLength(HttpHeaders headers) {
    final raw = headers.value(HttpHeaders.contentLengthHeader);
    final direct = headers.contentLength;
    if (direct > 0) return direct;
    // En una respuesta 206 el tamaño real está en Content-Range.
    final range = headers.value(HttpHeaders.contentRangeHeader);
    if (range != null) {
      final total = RegExp(r'/(\d+)$').firstMatch(range.trim())?.group(1);
      if (total != null) return int.tryParse(total);
    }
    return raw == null ? null : int.tryParse(raw);
  }

  static _MediaKind _classify(String? contentType, String? fileName) {
    if (contentType != null) {
      if (contentType.startsWith('video/')) return _MediaKind.file;
      if (contentType.contains('matroska')) return _MediaKind.file;
      if (contentType.contains('mpegurl') || contentType.contains('dash+xml')) {
        return _MediaKind.playlist;
      }
      if (contentType.startsWith('audio/')) return _MediaKind.file;
      final isOpaque =
          contentType.startsWith('application/octet-stream') ||
          contentType.startsWith('binary/');
      if (isOpaque) {
        return (fileName != null && _videoExtensions.hasMatch(fileName))
            ? _MediaKind.file
            : _MediaKind.none;
      }
      // text/html, application/json... es un panel web, no un stream.
      return _MediaKind.none;
    }
    // Sin Content-Type solo nos fiamos del nombre del archivo.
    if (fileName != null && _videoExtensions.hasMatch(fileName)) {
      return _MediaKind.file;
    }
    return _MediaKind.none;
  }

  /// Saca el nombre de `Content-Disposition`, soportando tanto
  /// `filename="x.mkv"` como el `filename*=UTF-8''x%20y.mkv` de RFC 5987.
  static String? fileNameFrom(String? disposition) {
    if (disposition == null) return null;
    final extended = RegExp(
      r"filename\*\s*=\s*[^']*'[^']*'([^;]+)",
      caseSensitive: false,
    ).firstMatch(disposition);
    if (extended != null) {
      try {
        return Uri.decodeComponent(extended.group(1)!.trim());
      } on Object {
        // Cae al formato simple.
      }
    }
    final simple = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(disposition);
    final name = simple?.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    return name;
  }

  /// Mide el stream: arranque en frío, ancho de banda sostenido y latencia de
  /// salto. Es lo que permite ordenar varios streams por "cuál va mejor".
  Future<StreamMetrics?> benchmark(StreamCandidate candidate) async {
    try {
      final start = await _timedRead(
        candidate.uri,
        offset: 0,
        maxBytes: config.benchmarkBytes,
        maxDuration: config.benchmarkMaxDuration,
      );
      if (start == null) return null;

      // Latencia de salto: pedimos desde la mitad del archivo y cronometramos
      // hasta el primer byte. Es exactamente lo que sufre el usuario al
      // arrastrar la barra de progreso.
      var seekTtfb = start.timeToFirstByte;
      final size = candidate.sizeBytes;
      if (candidate.seekable && size != null && size > 8 * 1024 * 1024) {
        final middle = (size ~/ 2);
        final seek = await _timedRead(
          candidate.uri,
          offset: middle,
          maxBytes: 64 * 1024,
          maxDuration: const Duration(seconds: 4),
        );
        if (seek != null) seekTtfb = seek.timeToFirstByte;
      }

      return StreamMetrics(
        timeToFirstByte: start.timeToFirstByte,
        bytesPerSecond: start.bytesPerSecond,
        seekTimeToFirstByte: seekTtfb,
      );
    } on Object {
      return null;
    }
  }

  Future<_TimedRead?> _timedRead(
    Uri uri, {
    required int offset,
    required int maxBytes,
    required Duration maxDuration,
  }) async {
    final stopwatch = Stopwatch()..start();
    final request = await _client.getUrl(uri).timeout(config.probeTimeout);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$offset-${offset + maxBytes - 1}',
    );

    final response = await request.close().timeout(config.probeTimeout);
    if (!_isUsableStatus(response.statusCode)) {
      await response.drain<void>().catchError((_) {});
      return null;
    }

    Duration? firstByte;
    var total = 0;
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    subscription = response.listen(
      (chunk) {
        firstByte ??= stopwatch.elapsed;
        total += chunk.length;
        if (total >= maxBytes || stopwatch.elapsed > maxDuration) {
          subscription.cancel();
          finish();
        }
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );

    await done.future.timeout(
      maxDuration + config.probeTimeout,
      onTimeout: () async {
        await subscription.cancel();
      },
    );
    stopwatch.stop();

    final ttfb = firstByte ?? stopwatch.elapsed;
    var transfer = stopwatch.elapsed - ttfb;
    if (transfer <= Duration.zero) transfer = const Duration(milliseconds: 1);

    return _TimedRead(
      status: response.statusCode,
      timeToFirstByte: ttfb,
      bytes: total,
      transferTime: transfer,
    );
  }
}

enum _MediaKind { none, file, playlist }
