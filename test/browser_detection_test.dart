import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flux/features/browser/data/video_detector.dart';
import 'package:flux/features/browser/domain/video_classifier.dart';

void main() {
  test('Short videos and download paths are not advertisements', () {
    final classifier = VideoClassifier();
    expect(
      classifier
          .classify('https://example.com/download/road.mp4', duration: 15)
          .type,
      VideoType.unknown,
    );
    expect(
      classifier.classify('https://example.com/ads/preroll.mp4').type,
      VideoType.ad,
    );
  });

  test(
    'Detector excludes segments and non-network schemes and deduplicates',
    () {
      final videos = <String>[];
      final detector = VideoDetector(
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
              videos.add(url);
            },
      );
      for (final url in [
        'file:///video.mp4',
        'https://example.com/live/1.ts',
        'https://example.com/live/1.m4s',
        'https://example.com/master.m3u8#one',
        'https://example.com/master.m3u8#two',
      ]) {
        detector.handleMessage([
          jsonEncode({'url': url}),
        ]);
      }
      expect(videos, ['https://example.com/master.m3u8']);
      detector.clear();
      detector.interceptNativeResource('https://example.com/master.m3u8');
      expect(videos.length, 2);
    },
  );

  test(
    'Native detection retains referer and short media remains selectable',
    () {
      String? capturedReferer;
      bool? ad;
      final detector = VideoDetector(
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
              capturedReferer = referer;
              ad = isLikelyAd;
            },
      );
      detector.interceptNativeResource(
        'https://example.com/video.mp4',
        referer: 'https://example.com/watch',
      );
      expect(capturedReferer, 'https://example.com/watch');
      detector.handleMessage([
        jsonEncode({'url': 'https://example.com/short.mp4', 'duration': 20}),
      ]);
      expect(ad, false);
    },
  );
}
