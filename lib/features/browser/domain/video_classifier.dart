import 'ad_block_list.dart';

enum VideoType { main, ad, unknown }

class ClassifiedVideo {
  ClassifiedVideo({
    required this.url,
    required this.type,
    this.confidence = 0.0,
    this.duration,
    this.referer,
    this.width,
    this.height,
    this.source,
    this.poster,
  });

  final String url;
  final VideoType type;
  final double confidence; // 0.0 to 1.0
  final double? duration;
  final String? referer;
  final int? width;
  final int? height;
  final String? source;
  final String? poster;
}

class VideoClassifier {
  VideoClassifier({AdBlockList? adBlockList})
    : _adBlockList = adBlockList ?? AdBlockList();

  final AdBlockList _adBlockList;

  ClassifiedVideo classify(
    String url, {
    double? duration,
    bool isLikelyAd = false,
    String? referer,
    int? width,
    int? height,
    String? source,
    String? poster,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return ClassifiedVideo(
        url: url,
        type: VideoType.unknown,
        referer: referer,
        width: width,
        height: height,
        source: source,
        poster: poster,
      );
    }

    // 1. Si el detector ya lo marcó como anuncio (por dominio o duración corta)
    if (isLikelyAd) {
      return ClassifiedVideo(
        url: url,
        type: VideoType.ad,
        confidence: 0.85,
        duration: duration,
        referer: referer,
        width: width,
        height: height,
        source: source,
        poster: poster,
      );
    }

    // 2. Check if it's from a known ad domain
    if (_adBlockList.isAdUrl(uri)) {
      return ClassifiedVideo(
        url: url,
        type: VideoType.ad,
        confidence: 0.9,
        duration: duration,
        referer: referer,
        width: width,
        height: height,
        source: source,
        poster: poster,
      );
    }

    // Duration alone does not identify an advertisement.
    if (duration != null && duration >= 90) {
      return ClassifiedVideo(
        url: url,
        type: VideoType.main,
        confidence: 0.7,
        duration: duration,
        referer: referer,
        width: width,
        height: height,
        source: source,
        poster: poster,
      );
    }

    // 4. Fallback based on URL patterns
    final path = uri.path.toLowerCase();
    if (RegExp(r'(^|[/_.-])(ads?|sponsor|preroll)([/_.-]|$)').hasMatch(path)) {
      return ClassifiedVideo(
        url: url,
        type: VideoType.ad,
        confidence: 0.6,
        duration: duration,
        referer: referer,
        width: width,
        height: height,
        source: source,
        poster: poster,
      );
    }

    return ClassifiedVideo(
      url: url,
      type: VideoType.unknown,
      confidence: 0.0,
      duration: duration,
      referer: referer,
      width: width,
      height: height,
      source: source,
      poster: poster,
    );
  }
}
