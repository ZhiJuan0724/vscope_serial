import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/crash_dump_service.dart';

void main() {
  group('CrashDumpService', () {
    late Directory temporaryDirectory;
    late CrashDumpService service;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'vscope_crash_dump_test_',
      );
      service = CrashDumpService(executableDirectory: temporaryDirectory);
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('默认开启并通过禁用标记同步给下一次 Runner 启动', () async {
      expect(await service.disabledMarker.exists(), isFalse);

      await service.setEnabled(false);
      expect(await service.disabledMarker.exists(), isTrue);

      await service.setEnabled(true);
      expect(await service.disabledMarker.exists(), isFalse);
    });

    test('只返回尚未提示的记录并按时间倒序排列', () async {
      await service.crashDumpDirectory.create(recursive: true);
      final olderDump = File(
        '${service.crashDumpDirectory.path}${Platform.pathSeparator}older.dmp',
      );
      await olderDump.writeAsBytes([1, 2, 3]);
      final olderMetadata = File(
        '${service.crashDumpDirectory.path}${Platform.pathSeparator}older.json',
      );
      await olderMetadata.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'timestampUtc': '2026-07-28T10:00:00.000Z',
          'exceptionCode': '0xC0000005',
          'dumpFile': 'older.dmp',
          'dumpWritten': true,
        }),
      );
      final newerMetadata = File(
        '${service.crashDumpDirectory.path}${Platform.pathSeparator}newer.json',
      );
      await newerMetadata.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'timestampUtc': '2026-07-29T10:00:00.000Z',
          'exceptionCode': '0x80000003',
          'dumpFile': 'missing.dmp',
          'dumpWritten': false,
        }),
      );

      final records = await service.pendingRecords();

      expect(records, hasLength(2));
      expect(records.first.metadataFile.path, newerMetadata.path);
      expect(records.first.dumpFile, isNull);
      expect(records.last.metadataFile.path, olderMetadata.path);
      expect(records.last.dumpFile?.path, olderDump.path);

      await service.markReported([records.first]);
      final remaining = await service.pendingRecords();
      expect(remaining, hasLength(1));
      expect(remaining.single.metadataFile.path, olderMetadata.path);
    });

    test('元数据损坏时仍保留未知崩溃提示', () async {
      await service.crashDumpDirectory.create(recursive: true);
      final metadata = File(
        '${service.crashDumpDirectory.path}${Platform.pathSeparator}broken.json',
      );
      await metadata.writeAsString('{');

      final records = await service.pendingRecords();

      expect(records, hasLength(1));
      expect(records.single.metadataFile.path, metadata.path);
      expect(records.single.timestampUtc, isNull);
      expect(records.single.exceptionCode, isNull);
    });

    test('启动读取时只保留最近十份记录', () async {
      await service.crashDumpDirectory.create(recursive: true);
      for (var index = 0; index < 12; index++) {
        final metadata = File(
          '${service.crashDumpDirectory.path}'
          '${Platform.pathSeparator}record_$index.json',
        );
        await metadata.writeAsString(
          jsonEncode({
            'timestampUtc':
                '2026-07-29T10:00:${index.toString().padLeft(2, '0')}.000Z',
          }),
        );
        await metadata.setLastModified(DateTime.utc(2026, 7, 29, 10, 0, index));
      }

      final records = await service.pendingRecords();
      final remainingMetadata =
          await service.crashDumpDirectory
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    entity.path.toLowerCase().endsWith('.json'),
              )
              .length;

      expect(records, hasLength(CrashDumpService.maxRetainedRecords));
      expect(remainingMetadata, CrashDumpService.maxRetainedRecords);
      expect(records.first.timestampUtc, DateTime.utc(2026, 7, 29, 10, 0, 11));
    });
  });
}
