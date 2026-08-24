import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/utils/atomic_file.dart';

typedef SettingsSnapshotValidator =
    void Function(Map<String, dynamic> snapshot);

const JsonEncoder _settingsJsonEncoder = JsonEncoder.withIndent('  ');

/// 设置读取及备份恢复结果。
///
/// 读取失败不会半量应用字段：调用方只能使用已完整校验的 [snapshot]，或保留内存
/// 默认值并根据错误提示用户。
class SettingsLoadResult {
  const SettingsLoadResult({
    this.snapshot,
    this.recoveredFromBackup = false,
    this.primaryError,
    this.primaryStackTrace,
    this.error,
    this.stackTrace,
  });

  final Map<String, dynamic>? snapshot;
  final bool recoveredFromBackup;
  final Object? primaryError;
  final StackTrace? primaryStackTrace;
  final Object? error;
  final StackTrace? stackTrace;

  bool get failed => error != null;
}

/// 设置文件的 JSON、备份恢复和串行原子写入边界。
///
/// 本类不认识任何具体设置字段；字段归一化仍由运行时设置门面负责。
class SettingsRepository {
  SettingsRepository({
    required SettingsSnapshotValidator validator,
    AtomicFileCommitter fileCommitter = const AtomicFileCommitter(),
    Duration saveDebounce = const Duration(milliseconds: 200),
  }) : _validator = validator,
       _fileCommitter = fileCommitter,
       _saveDebounce = saveDebounce;

  final SettingsSnapshotValidator _validator;
  final AtomicFileCommitter _fileCommitter;
  final Duration _saveDebounce;

  String? _path;
  Timer? _saveDebounceTimer;
  Completer<void>? _pendingSave;
  String? _pendingContent;
  Future<void> _saveChain = Future<void>.value();

  String? get path => _path;

  Future<void> setPath(String? path) async {
    // 切换路径前先排空旧写链，避免旧目录的延迟写入落到新会话之后。
    await flush();
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _pendingSave = null;
    _pendingContent = null;
    _path = path;
  }

  Future<SettingsLoadResult> load() async {
    final path = _path;
    if (path == null) return const SettingsLoadResult();
    await _fileCommitter.recoverMissingTarget(path);
    if (!await File(path).exists()) return const SettingsLoadResult();

    try {
      return SettingsLoadResult(snapshot: await _readValidated(path));
    } catch (primaryError, primaryStackTrace) {
      // 主文件损坏时只接受同样通过字段校验的一代备份。
      final backupPath = _fileCommitter.backupPath(path);
      try {
        final snapshot = await _readValidated(backupPath);
        await _fileCommitter.restoreBackup(path);
        return SettingsLoadResult(
          snapshot: snapshot,
          recoveredFromBackup: true,
          primaryError: primaryError,
          primaryStackTrace: primaryStackTrace,
        );
      } catch (error, stackTrace) {
        return SettingsLoadResult(
          primaryError: primaryError,
          primaryStackTrace: primaryStackTrace,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<Map<String, dynamic>> _readValidated(String path) async {
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map) throw const FormatException('设置根节点必须为对象');
    final snapshot = Map<String, dynamic>.from(decoded);
    _validator(snapshot);
    return snapshot;
  }

  Future<void> save(Map<String, dynamic> snapshot) {
    // 防抖将连续 UI 修改合并为一次原子提交；调用者仍可用 flush 等待落盘。
    if (_path == null) return Future<void>.value();
    _pendingContent = _settingsJsonEncoder.convert(snapshot);
    _saveDebounceTimer?.cancel();
    final pending = _pendingSave ??= Completer<void>();
    _saveDebounceTimer = Timer(_saveDebounce, _enqueueSave);
    return pending.future;
  }

  void _enqueueSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    final path = _path;
    final content = _pendingContent;
    final pending = _pendingSave;
    _pendingContent = null;
    _pendingSave = null;
    if (path == null || content == null || pending == null) return;
    // 所有提交串行执行，避免两个 .part/备份替换流程交叉。
    final write = _saveChain.then(
      (_) => _fileCommitter.writeString(path, content, keepBackup: true),
    );
    _saveChain = write.catchError((Object _) {});
    write.then<void>(
      (_) => pending.complete(),
      onError: (Object error, StackTrace stackTrace) {
        pending.completeError(error, stackTrace);
      },
    );
  }

  Future<void> flush() async {
    if (_pendingSave != null) _enqueueSave();
    await _saveChain;
    if (_pendingSave != null) {
      _enqueueSave();
      await _saveChain;
    }
  }
}
