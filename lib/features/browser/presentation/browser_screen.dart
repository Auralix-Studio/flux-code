import 'dart:collection';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/settings/app_settings.dart';

import '../../discovery/presentation/discovery_controller.dart';
import '../../cast/presentation/cast_dialog.dart';
import '../data/video_detector.dart';
import '../domain/ad_block_list.dart';
import '../domain/video_classifier.dart';
import 'browser_controller.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key, this.initialUrl = 'https://google.com'});
  final String initialUrl;

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  InAppWebViewController? _webController;
  late final VideoDetector _detector;
  late final AdBlockList _adBlockList;
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    _detector = VideoDetector(
      onVideoDetected:
          (
            url, {
            duration,
            source,
            width,
            height,
            isLikelyAd = false,
            referer,
            poster,
          }) {
            ref
                .read(browserControllerProvider.notifier)
                .addVideo(
                  url,
                  duration: duration,
                  source: source,
                  width: width,
                  height: height,
                  isLikelyAd: isLikelyAd,
                  referer: referer,
                  poster: poster,
                );
          },
    );

    _adBlockList = AdBlockList();
  }

  Future<void> _processSelectedVideo(
    ClassifiedVideo video, {
    required bool cast,
  }) async {
    // Extraer cabeceras del navegador actual para evitar bloqueos Anti-Hotlinking
    final currentUrl = (await _webController?.getUrl())?.toString();
    final effectiveReferer = video.referer ?? currentUrl;
    final userAgent =
        await _webController?.evaluateJavascript(source: 'navigator.userAgent')
            as String?;

    final Map<String, String> headers = {};
    if (effectiveReferer != null) headers['Referer'] = effectiveReferer;
    if (userAgent != null) headers['User-Agent'] = userAgent;

    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(video.url),
    );
    if (cookies.isNotEmpty) {
      headers['Cookie'] = cookies.map((c) => '${c.name}=${c.value}').join('; ');
    }
    if (!mounted) return;

    // Mostrar indicador de carga mientras se extrae y verifica el enlace
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    // Validar el video con el discovery controller (probing)
    final candidate = await ref
        .read(discoveryControllerProvider.notifier)
        .addDirectLink(
          video.url,
          httpHeaders: headers.isEmpty ? null : headers,
        );

    if (mounted) {
      Navigator.of(context).pop(); // Cerrar diálogo de carga
    }

    if (candidate != null && mounted) {
      if (cast) {
        showDialog(
          context: context,
          builder: (context) => CastDialog(candidate: candidate),
        );
      } else {
        Navigator.of(context).pop(candidate);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'El enlace seleccionado no parece ser válido o reproducible.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserControllerProvider);
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _webController?.canGoBack() ?? false) {
          _webController?.goBack();
        } else {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Container(
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                hintText: 'Buscar o escribir URL',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (value) {
                if (value.isNotEmpty) {
                  var newUrl = value.trim();
                  if (!newUrl.startsWith('http://') &&
                      !newUrl.startsWith('https://')) {
                    // Si parece un dominio, agregar https, si no, buscar en Google
                    if (newUrl.contains('.') && !newUrl.contains(' ')) {
                      newUrl = 'https://$newUrl';
                    } else {
                      newUrl =
                          'https://www.google.com/search?q=${Uri.encodeComponent(newUrl)}';
                    }
                  }
                  _webController?.loadUrl(
                    urlRequest: URLRequest(url: WebUri(newUrl)),
                  );
                  FocusScope.of(context).unfocus();
                }
              },
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Abrir Flux en TV',
              icon: const Icon(Icons.tv_rounded),
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const CastDialog(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, size: 20),
              onPressed: () async {
                if (await _webController?.canGoBack() ?? false) {
                  _webController?.goBack();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 20),
              onPressed: () async {
                if (await _webController?.canGoForward() ?? false) {
                  _webController?.goForward();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              onPressed: () {
                ref.read(browserControllerProvider.notifier).clearCandidates();
                _webController?.reload();
              },
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4.0),
            child: state.isLoading
                ? const LinearProgressIndicator()
                : const SizedBox(height: 4.0),
          ),
        ),
        floatingActionButton: state.candidates.isNotEmpty
            ? FloatingActionButton.extended(
                onPressed: () => _showVideoSheet(context, state),
                icon: const Icon(Icons.movie_creation_rounded),
                label: Text('${state.candidates.length} Videos Detectados'),
                backgroundColor: theme.colorScheme.primaryContainer,
                elevation: 4,
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        body: Stack(
          children: [
            Positioned.fill(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
                initialSettings: InAppWebViewSettings(
                  useShouldOverrideUrlLoading: true,
                  mediaPlaybackRequiresUserGesture: false,
                  useOnLoadResource: true,
                  javaScriptEnabled: true,
                  supportMultipleWindows:
                      true, // Habilitar para interceptar popups
                ),
                initialUserScripts: UnmodifiableListView<UserScript>([
                  UserScript(
                    source: _detector.injectionScript,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    forMainFrameOnly: false,
                  ),
                ]),
                onWebViewCreated: (controller) {
                  _webController = controller;
                  controller.addJavaScriptHandler(
                    handlerName: VideoDetector.channelName,
                    callback: (args) {
                      _detector.handleMessage(args);
                    },
                  );
                },
                onLoadStart: (controller, url) {
                  if (url != null) {
                    ref
                        .read(browserControllerProvider.notifier)
                        .setLoading(true);
                    ref
                        .read(browserControllerProvider.notifier)
                        .setUrl(url.toString());
                    _urlController.text = url.toString();
                    // Solo limpiar el deduplicador interno, NO los candidatos visibles.
                    // El usuario puede navegar dentro del sitio y los videos
                    // detectados previamente deben seguir disponibles.
                    _detector.clear();
                  }
                },
                onLoadStop: (controller, url) {
                  ref
                      .read(browserControllerProvider.notifier)
                      .setLoading(false);

                  if (url != null) {
                    final urlStr = url.toString();
                    if (urlStr.contains('youtube.com/watch') ||
                        urlStr.contains('youtu.be/')) {
                      ref
                          .read(browserControllerProvider.notifier)
                          .addVideo(urlStr);
                    }
                  }

                  // Re-inyectar el script por si la página hizo una navegación
                  // interna (SPA) que no dispara AT_DOCUMENT_START.
                  controller.evaluateJavascript(
                    source: _detector.injectionScript,
                  );
                },
                onUpdateVisitedHistory: (controller, url, isReload) {
                  if (url != null) {
                    final urlStr = url.toString();
                    ref.read(browserControllerProvider.notifier).setUrl(urlStr);
                    _urlController.text = urlStr;

                    if (urlStr.contains('youtube.com/watch') ||
                        urlStr.contains('youtu.be/')) {
                      ref
                          .read(browserControllerProvider.notifier)
                          .addVideo(urlStr);
                    }
                  }
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  final uri = navigationAction.request.url;
                  final settings = ref.read(settingsProvider);

                  if (uri != null) {
                    final s = uri.scheme.toLowerCase();
                    if (s != 'http' &&
                        s != 'https' &&
                        s != 'about' &&
                        s != 'data') {
                      debugPrint('[Browser] Bloqueando esquema: $s');
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (settings.adBlockEnabled && _adBlockList.isAdUrl(uri)) {
                      debugPrint('[AdBlock] Bloqueando: $uri');
                      return NavigationActionPolicy.CANCEL;
                    }
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onLoadResource: (controller, resource) {
                  // Pasar TODAS las URLs al detector — él decide internamente
                  // si coincide con algún patrón de streaming.
                  final url = resource.url.toString();
                  _detector.interceptNativeResource(
                    url,
                    referer: state.currentUrl,
                  );
                },
                onCreateWindow: (controller, createWindowAction) async {
                  debugPrint(
                    '[Browser] Bloqueando popup/ventana nueva: \${createWindowAction.request.url}',
                  );
                  // Retornar true indica que nosotros manejamos la creación de la ventana,
                  // pero como no hacemos nada con ella, efectivamente la destruimos/bloqueamos.
                  return true;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showVideoSheet(BuildContext context, BrowserState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _VideoListSheet(
          videos: state.candidates,
          onPlay: (v) {
            Navigator.of(context).pop();
            _processSelectedVideo(v, cast: false);
          },
          onCast: (v) {
            Navigator.of(context).pop();
            _processSelectedVideo(v, cast: true);
          },
          onClear: () {
            ref.read(browserControllerProvider.notifier).clearCandidates();
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}

class _VideoListSheet extends StatelessWidget {
  const _VideoListSheet({
    required this.videos,
    required this.onPlay,
    required this.onCast,
    required this.onClear,
  });

  final List<ClassifiedVideo> videos;
  final ValueChanged<ClassifiedVideo> onPlay;
  final ValueChanged<ClassifiedVideo> onCast;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.6),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // Handle indicator
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 16),
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.2,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Videos Encontrados',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: onClear,
                          icon: const Icon(Icons.clear_all_rounded, size: 20),
                          label: const Text('Limpiar'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      itemCount: videos.length,
                      itemBuilder: (context, index) {
                        final video = videos[index];
                        return _VideoCard(
                          video: video,
                          onPlay: () => onPlay(video),
                          onCast: () => onCast(video),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({
    required this.video,
    required this.onPlay,
    required this.onCast,
  });

  final ClassifiedVideo video;
  final VoidCallback onPlay;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAd = video.type == VideoType.ad;
    final isMain = video.type == VideoType.main;
    final isDark = theme.brightness == Brightness.dark;

    final accentColor = isAd
        ? theme.colorScheme.error
        : isMain
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.black.withValues(alpha: 0.4)
            : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (video.poster != null && video.poster!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            video.poster!,
                            width: 100,
                            height: 70,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: 100,
                                height: 70,
                                color: Colors.black26,
                                child: const Icon(
                                  Icons.image_not_supported_rounded,
                                  color: Colors.white54,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isAd
                                    ? Icons.warning_amber_rounded
                                    : isMain
                                    ? Icons.play_circle_fill
                                    : Icons.ondemand_video_rounded,
                                color: accentColor,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  isAd
                                      ? 'Posible Anuncio'
                                      : isMain
                                      ? 'Contenido Principal'
                                      : 'Video Secundario',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: accentColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            video.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (video.duration != null && video.duration! > 0)
                            _Chip(
                              icon: Icons.timer_outlined,
                              text:
                                  "${(video.duration! / 60).floor()}:${(video.duration! % 60).toInt().toString().padLeft(2, '0')} min",
                            ),
                          if (video.width != null &&
                              video.height != null &&
                              video.width! > 0)
                            _Chip(
                              icon: Icons.hd_outlined,
                              text: '${video.width}x${video.height}',
                            ),
                          if (video.source != null)
                            _Chip(
                              icon: Icons.code_rounded,
                              text: video.source!.toUpperCase(),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: onPlay,
                      icon: const Icon(Icons.play_arrow_rounded),
                      tooltip: 'Reproducir en PC',
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: onCast,
                      icon: const Icon(Icons.cast_rounded),
                      tooltip: 'Transmitir a TV',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
