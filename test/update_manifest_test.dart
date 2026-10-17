import 'package:flutter_test/flutter_test.dart';
import 'package:flux/core/update_manifest.dart';

Map<String, dynamic> fixture() => {
  'schema': 1,
  'app': 'flux',
  'package': 'com.auralix.flux',
  'version': '1.2.3',
  'build': 10,
  'min_build': 0,
  'tag': 'v1.2.3',
  'assets': {
    for (final entry in {
      'android-universal': 'universal.apk',
      'android-arm64': 'arm64.apk',
      'windows-x64': 'windows-x64.zip',
    }.entries)
      entry.key: {
        'name': 'flux-v1.2.3-${entry.value}',
        'url':
            'https://github.com/Auralix-Studio/flux/releases/download/v1.2.3/flux-v1.2.3-${entry.value}',
        'sha256': 'a' * 64,
        'size': 1024,
      },
  },
};

void main() {
  test('chooses the device ABI, universal fallback and Windows ZIP', () {
    expect(
      UpdateManifest.parse(fixture(), androidTarget: 'android-arm64')!.url,
      endsWith('-arm64.apk'),
    );
    expect(
      UpdateManifest.parse(fixture(), androidTarget: 'android-armv7')!.url,
      endsWith('-universal.apk'),
    );
    expect(
      UpdateManifest.parse(fixture(), windows: true)!.url,
      endsWith('-windows-x64.zip'),
    );
    expect(
      UpdateManifest.parse(fixture(), androidTarget: 'windows-x64'),
      isNull,
    );
    final androidOnly = fixture();
    (androidOnly['assets'] as Map).remove('windows-x64');
    expect(UpdateManifest.parse(androidOnly, windows: true), isNull);
  });
  test('never offers downgrades or non-increasing Android builds', () {
    final manifest = UpdateManifest.parse(fixture())!;
    expect(manifest.isNewerThan('1.2.3', 9), isTrue);
    expect(manifest.isNewerThan('1.2.3', 10), isFalse);
    expect(manifest.isNewerThan('1.0.0', 11), isFalse);
    expect(manifest.isNewerThan('2.0.0', 1), isFalse);
  });
  test('rejects mismatched application, tag, schema and build', () {
    for (final entry in <String, dynamic>{
      'schema': 2,
      'package': 'com.aur.flux',
      'app': 'mediakeep',
      'version': '../1.2.3',
      'tag': 'v1.0.0',
      'build': 209990000,
      'min_build': 11,
    }.entries) {
      expect(
        UpdateManifest.parse(fixture()..[entry.key] = entry.value),
        isNull,
        reason: entry.key,
      );
    }
  });
  test(
    'rejects hostile URLs, modified filenames, malformed hashes and sizes',
    () {
      for (final entry in <String, dynamic>{
        'url': 'https://example.org/flux.apk',
        'name': '../flux.apk',
        'sha256': 42,
        'size': -1,
      }.entries) {
        final json = fixture();
        (json['assets']['android-universal'] as Map)[entry.key] = entry.value;
        expect(UpdateManifest.parse(json), isNull, reason: entry.key);
      }
    },
  );
}
