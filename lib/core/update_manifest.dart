class UpdateManifest {
  const UpdateManifest(
    this.version,
    this.build,
    this.minBuild,
    this.url,
    this.sha256,
    this.size,
  );

  final String version;
  final int build;
  final int minBuild;
  final String url;
  final String sha256;
  final int size;

  static UpdateManifest? parse(
    Object? data, {
    bool windows = false,
    String androidTarget = 'android-universal',
  }) {
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        data['app'] != 'flux' ||
        data['package'] != 'com.auralix.flux') {
      return null;
    }
    final version = data['version'];
    final build = data['build'];
    final minBuild = data['min_build'];
    if (version is! String ||
        !RegExp(
          r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
        ).hasMatch(version) ||
        build is! int ||
        build < 1 ||
        build > 209989999 ||
        minBuild is! int ||
        minBuild < 0 ||
        minBuild > build ||
        data['tag'] != 'v$version') {
      return null;
    }
    final assets = data['assets'];
    if (assets is! Map<String, dynamic>) return null;
    const suffixes = {
      'android-universal': 'universal.apk',
      'android-arm64': 'arm64.apk',
      'android-armv7': 'armv7.apk',
      'android-x86_64': 'x86_64.apk',
      'windows-x64': 'windows-x64.zip',
    };
    var target = windows ? 'windows-x64' : androidTarget;
    if (!suffixes.containsKey(target) ||
        (!windows && !target.startsWith('android-'))) {
      return null;
    }
    if (!windows && !assets.containsKey(target)) target = 'android-universal';
    final asset = assets[target];
    if (asset is! Map<String, dynamic>) return null;
    final name = 'flux-v$version-${suffixes[target]}';
    final url =
        'https://github.com/Auralix-Studio/flux/releases/download/v$version/$name';
    final hash = asset['sha256'];
    final size = asset['size'];
    if (asset['name'] != name ||
        asset['url'] != url ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        size is! int ||
        size <= 0 ||
        size > 1073741824) {
      return null;
    }
    return UpdateManifest(version, build, minBuild, url, hash, size);
  }

  bool isNewerThan(String installedVersion, int installedBuild) {
    final current = installedVersion.split('.').map(int.parse).toList();
    final offered = version.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (offered[i] != current[i]) {
        return offered[i] > current[i] && build > installedBuild;
      }
    }
    return build > installedBuild;
  }
}
