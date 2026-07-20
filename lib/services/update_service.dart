import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'app_info.dart';
import 'update_checker.dart';
import 'update_runtime_guard.dart';

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

  void validateFor(ReleaseInfo release, {bool requirePackage = true}) {
    final normalizedTag = release.tagName.replaceFirst(RegExp(r'^[vV]'), '');
    final packageValid =
        !requirePackage ||
        (packageName == 'vscope_serial-windows-${release.tagName}.zip' &&
            packageSize > 0 &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256));
    if (schemaVersion != 1 ||
        version != normalizedTag ||
        !packageValid ||
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

class RollbackUpdate {
  final UpdateChannel channel;
  final String version;
  final DateTime? createdAt;
  final UpdateManifest manifest;
  final Directory rollbackDirectory;
  final Directory payloadDirectory;

  const RollbackUpdate({
    required this.channel,
    required this.version,
    required this.createdAt,
    required this.manifest,
    required this.rollbackDirectory,
    required this.payloadDirectory,
  });

  String get tagName =>
      version.startsWith(RegExp(r'[vV]')) ? version : 'v$version';
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

class _UpdateDownloadCancelled extends UpdateDownloadException {
  const _UpdateDownloadCancelled() : super('下载已取消');
}

typedef ReleaseFetcher =
    Future<ReleaseInfo> Function(
      String tagName,
      String source,
      UpdateChannel channel,
    );
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
  final UpdateRuntimeGuard _runtimeGuard;
  HttpClient? _downloadClient;
  int _downloadGeneration = 0;
  static const _maxNetworkAttempts = 3;

  UpdateService({
    ReleaseFetcher? releaseFetcher,
    BytesFetcher? bytesFetcher,
    UpdateFileDownloader? fileDownloader,
    Directory? updatesRoot,
    UpdateRuntimeGuard? runtimeGuard,
  }) : _releaseFetcher = releaseFetcher ?? _defaultFetchRelease,
       _bytesFetcher = bytesFetcher ?? _defaultFetchBytes,
       _fileDownloader = fileDownloader,
       _updatesRootOverride = updatesRoot,
       _runtimeGuard = runtimeGuard ?? WindowsUpdateRuntimeGuard();

  Future<PreparedUpdate> downloadAndPrepare(
    ReleaseInfo checkedRelease, {
    required UpdateChannel channel,
    bool allowSourceFallback = true,
    required void Function(UpdateDownloadProgress progress) onProgress,
  }) async {
    final generation = ++_downloadGeneration;
    return _runtimeGuard.runWithUpdateLock(
      () => _downloadAndPrepareLocked(
        checkedRelease,
        generation: generation,
        channel: channel,
        allowSourceFallback: allowSourceFallback,
        onProgress: onProgress,
      ),
    );
  }

  Future<PreparedUpdate> _downloadAndPrepareLocked(
    ReleaseInfo checkedRelease, {
    required int generation,
    required UpdateChannel channel,
    bool allowSourceFallback = true,
    required void Function(UpdateDownloadProgress progress) onProgress,
  }) async {
    _throwIfDownloadCancelled(generation);
    if (!Platform.isWindows) {
      throw const UpdateDownloadException('自动安装目前仅支持 Windows');
    }

    final updateDir = await _updateDirectory(checkedRelease.tagName);
    await updateDir.create(recursive: true);
    final packagePart = File('${updateDir.path}/package.zip.part');
    final packageFile = File('${updateDir.path}/package.zip');
    final payloadDir = Directory('${updateDir.path}/payload');

    Object? lastError;
    final sources =
        allowSourceFallback
            ? [
              checkedRelease.source,
              for (final source in const ['GitHub', 'Gitee'])
                if (source != checkedRelease.source) source,
            ]
            : [checkedRelease.source];
    for (final source in sources) {
      try {
        _throwIfDownloadCancelled(generation);
        final release =
            checkedRelease.source == source
                ? checkedRelease
                : await _releaseFetcher(
                  checkedRelease.tagName,
                  source,
                  channel,
                );
        _throwIfDownloadCancelled(generation);
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
        _throwIfDownloadCancelled(generation);
        final manifest = UpdateManifest.fromJson(
          _decodeJsonObject(utf8.decode(manifestBytes), '更新清单'),
        )..validateFor(release);
        await File(
          '${updateDir.path}/update-manifest.json',
        ).writeAsBytes(manifestBytes, flush: true);
        _throwIfDownloadCancelled(generation);
        if (packageAsset.size > 0 &&
            packageAsset.size != manifest.packageSize) {
          throw const UpdateDownloadException('发布附件大小与更新清单不一致');
        }

        await _downloadWithRetry(
          Uri.parse(packageAsset.downloadUrl),
          packagePart,
          manifest.packageSize,
          onProgress,
          generation,
        );
        _throwIfDownloadCancelled(generation);
        if (await packagePart.length() != manifest.packageSize) {
          throw const UpdateDownloadException('更新包大小校验失败');
        }
        final digest = await _sha256File(packagePart);
        _throwIfDownloadCancelled(generation);
        if (digest != manifest.sha256) {
          throw const UpdateDownloadException('更新包 SHA-256 校验失败');
        }
        if (await packageFile.exists()) await packageFile.delete();
        await packagePart.rename(packageFile.path);
        await extractPackageSafely(packageFile, payloadDir);
        _throwIfDownloadCancelled(generation);
        _validatePayload(payloadDir, manifest);
        await File('${updateDir.path}/prepared.json').writeAsString(
          jsonEncode({
            'tagName': release.tagName,
            'version': manifest.version,
            'source': release.source,
            'channel': channel.value,
            'preparedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        return PreparedUpdate(
          release: release,
          manifest: manifest,
          updateDirectory: updateDir,
          payloadDirectory: payloadDir,
        );
      } on _UpdateDownloadCancelled {
        if (await packagePart.exists()) await packagePart.delete();
        rethrow;
      } catch (error) {
        _throwIfDownloadCancelled(generation);
        lastError = error;
        if (await packagePart.exists()) await packagePart.delete();
      }
    }
    throw UpdateDownloadException(
      lastError?.toString() ?? 'GitHub 和 Gitee 均无法下载更新',
    );
  }

  void cancelDownload() {
    _downloadGeneration++;
    final client = _downloadClient;
    _downloadClient = null;
    client?.close(force: true);
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
    UpdateChannel? channel,
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
        final preparedChannel = UpdateChannel.fromString(
          (preparedJson['channel'] ?? '').toString(),
        );
        if (channel != null && preparedChannel != channel) continue;
        final release = ReleaseInfo(
          tagName: tagName,
          htmlUrl: '',
          source: (preparedJson['source'] ?? '本地已下载').toString(),
          body: '',
          prerelease: preparedChannel == UpdateChannel.beta,
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
      if (entity.path == (await _rollbackRoot()).path) continue;
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

  Future<void> launchInstaller(
    PreparedUpdate update, {
    required UpdateChannel channel,
  }) async {
    await _runtimeGuard.runWithUpdateLock(
      () async {
        await _ensureNoOtherRunningInstances();
        await _launchInstaller(
          manifest: update.manifest,
          updateDirectory: update.updateDirectory,
          payloadDirectory: update.payloadDirectory,
          channel: channel,
        );
      },
    );
  }

  Future<List<RollbackUpdate>> findRollbackUpdates() async {
    final updates = <RollbackUpdate>[];
    for (final channel in UpdateChannel.values) {
      final update = await findRollbackUpdate(channel);
      if (update != null) updates.add(update);
    }
    return updates;
  }

  Future<RollbackUpdate?> findRollbackUpdate(UpdateChannel channel) async {
    final rollbackDir = await _rollbackDirectory(channel);
    final metadataFile = File('${rollbackDir.path}/rollback.json');
    final manifestFile = File('${rollbackDir.path}/update-manifest.json');
    final payload = Directory('${rollbackDir.path}/payload');
    if (!await metadataFile.exists() ||
        !await manifestFile.exists() ||
        !await payload.exists()) {
      return null;
    }
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final version = (metadata['version'] ?? '').toString();
      final manifest = UpdateManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
      );
      final release = ReleaseInfo(
        tagName: version.startsWith(RegExp(r'[vV]')) ? version : 'v$version',
        htmlUrl: '',
        source: '本地回退',
        body: '',
        prerelease: channel == UpdateChannel.beta,
      );
      manifest.validateFor(release, requirePackage: false);
      _validatePayload(payload, manifest);
      return RollbackUpdate(
        channel: channel,
        version: version,
        createdAt: DateTime.tryParse((metadata['createdAt'] ?? '').toString()),
        manifest: manifest,
        rollbackDirectory: rollbackDir,
        payloadDirectory: payload,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> launchRollbackInstaller(RollbackUpdate update) async {
    await _runtimeGuard.runWithUpdateLock(
      () async {
        await _ensureNoOtherRunningInstances();
        final stagingDir = await _rollbackInstallDirectory(update.channel);
        if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
        await stagingDir.create(recursive: true);
        final stagedPayload = Directory('${stagingDir.path}/payload');
        await _copyDirectory(update.payloadDirectory, stagedPayload);
        await File(
          '${update.rollbackDirectory.path}/update-manifest.json',
        ).copy('${stagingDir.path}/update-manifest.json');
        await _launchInstaller(
          manifest: update.manifest,
          updateDirectory: stagingDir,
          payloadDirectory: stagedPayload,
          channel: update.channel,
        );
      },
    );
  }

  Future<List<int>> findOtherRunningInstanceProcessIds() =>
      _runtimeGuard.findOtherInstanceProcessIds();

  Future<void> requestCloseOtherRunningInstances(List<int> processIds) =>
      _runtimeGuard.requestCloseProcesses(processIds);

  Future<bool> waitForOtherRunningInstancesToExit(Duration timeout) =>
      _runtimeGuard.waitForOtherInstancesToExit(timeout);

  Future<void> _ensureNoOtherRunningInstances() async {
    final otherInstances = await _runtimeGuard.findOtherInstanceProcessIds();
    if (otherInstances.isNotEmpty) {
      throw const UpdateDownloadException('请先关闭其他 Vscope Serial 窗口后再更新或回退');
    }
  }

  Future<void> _launchInstaller({
    required UpdateManifest manifest,
    required Directory updateDirectory,
    required Directory payloadDirectory,
    required UpdateChannel channel,
  }) async {
    if (!const bool.fromEnvironment('dart.vm.product')) {
      throw const UpdateDownloadException('Debug/Profile 构建不允许覆盖安装');
    }
    const updaterName = 'vscope_updater.exe';
    final sourceUpdater = File('${payloadDirectory.path}/$updaterName');
    if (!await sourceUpdater.exists()) {
      throw const UpdateDownloadException('更新包缺少外置更新器');
    }

    final updaterDir = Directory('${updateDirectory.path}/installer');
    await updaterDir.create(recursive: true);
    final updater = await sourceUpdater.copy('${updaterDir.path}/$updaterName');
    final installDir = File(Platform.resolvedExecutable).parent;
    final plan = File('${updaterDir.path}/update-plan.json');
    final resultFile = File('${updateDirectory.path}/result.json');
    final rollbackDir = await _rollbackDirectory(channel);
    await plan.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'pid': pid,
        'installDir': installDir.path,
        'payloadDir': payloadDirectory.path,
        'executable': manifest.executable,
        'resultFile': resultFile.path,
        'cleanupDir': updateDirectory.path,
        'rollbackDir': rollbackDir.path,
        'rollbackChannel': channel.value,
        'currentVersion': await AppInfo.version(),
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
    int generation,
  ) async {
    _throwIfDownloadCancelled(generation);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _downloadClient = client;
    try {
      final request = await client.getUrl(uri);
      _throwIfDownloadCancelled(generation);
      request.headers.set(HttpHeaders.userAgentHeader, 'SerialTools Updater');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      _throwIfDownloadCancelled(generation);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final sink = destination.openWrite();
      var received = 0;
      var lastBytes = 0;
      var lastTime = DateTime.now();
      try {
        await for (final chunk in response) {
          _throwIfDownloadCancelled(generation);
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
        _throwIfDownloadCancelled(generation);
      } finally {
        await sink.close();
      }
    } finally {
      _closeClientSilently(client);
      if (identical(_downloadClient, client)) _downloadClient = null;
    }
  }

  Future<void> _downloadWithRetry(
    Uri uri,
    File destination,
    int total,
    void Function(UpdateDownloadProgress progress) onProgress,
    int generation,
  ) async {
    _throwIfDownloadCancelled(generation);
    final fileDownloader = _fileDownloader;
    if (fileDownloader != null) {
      await fileDownloader(uri, destination, total, onProgress);
      _throwIfDownloadCancelled(generation);
      return;
    }

    Object? lastError;
    for (var attempt = 1; attempt <= _maxNetworkAttempts; attempt++) {
      try {
        _throwIfDownloadCancelled(generation);
        if (await destination.exists()) await destination.delete();
        await _download(uri, destination, total, onProgress, generation);
        _throwIfDownloadCancelled(generation);
        return;
      } on _UpdateDownloadCancelled {
        if (await destination.exists()) await destination.delete();
        rethrow;
      } catch (error) {
        _throwIfDownloadCancelled(generation);
        lastError = error;
        if (await destination.exists()) await destination.delete();
        if (attempt == _maxNetworkAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    throw UpdateDownloadException(
      '更新包下载失败，已重试 $_maxNetworkAttempts 次：$lastError',
    );
  }

  void _throwIfDownloadCancelled(int generation) {
    if (generation != _downloadGeneration) {
      throw const _UpdateDownloadCancelled();
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
    final executable = File(Platform.resolvedExecutable);
    return Directory('${executable.parent.path}/updates');
  }

  Future<Directory> _updateDirectory(String tagName) async {
    final root = await _updatesRoot();
    return Directory('${root.path}/$tagName');
  }

  Future<Directory> _rollbackRoot() async {
    final root = await _updatesRoot();
    return Directory('${root.path}/rollback');
  }

  Future<Directory> _rollbackDirectory(UpdateChannel channel) async {
    final root = await _rollbackRoot();
    return Directory('${root.path}/${channel.value}');
  }

  Future<Directory> _rollbackInstallDirectory(UpdateChannel channel) async {
    final root = await _updatesRoot();
    return Directory('${root.path}/rollback-install-${channel.value}');
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relative = entity.path.substring(source.path.length);
      final targetPath = '${destination.path}$relative';
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }

  static Future<ReleaseInfo> _defaultFetchRelease(
    String tagName,
    String source,
    UpdateChannel channel,
  ) async {
    final base = source == 'GitHub' ? _githubReleaseByTag : _giteeReleaseByTag;
    final json = await _defaultFetchJson(Uri.parse('$base$tagName'));
    return UpdateChecker.parseReleaseJson(
      json,
      source: source,
      channel: channel,
    );
  }

  static Future<List<int>> _defaultFetchBytes(Uri uri) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxNetworkAttempts; attempt++) {
      final client =
          HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, 'SerialTools Updater');
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
      } catch (error) {
        lastError = error;
        if (attempt == _maxNetworkAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      } finally {
        _closeClientSilently(client);
      }
    }
    throw UpdateDownloadException(
      '下载数据失败，已重试 $_maxNetworkAttempts 次：$lastError',
    );
  }

  static Future<Map<String, dynamic>> _defaultFetchJson(Uri uri) async {
    final bytes = await _defaultFetchBytes(uri);
    return _decodeJsonObject(utf8.decode(bytes), '接口响应');
  }

  static Map<String, dynamic> _decodeJsonObject(String content, String label) {
    final json = jsonDecode(content);
    if (json is Map) return Map<String, dynamic>.from(json);
    throw FormatException('$label格式不正确');
  }

  static void _closeClientSilently(HttpClient client) {
    try {
      client.close();
    } catch (_) {
      // 释放 client 时网络流可能迟到抛出连接关闭错误。
      // 上面的请求体处理负责重试和错误路径，因此释放阶段不能覆盖更有用的失败原因。
    }
  }
}
