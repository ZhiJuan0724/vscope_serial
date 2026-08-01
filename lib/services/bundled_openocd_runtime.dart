import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/app_logger.dart';

/// 内置 OpenOCD 压缩运行时的准备状态。
class BundledOpenOcdPreparationState {
  const BundledOpenOcdPreparationState({
    required this.preparing,
    this.message = '',
  });

  const BundledOpenOcdPreparationState.idle() : preparing = false, message = '';

  final bool preparing;
  final String message;
}

/// 校验并按需解压随应用发布的 OpenOCD 运行时。
///
/// 发布包只携带一个 ZIP 和一个清单。首次使用时解压到程序运行目录，完成前
/// 始终使用临时目录，校验完整后再原子切换，避免中断留下可被误用的半成品。
class BundledOpenOcdRuntime extends ChangeNotifier {
  factory BundledOpenOcdRuntime() => _instance;

  BundledOpenOcdRuntime.forTesting({
    required Directory bundleDirectory,
    Directory? cacheRoot,
  }) : _bundleDirectoryOverride = bundleDirectory,
       _cacheRootOverride =
           cacheRoot ??
           Directory(
             '${bundleDirectory.path}${Platform.pathSeparator}extracted',
           );

  BundledOpenOcdRuntime._()
    : _bundleDirectoryOverride = null,
      _cacheRootOverride = null;

  static final BundledOpenOcdRuntime _instance = BundledOpenOcdRuntime._();
  static const String manifestFileName = 'openocd-runtime.json';
  static const int manifestSchemaVersion = 1;
  static const List<String> _requiredPaths = [
    'bin/openocd.exe',
    'bin/libftdi1.dll',
    'bin/libusb-1.0.dll',
    'openocd/scripts/interface',
    'openocd/scripts/target',
  ];

  final Directory? _bundleDirectoryOverride;
  final Directory? _cacheRootOverride;
  BundledOpenOcdPreparationState _state =
      const BundledOpenOcdPreparationState.idle();
  Future<String?>? _preparation;
  String? _readyExecutable;

  BundledOpenOcdPreparationState get state => _state;

  /// 返回可执行文件路径；发布包没有压缩运行时时返回 null，由调用方继续查找
  /// 开发环境或旧版本的已解压目录。
  Future<String?> ensureReady() {
    final ready = _readyExecutable;
    if (ready != null && _isRuntimeCompleteSync(File(ready).parent.parent)) {
      return Future.value(ready);
    }
    final active = _preparation;
    if (active != null) return active;
    final future = _ensureReady();
    _preparation = future;
    return future.whenComplete(() {
      if (identical(_preparation, future)) _preparation = null;
    });
  }

  Future<String?> _ensureReady() async {
    final bundleDirectory = await _findBundleDirectory();
    if (bundleDirectory == null) return null;
    final manifest = await _readManifest(bundleDirectory);
    // Debug 运行时可能借用 Release 目录中的压缩包，但解压产物必须始终
    // 属于当前可执行文件，不能因压缩包来源不同而写入另一个构建目录。
    final cacheRoot = _cacheRootOverride ?? _currentExecutableCacheRoot();
    try {
      await cacheRoot.create(recursive: true);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        '无法在程序目录准备内置 OpenOCD，请检查目录写入权限',
        cacheRoot.path,
        error.osError,
      );
    }
    final cacheDirectory = Directory(
      _join(
        cacheRoot.path,
        '${_safeSegment(manifest.version)}-${manifest.sha256.substring(0, 12)}',
      ),
    );
    final cachedExecutable = await _validatedExecutable(
      cacheDirectory,
      manifest.sha256,
    );
    if (cachedExecutable != null) {
      _readyExecutable = cachedExecutable;
      return cachedExecutable;
    }

    _setState(
      const BundledOpenOcdPreparationState(
        preparing: true,
        message: '正在准备内置 OpenOCD，首次使用需要解压运行文件，请稍候…',
      ),
    );
    final lockFile = File(_join(cacheRoot.path, '.prepare.lock'));
    RandomAccessFile? lock;
    try {
      try {
        lock = await lockFile.open(mode: FileMode.append);
      } on FileSystemException catch (error) {
        throw FileSystemException(
          '无法在程序目录准备内置 OpenOCD，请检查目录写入权限',
          cacheRoot.path,
          error.osError,
        );
      }
      await lock.lock(FileLock.exclusive);
      // 另一应用实例可能在等待锁期间已经完成解压，取得锁后必须重新检查。
      final readyAfterLock = await _validatedExecutable(
        cacheDirectory,
        manifest.sha256,
      );
      if (readyAfterLock != null) {
        _readyExecutable = readyAfterLock;
        return readyAfterLock;
      }

      final archive = File(_join(bundleDirectory.path, manifest.archiveName));
      await _validateArchive(archive, manifest);
      final temporaryDirectory = Directory(
        '${cacheDirectory.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      await temporaryDirectory.create(recursive: true);
      try {
        final archivePath = archive.path;
        final temporaryPath = temporaryDirectory.path;
        await Isolate.run(() => extractFileToDisk(archivePath, temporaryPath));
        await _validateRequiredFiles(temporaryDirectory);
        await File(
          _join(temporaryDirectory.path, '.runtime.json'),
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': manifestSchemaVersion,
            'version': manifest.version,
            'archiveSha256': manifest.sha256,
          }),
          flush: true,
        );
        if (await cacheDirectory.exists()) {
          await cacheDirectory.delete(recursive: true);
        }
        await temporaryDirectory.rename(cacheDirectory.path);
      } catch (_) {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
        rethrow;
      }
      final executable = await _validatedExecutable(
        cacheDirectory,
        manifest.sha256,
      );
      if (executable == null) {
        throw const FormatException('内置 OpenOCD 解压完成后校验失败');
      }
      _readyExecutable = executable;
      await _cleanupOldCaches(cacheRoot, keep: cacheDirectory);
      AppLogger().info(
        '内置 OpenOCD 已准备完成：版本=${manifest.version}，目录=${cacheDirectory.path}',
        category: 'RTT',
      );
      return executable;
    } catch (error, stackTrace) {
      AppLogger().error(
        '准备内置 OpenOCD 失败: $error',
        category: 'RTT',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      if (lock != null) {
        try {
          await lock.unlock();
        } catch (_) {
          // 文件句柄关闭时系统会释放锁；这里只避免清理异常覆盖真正失败原因。
        }
        await lock.close();
      }
      _setState(const BundledOpenOcdPreparationState.idle());
    }
  }

  Future<Directory?> _findBundleDirectory() async {
    final override = _bundleDirectoryOverride;
    if (override != null) {
      return await File(_join(override.path, manifestFileName)).exists()
          ? override
          : null;
    }
    final separator = Platform.pathSeparator;
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      Directory('$executableDirectory${separator}runtime${separator}openocd'),
      Directory(
        'build${separator}windows${separator}x64${separator}runner'
        '${separator}Release${separator}runtime${separator}openocd',
      ),
    ];
    for (final candidate in candidates) {
      if (await File(_join(candidate.path, manifestFileName)).exists()) {
        return candidate.absolute;
      }
    }
    return null;
  }

  Directory _currentExecutableCacheRoot() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    return Directory(
      _join(
        _join(_join(executableDirectory, 'runtime'), 'openocd'),
        'extracted',
      ),
    );
  }

  Future<_OpenOcdRuntimeManifest> _readManifest(Directory directory) async {
    final file = File(_join(directory.path, manifestFileName));
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('内置 OpenOCD 清单格式无效');
    }
    final schemaVersion = decoded['schemaVersion'];
    final version = '${decoded['version'] ?? ''}'.trim();
    final archiveName = '${decoded['archive'] ?? ''}'.trim();
    final sha256Value = '${decoded['sha256'] ?? ''}'.trim().toLowerCase();
    final size = decoded['size'];
    if (schemaVersion != manifestSchemaVersion ||
        version.isEmpty ||
        archiveName.isEmpty ||
        archiveName != File(archiveName).uri.pathSegments.last ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256Value) ||
        size is! int ||
        size <= 0) {
      throw const FormatException('内置 OpenOCD 清单字段无效');
    }
    return _OpenOcdRuntimeManifest(
      version: version,
      archiveName: archiveName,
      sha256: sha256Value,
      size: size,
    );
  }

  Future<void> _validateArchive(
    File archive,
    _OpenOcdRuntimeManifest manifest,
  ) async {
    if (!await archive.exists()) {
      throw const FileSystemException('内置 OpenOCD 压缩包不存在');
    }
    if (await archive.length() != manifest.size) {
      throw const FormatException('内置 OpenOCD 压缩包大小与清单不一致');
    }
    final digest = await sha256.bind(archive.openRead()).first;
    if (digest.toString() != manifest.sha256) {
      throw const FormatException('内置 OpenOCD 压缩包 SHA-256 校验失败');
    }
  }

  Future<String?> _validatedExecutable(
    Directory directory,
    String expectedSha256,
  ) async {
    if (!await directory.exists()) return null;
    try {
      final marker = File(_join(directory.path, '.runtime.json'));
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['archiveSha256'] != expectedSha256) {
        return null;
      }
      await _validateRequiredFiles(directory);
      return File(_join(directory.path, 'bin/openocd.exe')).absolute.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _validateRequiredFiles(Directory directory) async {
    for (final relativePath in _requiredPaths) {
      final path = _join(directory.path, relativePath);
      final type = await FileSystemEntity.type(path, followLinks: false);
      final expectsDirectory =
          relativePath.endsWith('/interface') ||
          relativePath.endsWith('/target');
      if ((expectsDirectory && type != FileSystemEntityType.directory) ||
          (!expectsDirectory && type != FileSystemEntityType.file)) {
        throw FormatException('内置 OpenOCD 运行时缺少：$relativePath');
      }
    }
  }

  bool _isRuntimeCompleteSync(Directory directory) {
    for (final relativePath in _requiredPaths) {
      final type = FileSystemEntity.typeSync(
        _join(directory.path, relativePath),
        followLinks: false,
      );
      final expectsDirectory =
          relativePath.endsWith('/interface') ||
          relativePath.endsWith('/target');
      if ((expectsDirectory && type != FileSystemEntityType.directory) ||
          (!expectsDirectory && type != FileSystemEntityType.file)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _cleanupOldCaches(
    Directory cacheRoot, {
    required Directory keep,
  }) async {
    try {
      await for (final entity in cacheRoot.list(followLinks: false)) {
        if (entity is! Directory ||
            entity.absolute.path == keep.absolute.path) {
          continue;
        }
        await entity.delete(recursive: true);
      }
    } catch (error) {
      // 旧缓存只影响占用空间，不能因此让已经准备好的当前版本不可用。
      AppLogger().warning('清理旧 OpenOCD 缓存失败: $error', category: 'RTT');
    }
  }

  void _setState(BundledOpenOcdPreparationState value) {
    _state = value;
    notifyListeners();
  }

  static String _join(String left, String right) {
    final separator = Platform.pathSeparator;
    final normalizedRight = right.replaceAll('/', separator);
    return left.endsWith(separator)
        ? '$left$normalizedRight'
        : '$left$separator$normalizedRight';
  }

  static String _safeSegment(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

class _OpenOcdRuntimeManifest {
  const _OpenOcdRuntimeManifest({
    required this.version,
    required this.archiveName,
    required this.sha256,
    required this.size,
  });

  final String version;
  final String archiveName;
  final String sha256;
  final int size;
}
