import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 原子文件提交所需的最小文件系统接口。
///
/// 测试可注入故障实现，生产环境使用 [LocalAtomicFileOperations]。
abstract interface class AtomicFileOperations {
  Future<bool> exists(String path);
  Future<void> createParent(String path);
  Future<void> writeAndFlush(String path, Uint8List bytes);
  Future<Uint8List> read(String path);
  Future<void> rename(String sourcePath, String targetPath);
  Future<void> delete(String path);
}

class LocalAtomicFileOperations implements AtomicFileOperations {
  const LocalAtomicFileOperations();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> createParent(String path) =>
      File(path).parent.create(recursive: true);

  @override
  Future<void> writeAndFlush(String path, Uint8List bytes) async {
    final file = File(path);
    final output = await file.open(mode: FileMode.write);
    try {
      await output.writeFrom(bytes);
      await output.flush();
    } finally {
      await output.close();
    }
  }

  @override
  Future<Uint8List> read(String path) => File(path).readAsBytes();

  @override
  Future<void> rename(String sourcePath, String targetPath) =>
      File(sourcePath).rename(targetPath).then<void>((_) {});

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// 通过同目录临时文件提交内容，避免写入中断破坏已有目标。
class AtomicFileCommitter {
  final AtomicFileOperations operations;

  const AtomicFileCommitter({
    this.operations = const LocalAtomicFileOperations(),
  });

  String partPath(String targetPath) => '$targetPath.part';
  String backupPath(String targetPath) => '$targetPath.bak';

  Future<void> writeString(
    String targetPath,
    String content, {
    Encoding encoding = utf8,
    bool keepBackup = false,
  }) => writeBytes(
    targetPath,
    Uint8List.fromList(encoding.encode(content)),
    keepBackup: keepBackup,
  );

  Future<void> writeBytes(
    String targetPath,
    Uint8List bytes, {
    bool keepBackup = false,
  }) async {
    final part = partPath(targetPath);
    await operations.createParent(targetPath);
    await operations.delete(part);
    await operations.writeAndFlush(part, bytes);

    await commitPart(targetPath, keepBackup: keepBackup);
  }

  /// 提交调用方已经 flush 并关闭的同目录 `.part` 文件。
  Future<void> commitPart(String targetPath, {bool keepBackup = false}) async {
    final part = partPath(targetPath);
    final backup = backupPath(targetPath);

    var movedOriginal = false;
    try {
      if (await operations.exists(targetPath)) {
        await operations.delete(backup);
        await operations.rename(targetPath, backup);
        movedOriginal = true;
      }
      await operations.rename(part, targetPath);
      if (!keepBackup) await operations.delete(backup);
    } catch (_) {
      if (movedOriginal &&
          !await operations.exists(targetPath) &&
          await operations.exists(backup)) {
        await operations.rename(backup, targetPath);
      }
      await operations.delete(part);
      rethrow;
    }
  }

  /// 目标缺失但备份存在时恢复备份，处理进程在两次 rename 之间退出的情况。
  Future<bool> recoverMissingTarget(String targetPath) async {
    if (await operations.exists(targetPath)) return false;
    final backup = backupPath(targetPath);
    if (!await operations.exists(backup)) return false;
    await operations.rename(backup, targetPath);
    return true;
  }

  /// 主文件损坏时用已验证的备份替换，并继续保留一份有效备份。
  Future<bool> restoreBackup(String targetPath) async {
    final backup = backupPath(targetPath);
    if (!await operations.exists(backup)) return false;
    final validBytes = await operations.read(backup);
    final invalid = '${partPath(targetPath)}.invalid';
    await operations.delete(invalid);
    if (await operations.exists(targetPath)) {
      await operations.rename(targetPath, invalid);
    }
    try {
      await operations.rename(backup, targetPath);
      await operations.writeAndFlush(backup, validBytes);
      await operations.delete(invalid);
      return true;
    } catch (_) {
      if (!await operations.exists(targetPath) &&
          await operations.exists(invalid)) {
        await operations.rename(invalid, targetPath);
      }
      rethrow;
    }
  }
}
