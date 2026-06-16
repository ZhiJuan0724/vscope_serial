import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'update_checker.dart';

class UpdateManifest {
  final int schemaVersion;
  final String version;
  final String packageName;
  final int packageSize;
  final String sha256;
  final String executable;

  const UpdateManifest({
    required this.schemaVersion,
    required this.version,
    required this.packageName,
    required this.packageSize,
    required this.sha256,
    required this.executable,
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    return UpdateManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      version: (json['version'] ?? '').toString(),
      packageName: (json['packageName'] ?? '').toString(),
      packageSize: (json['packageSize'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] ?? '').toString().toLowerCase(),
      executable: (json['executable'] ?? '').toString(),
    );
  }

  void validateFor(ReleaseInfo release) {
    final normalizedTag = release.tagName.replaceFirst(RegExp(r'^[vV]'), '');
    if (schemaVersion != 1 ||
        version != normalizedTag ||
        packageName != 'vscope_serial-windows-${release.tagName}.zip' ||
        packageSize <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        executable != 'vscope_serial.exe') {
      throw const FormatException('更新清单无效或与发布版本不匹配');
    }
  }
}

class PreparedUpdate {
  final ReleaseInfo release;
  final UpdateManifest manifest;
  final Directory updateDirectory;
  final Directory payloadDirectory;

  const PreparedUpdate({
    required this.release,
    required this.manifest,
    required this.updateDirectory,
    required this.payloadDirectory,
  });
}

class UpdateDownloadProgress {
  final int received;
  final int total;
  final double bytesPerSecond;

  const UpdateDownloadProgress({
    required this.received,
    required this.total,
    required this.bytesPerSecond,
  });

  double? get fraction => total > 0 ? received / total : null;
}

class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);

  @override
  String toString() => message;
}

typedef ReleaseFetcher =
    Future<ReleaseInfo> Function(String tagName, String source);
typedef BytesFetcher = Future<List<int>> Function(Uri uri);
typedef UpdateFileDownloader =
    Future<void> Function(
      Uri uri,
      File destination,
      int total,
      void Function(UpdateDownloadProgress progress) onProgress,
    );

class UpdateService {
  static const _githubReleaseByTag =
      'https://api.github.com/repos/ZhiJuan0724/vscope_serial/releases/tags/';
  static const _giteeReleaseByTag =
      'https://gitee.com/api/v5/repos/ZhiJuan0724/vscope_serial/releases/tags/';

  final ReleaseFetcher _releaseFetcher;
  final BytesFetcher _bytesFetcher;
  final UpdateFileDownloader? _fileDownloader;
  final Directory? _updatesRootOverride;
  HttpClient? _downloadClient;

  UpdateService({
    ReleaseFetcher? releaseFetcher,
    BytesFetcher? bytesFetcher,
    UpdateFileDownloader? fileDownloader,
    Directory? updatesRoot,
  }) : _releaseFetcher = releaseFetcher ?? _defaultFetchRelease,
       _bytesFetcher = bytesFetcher ?? _defaultFetchBytes,
       _fileDownloader = fileDownloader,
       _updatesRootOverride = updatesRoot;

  Future<PreparedUpdate> downloadAndPrepare(
    ReleaseInfo checkedRelease, {
    required void Function(UpdateDownloadProgress progress) onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw const UpdateDownloadException('自动安装目前仅支持 Windows');
    }

    final updateDir = await _updateDirectory(checkedRelease.tagName);
    await updateDir.create(recursive: true);
    final packagePart = File('${updateDir.path}/package.zip.part');
    final packageFile = File('${updateDir.path}/package.zip');
    final payloadDir = Directory('${updateDir.path}/payload');

    Object? lastError;
    for (final source in <String>['GitHub', 'Gitee']) {
      try {
        final release =
            checkedRelease.source == source
                ? checkedRelease
                : await _releaseFetcher(checkedRelease.tagName, source);
        final manifestName = 'update-manifest-${checkedRelease.tagName}.json';
        final packageName =
            'vscope_serial-windows-${checkedRelease.tagName}.zip';
        final manifestAsset = _findAsset(release, manifestName);
        final packageAsset = _findAsset(release, packageName);
        if (manifestAsset == null || packageAsset == null) {
          throw UpdateDownloadException('$source 尚未提供完整更新附件');
        }

        final manifestBytes = await _bytesFetcher(
          Uri.parse(manifestAsset.downloadUrl),
        );
        final manifest = UpdateManifest.fromJson(
          jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>,
        )..validateFor(release);
        await File(
          '${updateDir.path}/update-manifest.json',
        ).writeAsBytes(manifestBytes, flush: true);
        if (packageAsset.size > 0 &&
            packageAsset.size != manifest.packageSize) {
          throw const UpdateDownloadException('发布附件大小与更新清单不一致');
        }

        await (_fileDownloader ?? _download)(
          Uri.parse(packageAsset.downloadUrl),
          packagePart,
          manifest.packageSize,
          onProgress,
        );
        if (await packagePart.length() != manifest.packageSize) {
          throw const UpdateDownloadException('更新包大小校验失败');
        }
        final digest = await _sha256File(packagePart);
        if (digest != manifest.sha256) {
          throw const UpdateDownloadException('更新包 SHA-256 校验失败');
        }
        if (await packageFile.exists()) await packageFile.delete();
        await packagePart.rename(packageFile.path);
        await extractPackageSafely(packageFile, payloadDir);
        _validatePayload(payloadDir, manifest);
        await File('${updateDir.path}/prepared.json').writeAsString(
          jsonEncode({
            'tagName': release.tagName,
            'version': manifest.version,
            'source': release.source,
            'preparedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        return PreparedUpdate(
          release: release,
          manifest: manifest,
          updateDirectory: updateDir,
          payloadDirectory: payloadDir,
        );
      } catch (error) {
        lastError = error;
        if (await packagePart.exists()) await packagePart.delete();
      }
    }
    throw UpdateDownloadException(
      lastError?.toString() ?? 'GitHub 和 Gitee 均无法下载更新',
    );
  }

  void cancelDownload() {
    _downloadClient?.close(force: true);
    _downloadClient = null;
  }

  Future<PreparedUpdate?> findPreparedUpdate(ReleaseInfo release) async {
    final updateDir = await _updateDirectory(release.tagName);
    final prepared = File('${updateDir.path}/prepared.json');
    final payload = Directory('${updateDir.path}/payload');
    final manifestFile = File('${updateDir.path}/update-manifest.json');
    if (!await prepared.exists() ||
        !await payload.exists() ||
        !await manifestFile.exists()) {
      return null;
    }
    final manifest = UpdateManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
    )..validateFor(release);
    return PreparedUpdate(
      release: release,
      manifest: manifest,
      updateDirectory: updateDir,
      payloadDirectory: payload,
    );
  }

  Future<PreparedUpdate?> findLatestPreparedUpdate({
    String? newerThanVersion,
  }) async {
    final root = await _updatesRoot();
    if (!await root.exists()) return null;
    final preparedFiles = <File>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('prepared.json')) {
        preparedFiles.add(entity);
      }
    }
    preparedFiles.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    for (final preparedFile in preparedFiles) {
      try {
        final preparedJson =
            jsonDecode(await preparedFile.readAsString())
                as Map<String, dynamic>;
        final directory = preparedFile.parent;
        final manifestFile = File('${directory.path}/update-manifest.json');
        final payload = Directory('${directory.path}/payload');
        if (!await manifestFile.exists() || !await payload.exists()) continue;
        final manifest = UpdateManifest.fromJson(
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
        );
        final tagName =
            (preparedJson['tagName'] ?? 'v${manifest.version}').toString();
        final release = ReleaseInfo(
          tagName: tagName,
          htmlUrl: '',
          source: (preparedJson['source'] ?? '本地已下载').toString(),
          body: '',
        );
        manifest.validateFor(release);
        if (newerThanVersion != null &&
            UpdateChecker.compareVersions(tagName, newerThanVersion) <= 0) {
          continue;
        }
        _validatePayload(payload, manifest);
        return PreparedUpdate(
          release: release,
          manifest: manifest,
          updateDirectory: directory,
          payloadDirectory: payload,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> cleanupOldUpdates() async {
    final root = await _updatesRoot();
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<String?> consumeLastResult() async {
    final root = await _updatesRoot();
    if (!await root.exists()) return null;
    final results = <File>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('result.json')) {
        results.add(entity);
      }
    }
    if (results.isEmpty) return null;
    results.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    final result = results.first;
    try {
      final json =
          jsonDecode(await result.readAsString()) as Map<String, dynamic>;
      final success = json['success'] == true;
      final message = (json['message'] ?? '').toString();
      return success
          ? '应用已成功更新到最新版本'
          : '自动更新失败${message.isEmpty ? '' : ': $message'}';
    } finally {
      await result.delete();
    }
  }

  Future<void> launchInstaller(PreparedUpdate update) async {
    if (!const bool.fromEnvironment('dart.vm.product')) {
      throw const UpdateDownloadException('Debug/Profile 构建不允许覆盖安装');
    }
    const updaterName = 'vscope_updater.exe';
    final sourceUpdater = File('${update.payloadDirectory.path}/$updaterName');
    if (!await sourceUpdater.exists()) {
      throw const UpdateDownloadException('更新包缺少外置更新器');
    }

    final updaterDir = Directory('${update.updateDirectory.path}/installer');
    await updaterDir.create(recursive: true);
    final updater = await sourceUpdater.copy('${updaterDir.path}/$updaterName');
    final installDir = File(Platform.resolvedExecutable).parent;
    final plan = File('${updaterDir.path}/update-plan.json');
    final resultFile = File('${update.updateDirectory.path}/result.json');
    await plan.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'pid': pid,
        'installDir': installDir.path,
        'payloadDir': update.payloadDirectory.path,
        'executable': update.manifest.executable,
        'resultFile': resultFile.path,
        'cleanupDir': update.updateDirectory.path,
      }),
    );
    await Process.start(
      updater.path,
      ['--plan', plan.path],
      mode: ProcessStartMode.detached,
      workingDirectory: updaterDir.path,
    );
  }

  static ReleaseAsset? _findAsset(ReleaseInfo release, String name) {
    for (final asset in release.assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  Future<void> _download(
    Uri uri,
    File destination,
    int total,
    void Function(UpdateDownloadProgress progress) onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _downloadClient = client;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'VScope Serial Updater');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final sink = destination.openWrite();
      var received = 0;
      var lastBytes = 0;
      var lastTime = DateTime.now();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          final elapsed = now.difference(lastTime);
          if (elapsed.inMilliseconds >= 250 || received == total) {
            final speed =
                (received - lastBytes) /
                (elapsed.inMilliseconds.clamp(1, 1 << 31) / 1000);
            onProgress(
              UpdateDownloadProgress(
                received: received,
                total: total,
                bytesPerSecond: speed,
              ),
            );
            lastBytes = received;
            lastTime = now;
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
      if (identical(_downloadClient, client)) _downloadClient = null;
    }
  }

  static Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static Future<void> extractPackageSafely(
    File zip,
    Directory destination,
  ) async {
    if (await destination.exists()) await destination.delete(recursive: true);
    await destination.create(recursive: true);
    final bytes = await zip.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 20000) {
      throw const FormatException('更新包文件数量异常');
    }
    final totalSize = archive.fold<int>(
      0,
      (sum, entry) => sum + (entry.isFile ? entry.size : 0),
    );
    if (totalSize > 1024 * 1024 * 1024) {
      throw const FormatException('更新包解压体积超过限制');
    }
    final root = destination.absolute.path.replaceAll('/', '\\');
    final targets = <String>{};
    for (final entry in archive) {
      final normalized = entry.name.replaceAll('\\', '/');
      final parts = normalized.split('/').where((part) => part.isNotEmpty);
      if (normalized.startsWith('/') ||
          parts.any(
            (part) => part == '.' || part == '..' || part.contains(':'),
          )) {
        throw const FormatException('更新包包含不安全路径');
      }
      final relative = parts.join('\\');
      if (relative.isEmpty) continue;
      final target = File('$root\\$relative').absolute;
      final targetPath = target.path.replaceAll('/', '\\');
      if (!targetPath.toLowerCase().startsWith('${root.toLowerCase()}\\')) {
        throw const FormatException('更新包路径越界');
      }
      if (!targets.add(targetPath.toLowerCase())) {
        throw const FormatException('更新包包含重复路径');
      }
      if (entry.isFile) {
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content as List<int>, flush: true);
      } else {
        await Directory(target.path).create(recursive: true);
      }
    }
  }

  static void _validatePayload(Directory payload, UpdateManifest manifest) {
    for (final name in [
      manifest.executable,
      'vscope_updater.exe',
      'app-files.json',
    ]) {
      if (!File('${payload.path}/$name').existsSync()) {
        throw UpdateDownloadException('更新包缺少必要文件: $name');
      }
    }
  }

  Future<Directory> _updatesRoot() async {
    if (_updatesRootOverride != null) return _updatesRootOverride;
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$localAppData/VScope Serial/updates');
  }

  Future<Directory> _updateDirectory(String tagName) async {
    final root = await _updatesRoot();
    return Directory('${root.path}/$tagName');
  }

  static Future<ReleaseInfo> _defaultFetchRelease(
    String tagName,
    String source,
  ) async {
    final base = source == 'GitHub' ? _githubReleaseByTag : _giteeReleaseByTag;
    final json = await _defaultFetchJson(Uri.parse('$base$tagName'));
    return UpdateChecker.parseReleaseJson(json, source: source);
  }

  static Future<List<int>> _defaultFetchBytes(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'VScope Serial Updater');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _defaultFetchJson(Uri uri) async {
    final bytes = await _defaultFetchBytes(uri);
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
}
