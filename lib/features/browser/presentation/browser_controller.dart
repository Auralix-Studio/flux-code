import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/video_classifier.dart';
import '../data/youtube_extractor.dart';

class BrowserState {
  const BrowserState({
    this.candidates = const [],
    this.isLoading = false,
    this.currentUrl = '',
  });

  final List<ClassifiedVideo> candidates;
  final bool isLoading;
  final String currentUrl;

  BrowserState copyWith({
    List<ClassifiedVideo>? candidates,
    bool? isLoading,
    String? currentUrl,
  }) {
    return BrowserState(
      candidates: candidates ?? this.candidates,
      isLoading: isLoading ?? this.isLoading,
      currentUrl: currentUrl ?? this.currentUrl,
    );
  }
}

class BrowserController extends Notifier<BrowserState> {
  late final VideoClassifier _classifier;
  final Set<String> _extracting = {};
  int _generation = 0;

  @override
  BrowserState build() {
    _classifier = VideoClassifier();
    return const BrowserState();
  }

  void setLoading(bool loading) {
    state = state.copyWith(isLoading: loading);
  }

  void setUrl(String url) {
    state = state.copyWith(currentUrl: url);
  }

  void clearCandidates() {
    _generation++;
    state = state.copyWith(candidates: []);
  }

  Future<void> addVideo(
    String url, {
    double? duration,
    String? source,
    int? width,
    int? height,
    bool isLikelyAd = false,
    String? referer,
    String? poster,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty)
      return;
    if (state.candidates.any((v) => v.url == url)) return;
    // 1. YouTube extractor
    if (YouTubeExtractor.isYouTubeUrl(url)) {
      if (!_extracting.add(url)) return;
      final generation = _generation;
      try {
        final ytVideo = await YouTubeExtractor.extractVideo(url);
        if (ref.mounted && generation == _generation && ytVideo != null) {
          _insertCandidate(ytVideo);
        }
      } finally {
        _extracting.remove(url);
      }
      return;
    }

    // 2. Generic Classifier
    final classified = _classifier.classify(
      url,
      duration: duration,
      isLikelyAd: isLikelyAd,
      referer: referer,
      width: width,
      height: height,
      source: source,
      poster: poster,
    );

    // Verify on selection, with the browser headers, instead of probing every resource.
    _insertCandidate(classified);
  }

  void _insertCandidate(ClassifiedVideo classified) {
    // Evitar duplicados exactos en la lista final mostrada
    final exists = state.candidates.any((c) => c.url == classified.url);
    if (!exists) {
      final updated = List<ClassifiedVideo>.from(state.candidates)
        ..add(classified);

      // Ordenar: Main primero, Unknown después, Ads al final.
      // Dentro de cada grupo, mayor confianza o duración primero.
      updated.sort((a, b) {
        if (a.type != b.type) {
          if (a.type == VideoType.main) return -1;
          if (b.type == VideoType.main) return 1;
          if (a.type == VideoType.ad) return 1;
          if (b.type == VideoType.ad) return -1;
        }
        final confCompare = b.confidence.compareTo(a.confidence);
        if (confCompare != 0) return confCompare;

        final aDur = a.duration ?? 0.0;
        final bDur = b.duration ?? 0.0;
        return bDur.compareTo(aDur);
      });

      state = state.copyWith(candidates: updated);
    }
  }
}

final browserControllerProvider =
    NotifierProvider<BrowserController, BrowserState>(
      () => BrowserController(),
    );
