import 'dart:convert';
import 'dart:io';

/// 一次由 Windows Runner 生成、尚未向用户提示的原生崩溃记录。
class CrashDumpRecord {
  const CrashDumpRecord({
    required this.metadataFile,
    required this.dumpFile,
    required this.timestampUtc,
    required this.exceptionCode,
    required this.dumpWritten,
  });

  final File metadataFile;
  final File? dumpFile;
  final DateTime? timestampUtc;
  final String? exceptionCode;
  final bool dumpWritten;

  File get reportedMarker => File('${metadataFile.path}.reported');
}

/// 管理原生崩溃转储开关和“下次启动提示”状态。
///
/// Runner 在 Dart 启动前无法安全读取完整 settings.json，因此使用一个仅表示
/// “已禁用”的标记文件。标记不存在即为默认开启，兼容旧版本和首次启动。
class CrashDumpService {
  CrashDumpService({Directory? executableDirectory})
    : _executableDirectory =
          executableDirectory ?? File(Platform.resolvedExecutable).parent;

  static const String disabledMarkerName = 'crash_dump.disabled';
  static const int maxRetainedRecords = 10;

  final Directory _executableDirectory;

  Directory get crashDumpDirectory => Directory(
    '${_executableDirectory.path}${Platform.pathSeparator}crash_dumps',
  );

  Directory get settingsDirectory => Directory(
    '${_executableDirectory.path}${Platform.pathSeparator}settings',
  );

  File get disabledMarker => File(
    '${settingsDirectory.path}${Platform.pathSeparator}$disabledMarkerName',
  );

  /// 同步供下一次原生进程启动读取的开关。
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      if (await disabledMarker.exists()) {
        await disabledMarker.delete();
      }
      return;
    }
    await settingsDirectory.create(recursive: true);
    await disabledMarker.writeAsString(
      'disabled\n',
      mode: FileMode.write,
      flush: true,
    );
  }

  /// 返回尚未提示过的崩溃记录；损坏的元数据也会作为未知崩溃保留下来。
  Future<List<CrashDumpRecord>> pendingRecords() async {
    final directory = crashDumpDirectory;
    if (!await directory.exists()) return const [];

    final metadataFiles = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
        metadataFiles.add(entity);
      }
    }
    metadataFiles.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final metadataFile in metadataFiles.skip(maxRetainedRecords)) {
      await _deleteRecordFiles(metadataFile);
    }

    final records = <CrashDumpRecord>[];
    for (final metadataFile in metadataFiles.take(maxRetainedRecords)) {
      if (await File('${metadataFile.path}.reported').exists()) {
        continue;
      }
      records.add(await _readRecord(metadataFile));
    }
    records.sort((a, b) {
      final aTime =
          a.timestampUtc ?? a.metadataFile.statSync().modified.toUtc();
      final bTime =
          b.timestampUtc ?? b.metadataFile.statSync().modified.toUtc();
      return bTime.compareTo(aTime);
    });
    return records;
  }

  Future<void> _deleteRecordFiles(File metadataFile) async {
    final basePath = metadataFile.path.substring(
      0,
      metadataFile.path.length - '.json'.length,
    );
    for (final file in [
      File('$basePath.dmp'),
      metadataFile,
      File('${metadataFile.path}.reported'),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<CrashDumpRecord> _readRecord(File metadataFile) async {
    DateTime? timestampUtc;
    String? exceptionCode;
    File? dumpFile;
    var dumpWritten = false;
    try {
      final decoded =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      timestampUtc = DateTime.tryParse(
        decoded['timestampUtc'] as String? ?? '',
      );
      exceptionCode = decoded['exceptionCode'] as String?;
      dumpWritten = decoded['dumpWritten'] as bool? ?? false;
      final dumpName = decoded['dumpFile'] as String?;
      if (dumpName != null &&
          !dumpName.contains('/') &&
          !dumpName.contains('\\')) {
        final candidate = File(
          '${crashDumpDirectory.path}${Platform.pathSeparator}$dumpName',
        );
        if (await candidate.exists()) dumpFile = candidate;
      }
    } catch (_) {
      // 元数据可能正好在断电或二次崩溃时被截断，仍应提示用户检查目录。
    }
    return CrashDumpRecord(
      metadataFile: metadataFile,
      dumpFile: dumpFile,
      timestampUtc: timestampUtc,
      exceptionCode: exceptionCode,
      dumpWritten: dumpWritten,
    );
  }

  /// 将本批记录标记为已提示，避免每次启动重复弹窗。
  Future<void> markReported(Iterable<CrashDumpRecord> records) async {
    for (final record in records) {
      await record.reportedMarker.writeAsString(
        'reported\n',
        mode: FileMode.write,
        flush: true,
      );
    }
  }

  Future<void> openCrashDumpDirectory() async {
    await crashDumpDirectory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [crashDumpDirectory.path]);
    }
  }
}
