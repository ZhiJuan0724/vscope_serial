import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/atomic_file.dart';

class _MemoryFileOperations implements AtomicFileOperations {
  final Map<String, Uint8List> files = {};
  bool failPartCommit = false;

  @override
  Future<void> createParent(String path) async {}

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList(files[path]!);

  @override
  Future<void> rename(String sourcePath, String targetPath) async {
    if (failPartCommit && sourcePath.endsWith('.part')) {
      throw FileSystemException('injected rename failure', sourcePath);
    }
    files[targetPath] = files.remove(sourcePath)!;
  }

  @override
  Future<void> writeAndFlush(String path, Uint8List bytes) async {
    files[path] = Uint8List.fromList(bytes);
  }
}

void main() {
  group('AtomicFileCommitter', () {
    test('提交成功后保留一代备份并清理临时文件', () async {
      final operations =
          _MemoryFileOperations()
            ..files['settings.json'] = Uint8List.fromList([1]);
      final committer = AtomicFileCommitter(operations: operations);

      await committer.writeBytes(
        'settings.json',
        Uint8List.fromList([2]),
        keepBackup: true,
      );

      expect(operations.files['settings.json'], [2]);
      expect(operations.files['settings.json.bak'], [1]);
      expect(operations.files, isNot(contains('settings.json.part')));
    });

    test('替换失败时恢复原目标且不遗留临时文件', () async {
      final operations =
          _MemoryFileOperations()
            ..files['settings.json'] = Uint8List.fromList([1])
            ..failPartCommit = true;
      final committer = AtomicFileCommitter(operations: operations);

      await expectLater(
        committer.writeBytes('settings.json', Uint8List.fromList([2])),
        throwsA(isA<FileSystemException>()),
      );

      expect(operations.files['settings.json'], [1]);
      expect(operations.files, isNot(contains('settings.json.part')));
    });

    test('目标缺失时可从备份恢复', () async {
      final operations =
          _MemoryFileOperations()
            ..files['settings.json.bak'] = Uint8List.fromList([1]);
      final committer = AtomicFileCommitter(operations: operations);

      expect(await committer.recoverMissingTarget('settings.json'), isTrue);
      expect(operations.files['settings.json'], [1]);
    });
  });
}
