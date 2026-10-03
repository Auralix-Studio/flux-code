import 'dart:convert';
import 'package:flutter/foundation.dart';

typedef OnVideoDetected =
    void Function(
      String url, {
      double? duration,
      String? source,
      int? width,
      int? height,
      bool isLikelyAd,
      String? referer,
      String? poster,
    });

/// Detector de video multicapa para flutter_inappwebview.
///
/// Detecta streams de:
///   - XHR / fetch hooks (MSE, YouTube, Twitch…)
///   - src setter de HTMLMediaElement
///   - play() hook con metadata real
///   - MutationObserver para reproductores que agregan <video> tardíamente
///   - onLoadResource nativo de Android (sin fragmentos .ts/.m4s)
///
/// Clasifica cada candidato como contenido real o probable anuncio antes de
/// notificar, usando dominio de ad-server y duración del clip.
class VideoDetector {
  VideoDetector({required this.onVideoDetected});

  final OnVideoDetected onVideoDetected;

  /// URLs ya notificadas (sin fragment #). Evita duplicados exactos.
  final Set<String> _seen = {};

  static const String channelName = 'FluxVideoDetector';

  // ── Extensiones de contenedor / manifiesto que SÍ queremos ────────────────
  static final _masterPattern = RegExp(
    r'\.(m3u8|mpd|mp4|mkv|webm|mov|m4v)(\?|$|#)',
    caseSensitive: false,
  );

  // ── Fragmentos y archivos no deseados que NO queremos reportar ─────────────
  static final _ignoredPattern = RegExp(
    r'\.(ts|m4s|aac|vtt|srt|png|jpg|jpeg|gif|css|js)(\?|$|#)',
    caseSensitive: false,
  );

  // ── Paths de streaming sin extensión obvia (FIXED: puntos escapados) ───────
  static final _streamingPathPattern = RegExp(
    r'(\/hls\/|\/dash\/|\/manifest|\/playlist|\/master\.m3u8'
    r'|\/chunklist|\/vod\/|\/live\/|\.googlevideo\.com\/)',
    caseSensitive: false,
  );

  // ── Dominios de ad-servers conocidos ──────────────────────────────────────
  static const _adDomains = {
    'imasdk.googleapis.com', // IMA SDK de Google (el más común)
    'doubleclick.net',
    'googlesyndication.com',
    'moatads.com',
    'springserve.com',
    'spotxchange.com',
    'freewheel.tv',
    'advertising.com',
    'adnxs.com',
    'rubiconproject.com',
    '2mdn.net',
    'pubmatic.com',
    'openx.net',
    'taboola.com',
    'outbrain.com',
    'smartadserver.com',
    'lijit.com',
    'undertone.com',
  };

  // ══════════════════════════════════════════════════════════════════════════
  // Script JS inyectado en la página
  // ══════════════════════════════════════════════════════════════════════════

  String get injectionScript =>
      '''
(function() {
  if (window.__fluxDetectorInjected) return;
  window.__fluxDetectorInjected = true;

  const seen = new Set();
  const pending = [];
  let ready = false;

  // ── FIXED Bug 1: cola hasta que el bridge esté listo ──────────────────────
  function sendToDart(payload) {
    if (ready) {
      _doSend(payload);
    } else {
      pending.push(payload);
    }
  }

  function _doSend(payload) {
    try {
      window.flutter_inappwebview.callHandler('$channelName', JSON.stringify(payload));
    } catch(e) {}
  }

  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
    ready = true;
  } else {
    window.addEventListener('flutterInAppWebViewPlatformReady', function() {
      ready = true;
      pending.forEach(_doSend);
      pending.length = 0;
    }, { once: true });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  function isMediaUrl(url) {
    if (!url || typeof url !== 'string') return false;
    const lo = url.toLowerCase();
    return lo.match(/\\.(m3u8|mpd|mp4|mkv|webm|mov|m4v)(\\?|\$|#)/) != null
        || lo.includes('/hls/')    || lo.includes('/dash/')
        || lo.includes('.m3u8')   || lo.includes('.mpd')
        || lo.includes('/manifest') || lo.includes('/playlist')
        || lo.includes('/vod/')   || lo.includes('/live/')
        || lo.includes('.googlevideo.com/');
  }

  function _getOgImage() {
    let meta = document.querySelector('meta[property="og:image"]') || document.querySelector('meta[name="twitter:image"]');
    if (!meta || !meta.content) return null;
    let url = meta.content;
    if (!url.startsWith('http')) {
      try { url = new URL(url, document.baseURI).href; } catch(e) {}
    }
    return url;
  }

  function videoMeta(el) {
    return {
      duration : isFinite(el.duration) ? el.duration : null,
      width    : el.videoWidth  || el.width  || 0,
      height   : el.videoHeight || el.height || 0,
      poster   : el.poster || _getOgImage(),
    };
  }

  function guessMeta() {
    const videos = document.querySelectorAll('video');
    if (videos.length === 1) return videoMeta(videos[0]);
    for (let i = 0; i < videos.length; i++) {
       if (videos[i].readyState >= 1 && videos[i].videoWidth > 0) return videoMeta(videos[i]);
    }
    return { poster: _getOgImage() };
  }

  function notify(url, type, extra) {
    if (!url || typeof url !== 'string') return;
    if (url.startsWith('blob:') || url.startsWith('data:')) return;
    if (!url.startsWith('http')) {
      try { url = new URL(url, document.baseURI).href; } catch(e) { return; }
    }
    if (!/^https?:/i.test(url)) return;
    if (/\\.(ts|m4s|aac|vtt|srt|png|jpg|jpeg|gif|css|js)(\\?|\$|#)/i.test(url)) return;
    const clean = url.split('#')[0];
    if (seen.has(clean)) return;
    seen.add(clean);
    
    if (!extra) {
       extra = guessMeta();
    } else if (!extra.poster) {
       extra.poster = _getOgImage();
    }

    const payload = { type: type, url: clean, referer: window.location.href };
    if (extra) {
      if (extra.duration != null && isFinite(extra.duration) && extra.duration > 0)
        payload.duration = extra.duration;
      if (extra.width  > 0) payload.width  = extra.width;
      if (extra.height > 0) payload.height = extra.height;
      if (extra.poster)     payload.poster = extra.poster;
    }
    sendToDart(payload);
  }

  function checkVideoEl(video) {
    const src = video.currentSrc || video.src;
    if (src && src.startsWith('http')) {
      notify(src, 'video_element', videoMeta(video));
    }
    video.querySelectorAll('source[src]').forEach(function(s) {
      if (s.src && s.src.startsWith('http')) notify(s.src, 'source_element', videoMeta(video));
    });
  }

  // ── Capa 1: fetch hook ─────────────────────────────────────────────────────
  try {
    const origFetch = window.fetch;
    window.fetch = function() {
      const arg = arguments[0];
      const url = (typeof arg === 'string') ? arg : (arg && arg.url);
      if (url && isMediaUrl(url)) notify(url, 'fetch');
      return origFetch.apply(this, arguments).then(function(response) {
        const mime = (response.headers.get('content-type') || '').toLowerCase();
        if ((mime.startsWith('video/') && !mime.includes('mp2t') && !mime.includes('iso.segment')) || mime.includes('mpegurl') || mime.includes('dash+xml')) {
          notify(response.url || url, 'fetch');
        }
        return response;
      });
    };
  } catch(e) {}

  // ── Capa 2: XHR hook ──────────────────────────────────────────────────────
  try {
    const origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function() {
      const url = arguments[1];
      if (url && typeof url === 'string' && isMediaUrl(url)) notify(url, 'xhr');
      this.addEventListener('load', function() {
        const mime = (this.getResponseHeader('content-type') || '').toLowerCase();
        if ((mime.startsWith('video/') && !mime.includes('mp2t') && !mime.includes('iso.segment')) || mime.includes('mpegurl') || mime.includes('dash+xml')) {
          notify(this.responseURL || url, 'xhr');
        }
      }, { once: true });
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}

  // ── Capa 3: src setter — espera loadedmetadata para capturar duration ──────
  try {
    const desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc && desc.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        get: desc.get,
        set: function(val) {
          desc.set.call(this, val);
          if (val && typeof val === 'string' && val.startsWith('http')) {
            const el = this;
            // Intentar inmediatamente por si ya hay metadata
            if (el.readyState >= 1 && el.currentSrc) {
              notify(el.currentSrc, 'src_setter', videoMeta(el));
            } else {
              el.addEventListener('loadedmetadata', function onMeta() {
                el.removeEventListener('loadedmetadata', onMeta);
                if (el.currentSrc) notify(el.currentSrc, 'src_setter', videoMeta(el));
              }, { once: true });
            }
          }
        },
      });
    }
  } catch(e) {}

  // ── Capa 4: play() hook — FIXED Bug 5: espera readyState >= 1 ─────────────
  try {
    const origPlay = HTMLVideoElement.prototype.play;
    HTMLVideoElement.prototype.play = function() {
      const el = this;
      if (el.readyState >= 1 && el.currentSrc && el.currentSrc.startsWith('http')) {
        notify(el.currentSrc, 'play', videoMeta(el));
      } else {
        el.addEventListener('loadedmetadata', function onMeta() {
          el.removeEventListener('loadedmetadata', onMeta);
          if (el.currentSrc && el.currentSrc.startsWith('http'))
            notify(el.currentSrc, 'play', videoMeta(el));
        }, { once: true });
      }
      return origPlay.apply(this, arguments);
    };
  } catch(e) {}

  // ── Capa 5: MutationObserver para reproductores que añaden <video> tarde ──
  try {
    new MutationObserver(function(muts) {
      for (const m of muts) {
        for (const node of m.addedNodes) {
          if (node.nodeType !== 1) continue;
          if (node.tagName === 'VIDEO') checkVideoEl(node);
          const nested = node.querySelectorAll ? node.querySelectorAll('video') : [];
          nested.forEach(checkVideoEl);
        }
      }
    }).observe(document.documentElement || document.body, {
      childList: true, subtree: true,
    });
  } catch(e) {}

  // ── Capa 6: escaneos periódicos (fallback para SPAs lentas) ───────────────
  [800, 2500, 5000, 9000].forEach(function(ms) {
    setTimeout(function() {
      document.querySelectorAll('video').forEach(checkVideoEl);
    }, ms);
  });
})();
''';

  // ══════════════════════════════════════════════════════════════════════════
  // Lado Dart
  // ══════════════════════════════════════════════════════════════════════════

  /// Llamado desde el JavascriptHandler de flutter_inappwebview:
  ///
  /// ```dart
  /// webViewController.addJavaScriptHandler(
  ///   handlerName: VideoDetector.channelName,
  ///   callback: (args) => detector.handleMessage(args),
  /// );
  /// ```
  void handleMessage(dynamic message) {
    try {
      // flutter_inappwebview entrega args como List<dynamic>
      final raw = (message is List)
          ? message.first.toString()
          : message.toString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) return;

      _process(
        url: url,
        source: data['type'] as String?,
        referer: data['referer'] as String?,
        duration: (data['duration'] as num?)?.toDouble(),
        width: (data['width'] as num?)?.toInt(),
        height: (data['height'] as num?)?.toInt(),
        poster: data['poster'] as String?,
      );
    } catch (e) {
      debugPrint('[VideoDetector] handleMessage error: $e');
    }
  }

  /// Llamado desde `onLoadResource` de InAppWebView (Android).
  ///
  /// FIXED Bug 2: los segmentos .ts/.m4s se suprimen aquí.
  /// Solo se reportan masters (.m3u8/.mpd) y contenedores completos (.mp4…).
  void interceptNativeResource(String url, {String? referer}) {
    // Ignorar cualquier archivo no deseado (fragmentos, imágenes, etc.)
    if (_ignoredPattern.hasMatch(url)) return;

    if (_masterPattern.hasMatch(url) || _streamingPathPattern.hasMatch(url)) {
      _process(url: url, source: 'network', referer: referer);
    }
  }

  // ── Pipeline interno ───────────────────────────────────────────────────────

  void _process({
    required String url,
    String? source,
    String? referer,
    double? duration,
    int? width,
    int? height,
    String? poster,
  }) {
    final clean = _stripFragment(url);
    final uri = Uri.tryParse(clean);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty)
      return;

    // Suprimir segmentos individuales (HLS/DASH) y otros ignorados SIEMPRE.
    // Reproducir un fragmento .ts o .m4s falla rápidamente y traba el reproductor.
    if (_ignoredPattern.hasMatch(clean)) return;

    if (!_markSeen(clean)) return; // ya notificado

    final isAd = _classifyAsAd(clean, duration: duration);

    debugPrint(
      '[VideoDetector] ${isAd ? "📢 AD" : "✅ VIDEO"}'
      ' ($source): $clean'
      '${duration != null ? " [${duration.toStringAsFixed(0)}s]" : ""}'
      '${width != null && width > 0 ? " ${width}x$height" : ""}',
    );

    onVideoDetected(
      clean,
      duration: duration,
      source: source,
      width: width,
      height: height,
      isLikelyAd: isAd,
      referer: referer,
      poster: poster,
    );
  }

  // ── Clasificación de anuncios ──────────────────────────────────────────────

  /// FIXED Bug 6: clasificación real por dominio y duración.
  bool _classifyAsAd(String url, {double? duration}) {
    // 1. Dominio de ad-server conocido
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (_adDomains.any((d) => host == d || host.endsWith('.$d'))) {
        return true;
      }
    } catch (_) {}

    return false;
  }

  // ── Utilidades ─────────────────────────────────────────────────────────────

  String _stripFragment(String url) {
    final i = url.indexOf('#');
    return i < 0 ? url : url.substring(0, i);
  }

  bool _markSeen(String url) {
    if (_seen.contains(url)) return false;
    _seen.add(url);
    return true;
  }

  /// Llama esto al navegar a una nueva página para limpiar el estado.
  void clear() {
    _seen.clear();
  }
}
