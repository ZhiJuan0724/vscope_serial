import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/bundled_openocd_runtime.dart';
import 'package:vscope_serial/services/rtt_process_backends.dart';

void main() {
  late Directory root;
  late Directory bundle;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vscope-openocd-runtime-');
    bundle = Directory('${root.path}${Platform.pathSeparator}bundle');
    cache = Directory('${bundle.path}${Platform.pathSeparator}extracted');
    await bundle.create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('首次使用校验归档并原子解压，后续直接复用缓存', () async {
    final archiveFile = await _writeRuntimeArchive(bundle);
    await _writeManifest(bundle, archiveFile);
    final oldCache = Directory('${cache.path}${Platform.pathSeparator}old');
    await oldCache.create(recursive: true);
    await File(
      '${oldCache.path}${Platform.pathSeparator}stale',
    ).writeAsString('stale');
    final runtime = BundledOpenOcdRuntime.forTesting(bundleDirectory: bundle);
    final states = <BundledOpenOcdPreparationState>[];
    runtime.addListener(() => states.add(runtime.state));

    final executable = await runtime.ensureReady();

    expect(executable, isNotNull);
    expect(File(executable!).existsSync(), isTrue);
    expect(executable, startsWith(cache.absolute.path));
    expect(states.any((state) => state.preparing), isTrue);
    expect(runtime.state.preparing, isFalse);
    expect(await oldCache.exists(), isFalse);
    final interfaceDirectory = await findOpenOcdConfigDirectoryForExecutable(
      executable,
      'interface',
    );
    final targetDirectory = await findOpenOcdConfigDirectoryForExecutable(
      executable,
      'target',
    );
    expect(Directory(interfaceDirectory!).existsSync(), isTrue);
    expect(Directory(targetDirectory!).existsSync(), isTrue);

    final cached = await runtime.ensureReady();
    expect(cached, executable);
    expect(cache.listSync().whereType<Directory>(), hasLength(1));
  });

  test('归档哈希不匹配时拒绝解压且恢复空闲状态', () async {
    final archiveFile = await _writeRuntimeArchive(bundle);
    await _writeManifest(
      bundle,
      archiveFile,
      shaOverride: List.filled(64, '0').join(),
    );
    final runtime = BundledOpenOcdRuntime.forTesting(bundleDirectory: bundle);

    await expectLater(runtime.ensureReady(), throwsA(isA<FormatException>()));

    expect(runtime.state.preparing, isFalse);
    expect(cache.listSync().whereType<Directory>(), isEmpty);
  });

  test('压缩包来源与当前程序缓存目录可以分离', () async {
    final archiveFile = await _writeRuntimeArchive(bundle);
    await _writeManifest(bundle, archiveFile);
    final executableCache = Directory(
      '${root.path}${Platform.pathSeparator}current-executable'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}openocd'
      '${Platform.pathSeparator}extracted',
    );
    final runtime = BundledOpenOcdRuntime.forTesting(
      bundleDirectory: bundle,
      cacheRoot: executableCache,
    );

    final executable = await runtime.ensureReady();

    expect(executable, isNotNull);
    expect(executable, startsWith(executableCache.absolute.path));
    expect(await cache.exists(), isFalse);
  });
}

Future<File> _writeRuntimeArchive(Directory bundle) async {
  final archive = Archive();
  void add(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('bin/openocd.exe', 'openocd');
  add('bin/libftdi1.dll', 'libftdi');
  add('bin/libusb-1.0.dll', 'libusb');
  add('openocd/scripts/interface/cmsis-dap.cfg', 'interface');
  add('openocd/scripts/target/stm32f4x.cfg', 'target');
  final file = File(
    '${bundle.path}${Platform.pathSeparator}openocd-runtime.zip',
  );
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  return file;
}

Future<void> _writeManifest(
  Directory bundle,
  File archive, {
  String? shaOverride,
}) async {
  final digest = await sha256.bind(archive.openRead()).first;
  await File(
    '${bundle.path}${Platform.pathSeparator}openocd-runtime.json',
  ).writeAsString(
    jsonEncode({
      'schemaVersion': 1,
      'version': '0.12.0-7',
      'archive': 'openocd-runtime.zip',
      'size': await archive.length(),
      'sha256': shaOverride ?? digest.toString(),
    }),
    flush: true,
  );
}
