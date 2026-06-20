import 'dart:convert';
import 'dart:io';

import 'app_info.dart';

enum UpdateChannel {
  stable('stable', '稳定版'),
  beta('beta', 'Beta');

  final String value;
  final String label;

  const UpdateChannel(this.value, this.label);

  static UpdateChannel fromString(String value) {
    return value == beta.value ? beta : stable;
  }
}

enum UpdateReleaseSource {
  github('GitHub'),
  gitee('Gitee');

  final String label;

  const UpdateReleaseSource(this.label);

  static UpdateReleaseSource fromString(String value) {
    return switch (value.trim().toLowerCase()) {
      'github' => github,
      'gitee' => gitee,
      _ => throw ArgumentError('Unknown update source: $value'),
    };
  }
}

class ReleaseAsset {
  final String name;
  final int size;
  final String downloadUrl;
  final String? digest;

  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
    this.digest,
  });
}

class ReleaseInfo {
  final String tagName;
  final String htmlUrl;
  final String source;
  final String body;
  final bool prerelease;
  final List<ReleaseAsset> assets;

  const ReleaseInfo({
    required this.tagName,
    required this.htmlUrl,
    required this.source,
    required this.body,
    this.prerelease = false,
    this.assets = const [],
  });

  UpdateChannel get channel =>
      UpdateChecker.isBetaTag(tagName)
          ? UpdateChannel.beta
          : UpdateChannel.stable;
}

class UpdateCheckResult {
  final ReleaseInfo? latestRelease;
  final bool hasUpdate;
  final String? error;

  const UpdateCheckResult._({
    required this.latestRelease,
    required this.hasUpdate,
    required this.error,
  });

  factory UpdateCheckResult.available(ReleaseInfo release) {
    return UpdateCheckResult._(
      latestRelease: release,
      hasUpdate: true,
      error: null,
    );
  }

  factory UpdateCheckResult.latest(ReleaseInfo release) {
    return UpdateCheckResult._(
      latestRelease: release,
      hasUpdate: false,
      error: null,
    );
  }

  factory UpdateCheckResult.failed(String error) {
    return UpdateCheckResult._(
      latestRelease: null,
      hasUpdate: false,
      error: error,
    );
  }
}

class UpdateChecker {
  static const _githubLatestReleaseUrl =
      'https://api.github.com/repos/ZhiJuan0724/vscope_serial/releases/latest';
  static const _giteeLatestReleaseUrl =
      'https://gitee.com/api/v5/repos/ZhiJuan0724/vscope_serial/releases/latest';
  static const _githubReleasesUrl =
      'https://api.github.com/repos/ZhiJuan0724/vscope_serial/releases?per_page=30';
  static const _giteeReleasesUrl =
      'https://gitee.com/api/v5/repos/ZhiJuan0724/vscope_serial/releases?per_page=30';
  static const _githubReleasePage =
      'https://github.com/ZhiJuan0724/vscope_serial/releases';
  static const _giteeReleasePage =
      'https://gitee.com/ZhiJuan0724/vscope_serial/releases';

  final Future<dynamic> Function(Uri uri) _fetchJson;

  UpdateChecker({Future<dynamic> Function(Uri uri)? fetchJson})
    : _fetchJson = fetchJson ?? _defaultFetchJson;

  Future<UpdateCheckResult> check({
    UpdateChannel channel = UpdateChannel.stable,
    UpdateReleaseSource? source,
  }) async {
    final currentVersion = await AppInfo.version();
    final release =
        source == null
            ? await _tryFetchLatestRelease(channel)
            : await _tryFetchLatestReleaseFromSource(channel, source);
    if (release == null) {
      return UpdateCheckResult.failed(
        _checkFailedMessage(channel: channel, source: source),
      );
    }

    if (compareVersions(release.tagName, currentVersion) > 0) {
      return UpdateCheckResult.available(release);
    }
    return UpdateCheckResult.latest(release);
  }

  Future<ReleaseInfo?> _tryFetchLatestRelease(UpdateChannel channel) async {
    try {
      final release = await _fetchLatestFrom(
        channel: channel,
        source: 'GitHub',
        latestUrl: _githubLatestReleaseUrl,
        releasesUrl: _githubReleasesUrl,
        fallbackPage: _githubReleasePage,
      );
      if (release != null) return release;
    } catch (_) {
      // 继续尝试下面的镜像源。
    }
    try {
      return await _fetchLatestFrom(
        channel: channel,
        source: 'Gitee',
        latestUrl: _giteeLatestReleaseUrl,
        releasesUrl: _giteeReleasesUrl,
        fallbackPage: _giteeReleasePage,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ReleaseInfo?> _tryFetchLatestReleaseFromSource(
    UpdateChannel channel,
    UpdateReleaseSource source,
  ) async {
    try {
      return await switch (source) {
        UpdateReleaseSource.github => _fetchLatestFrom(
          channel: channel,
          source: source.label,
          latestUrl: _githubLatestReleaseUrl,
          releasesUrl: _githubReleasesUrl,
          fallbackPage: _githubReleasePage,
        ),
        UpdateReleaseSource.gitee => _fetchLatestFrom(
          channel: channel,
          source: source.label,
          latestUrl: _giteeLatestReleaseUrl,
          releasesUrl: _giteeReleasesUrl,
          fallbackPage: _giteeReleasePage,
        ),
      };
    } catch (_) {
      return null;
    }
  }

  Future<ReleaseInfo?> _fetchLatestFrom({
    required UpdateChannel channel,
    required String source,
    required String latestUrl,
    required String releasesUrl,
    required String fallbackPage,
  }) async {
    if (channel == UpdateChannel.stable) {
      final json = await _fetchJson(Uri.parse(latestUrl));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('release response is not an object');
      }
      return parseReleaseJson(
        json,
        source: source,
        channel: channel,
        fallbackPage: fallbackPage,
      );
    }

    final json = await _fetchJson(Uri.parse(releasesUrl));
    if (json is! List) {
      throw const FormatException('release list response is not an array');
    }
    final releases = <ReleaseInfo>[];
    for (final item in json.whereType<Map>()) {
      try {
        releases.add(
          parseReleaseJson(
            Map<String, dynamic>.from(item),
            source: source,
            channel: channel,
            fallbackPage: fallbackPage,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    releases.sort((a, b) => compareVersions(b.tagName, a.tagName));
    return releases.isEmpty ? null : releases.first;
  }

  static ReleaseInfo parseReleaseJson(
    Map<String, dynamic> json, {
    required String source,
    UpdateChannel channel = UpdateChannel.stable,
    String? fallbackPage,
  }) {
    final tagName = (json['tag_name'] ?? json['tagName'] ?? '').toString();
    final htmlUrl = (json['html_url'] ?? json['htmlUrl'] ?? '').toString();
    final body = (json['body'] ?? '').toString();
    final prerelease = json['prerelease'] == true;
    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (asset) => ReleaseAsset(
            name: (asset['name'] ?? '').toString(),
            size: (asset['size'] as num?)?.toInt() ?? 0,
            downloadUrl:
                (asset['browser_download_url'] ??
                        asset['browserDownloadUrl'] ??
                        '')
                    .toString(),
            digest: asset['digest']?.toString(),
          ),
        )
        .where((asset) => asset.name.isNotEmpty && asset.downloadUrl.isNotEmpty)
        .toList(growable: false);

    if (json['draft'] == true) {
      throw const FormatException('draft release is not supported');
    }
    if (!_tagMatchesChannel(tagName, channel, prerelease)) {
      throw const FormatException('release tag_name does not match channel');
    }
    return ReleaseInfo(
      tagName: tagName,
      htmlUrl:
          htmlUrl.isNotEmpty
              ? htmlUrl
              : fallbackPage == null
              ? ''
              : '$fallbackPage/tag/$tagName',
      source: source,
      body: body,
      prerelease: prerelease,
      assets: assets,
    );
  }

  static bool isStableTag(String value) {
    return RegExp(r'^v\d+\.\d+\.\d+$', caseSensitive: false).hasMatch(value);
  }

  static bool isBetaTag(String value) {
    return RegExp(
      r'^v\d+\.\d+\.\d+-beta\.\d+$',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static bool _tagMatchesChannel(
    String tagName,
    UpdateChannel channel,
    bool prerelease,
  ) {
    return switch (channel) {
      UpdateChannel.stable => isStableTag(tagName) && !prerelease,
      UpdateChannel.beta => isBetaTag(tagName),
    };
  }

  static String _checkFailedMessage({
    required UpdateChannel channel,
    required UpdateReleaseSource? source,
  }) {
    final sourceLabel = source?.label ?? 'GitHub 或 Gitee';
    return channel == UpdateChannel.beta
        ? '无法连接 $sourceLabel 检查 Beta 更新'
        : '无法连接 $sourceLabel 检查更新';
  }

  static Future<dynamic> _defaultFetchJson(Uri uri) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    try {
      final currentVersion = await AppInfo.version();
      final request = await client.getUrl(uri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'VScope Serial/$currentVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  static int compareVersions(String left, String right) {
    return _ParsedVersion.parse(left).compareTo(_ParsedVersion.parse(right));
  }
}

class _ParsedVersion implements Comparable<_ParsedVersion> {
  final int major;
  final int minor;
  final int patch;
  final int? beta;

  const _ParsedVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.beta,
  });

  factory _ParsedVersion.parse(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?(?:\+.*)?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match == null) {
      final parts = normalized
          .split(RegExp(r'[-+]'))
          .first
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList(growable: false);
      return _ParsedVersion(
        major: parts.isNotEmpty ? parts[0] : 0,
        minor: parts.length > 1 ? parts[1] : 0,
        patch: parts.length > 2 ? parts[2] : 0,
        beta: null,
      );
    }
    return _ParsedVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      beta: match.group(4) == null ? null : int.parse(match.group(4)!),
    );
  }

  @override
  int compareTo(_ParsedVersion other) {
    final main = [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ].firstWhere((value) => value != 0, orElse: () => 0);
    if (main != 0) return main;
    if (beta == null && other.beta == null) return 0;
    if (beta == null) return 1;
    if (other.beta == null) return -1;
    return beta!.compareTo(other.beta!);
  }
}
