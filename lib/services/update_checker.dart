import 'dart:convert';
import 'dart:io';

import 'app_info.dart';

class ReleaseInfo {
  final String tagName;
  final String htmlUrl;
  final String source;
  final String body;

  const ReleaseInfo({
    required this.tagName,
    required this.htmlUrl,
    required this.source,
    required this.body,
  });
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
  static const _githubReleasePage =
      'https://github.com/ZhiJuan0724/vscope_serial/releases';
  static const _giteeReleasePage =
      'https://gitee.com/ZhiJuan0724/vscope_serial/releases';

  final Future<Map<String, dynamic>> Function(Uri uri) _fetchJson;

  UpdateChecker({Future<Map<String, dynamic>> Function(Uri uri)? fetchJson})
    : _fetchJson = fetchJson ?? _defaultFetchJson;

  Future<UpdateCheckResult> check() async {
    final currentVersion = await AppInfo.version();
    final release = await _tryFetchLatestRelease();
    if (release == null) {
      return UpdateCheckResult.failed('无法连接 GitHub 或 Gitee 检查更新');
    }

    if (_compareVersions(release.tagName, currentVersion) > 0) {
      return UpdateCheckResult.available(release);
    }
    return UpdateCheckResult.latest(release);
  }

  Future<ReleaseInfo?> _tryFetchLatestRelease() async {
    try {
      final json = await _fetchJson(Uri.parse(_githubLatestReleaseUrl));
      return _parseRelease(
        json,
        source: 'GitHub',
        fallbackPage: _githubReleasePage,
      );
    } catch (_) {
      try {
        final json = await _fetchJson(Uri.parse(_giteeLatestReleaseUrl));
        return _parseRelease(
          json,
          source: 'Gitee',
          fallbackPage: _giteeReleasePage,
        );
      } catch (_) {
        return null;
      }
    }
  }

  static ReleaseInfo _parseRelease(
    Map<String, dynamic> json, {
    required String source,
    required String fallbackPage,
  }) {
    final tagName = (json['tag_name'] ?? json['tagName'] ?? '').toString();
    final htmlUrl = (json['html_url'] ?? json['htmlUrl'] ?? '').toString();
    final body = (json['body'] ?? '').toString();
    if (tagName.isEmpty) {
      throw const FormatException('release tag_name is empty');
    }
    return ReleaseInfo(
      tagName: tagName,
      htmlUrl: htmlUrl.isNotEmpty ? htmlUrl : '$fallbackPage/tag/$tagName',
      source: source,
      body: body,
    );
  }

  static Future<Map<String, dynamic>> _defaultFetchJson(Uri uri) async {
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
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('release response is not an object');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  static int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final length =
        leftParts.length > rightParts.length
            ? leftParts.length
            : rightParts.length;
    for (var i = 0; i < length; i++) {
      final l = i < leftParts.length ? leftParts[i] : 0;
      final r = i < rightParts.length ? rightParts[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final main = normalized.split(RegExp(r'[-+]')).first;
    return main
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}
