import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/update_checker.dart';
import 'package:vscope_serial/services/update_runtime_guard.dart';
import 'package:vscope_serial/services/update_service.dart';

void main() {
  group('UpdateManifest', () {
    test('validates release package metadata', () {
      final release = ReleaseInfo(
        tagName: 'v1.2.3',
        htmlUrl: '',
        source: 'GitHub',
        body: '',
      );
      final manifest = UpdateManifest(
        schemaVersion: 1,
        version: '1.2.3',
        packageName: 'vscope_serial-windows-v1.2.3.zip',
        packageSize: 100,
        sha256: List.filled(64, 'a').join(),
        executable: 'vscope_serial.exe',
      );

      expect(() => manifest.validateFor(release), returnsNormally);
    });

    test('rejects mismatched package name', () {
      final release = ReleaseInfo(
        tagName: 'v1.2.3',
        htmlUrl: '',
        source: 'GitHub',
        body: '',
      );
      final manifest = UpdateManifest(
        schemaVersion: 1,
        version: '1.2.3',
        packageName: 'source.zip',
        packageSize: 100,
        sha256: List.filled(64, 'a').join(),
        executable: 'vscope_serial.exe',
      );

      expect(() => manifest.validateFor(release), throwsFormatException);
    });
  });

  test('falls back to Gitee when GitHub assets are incomplete', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9';
    final package = _validPackage();
    final packageDigest = sha256.convert(package).toString();
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '9.9.9',
        'packageName': 'vscope_serial-windows-$tag.zip',
        'packageSize': package.length,
        'sha256': packageDigest,
        'executable': 'vscope_serial.exe',
      }),
    );
    final github = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
    );
    final gitee = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'Gitee',
      body: '',
      assets: [
        ReleaseAsset(
          name: 'update-manifest-$tag.json',
          size: manifest.length,
          downloadUrl: 'https://example.com/manifest',
        ),
        ReleaseAsset(
          name: 'vscope_serial-windows-$tag.zip',
          size: package.length,
          downloadUrl: 'https://example.com/package',
        ),
      ],
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, source, channel) async {
        expect(source, 'Gitee');
        expect(channel, UpdateChannel.stable);
        return gitee;
      },
      bytesFetcher: (_) async => manifest,
      fileDownloader: (_, destination, total, onProgress) async {
        await destination.writeAsBytes(package);
        onProgress(
          UpdateDownloadProgress(
            received: package.length,
            total: total,
            bytesPerSecond: package.length.toDouble(),
          ),
        );
      },
    );

    final prepared = await service.downloadAndPrepare(
      github,
      channel: UpdateChannel.stable,
      onProgress: (_) {},
    );

    expect(prepared.release.source, 'Gitee');
    expect(
      File('${prepared.payloadDirectory.path}/vscope_serial.exe').existsSync(),
      isTrue,
    );
  });

  test('beta download falls back to Gitee when GitHub fails', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9-beta.1';
    final package = _validPackage();
    final packageDigest = sha256.convert(package).toString();
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '9.9.9-beta.1',
        'packageName': 'vscope_serial-windows-$tag.zip',
        'packageSize': package.length,
        'sha256': packageDigest,
        'executable': 'vscope_serial.exe',
      }),
    );
    final github = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
      prerelease: true,
      assets: const [
        ReleaseAsset(
          name: 'update-manifest-$tag.json',
          size: 4,
          downloadUrl: 'https://example.com/manifest',
        ),
        ReleaseAsset(
          name: 'vscope_serial-windows-$tag.zip',
          size: 100,
          downloadUrl: 'https://example.com/package',
        ),
      ],
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, source, channel) async {
        expect(source, 'Gitee');
        expect(channel, UpdateChannel.beta);
        return UpdateChecker.parseReleaseJson(
          {
            'tag_name': tag,
            'assets': [
              {
                'name': 'update-manifest-$tag.json',
                'size': manifest.length,
                'browser_download_url': 'https://example.com/gitee-manifest',
              },
              {
                'name': 'vscope_serial-windows-$tag.zip',
                'size': package.length,
                'browser_download_url': 'https://example.com/gitee-package',
              },
            ],
          },
          source: source,
          channel: channel,
        );
      },
      bytesFetcher: (uri) async {
        if (uri.toString().contains('gitee-manifest')) return manifest;
        return utf8.encode('null');
      },
      fileDownloader: (_, destination, total, onProgress) async {
        await destination.writeAsBytes(package);
        onProgress(
          UpdateDownloadProgress(
            received: package.length,
            total: total,
            bytesPerSecond: package.length.toDouble(),
          ),
        );
      },
    );

    final prepared = await service.downloadAndPrepare(
      github,
      channel: UpdateChannel.beta,
      onProgress: (_) {},
    );

    expect(prepared.release.source, 'Gitee');
    expect(
      File('${prepared.payloadDirectory.path}/vscope_serial.exe').existsSync(),
      isTrue,
    );
  });

  test('locked source download does not fall back to another source', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9-beta.1';
    final github = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
      prerelease: true,
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, source, channel) async {
        throw StateError('unexpected $source fallback');
      },
    );

    expect(
      () => service.downloadAndPrepare(
        github,
        channel: UpdateChannel.beta,
        allowSourceFallback: false,
        onProgress: (_) {},
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.message,
          'message',
          contains('GitHub 尚未提供完整更新附件'),
        ),
      ),
    );
  });

  test('cancelled package download does not retry or fall back', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9-beta.1';
    final package = _validPackage();
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '9.9.9-beta.1',
        'packageName': 'vscope_serial-windows-$tag.zip',
        'packageSize': package.length,
        'sha256': sha256.convert(package).toString(),
        'executable': 'vscope_serial.exe',
      }),
    );
    final release = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
      prerelease: true,
      assets: [
        ReleaseAsset(
          name: 'update-manifest-$tag.json',
          size: manifest.length,
          downloadUrl: 'https://example.com/manifest',
        ),
        ReleaseAsset(
          name: 'vscope_serial-windows-$tag.zip',
          size: package.length,
          downloadUrl: 'https://example.com/package',
        ),
      ],
    );
    var downloadAttempts = 0;
    var fallbackAttempts = 0;
    late final UpdateService service;
    service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, _, _) async {
        fallbackAttempts++;
        throw StateError('取消后不应切换来源');
      },
      bytesFetcher: (_) async => manifest,
      fileDownloader: (_, destination, total, onProgress) async {
        downloadAttempts++;
        service.cancelDownload();
        throw const HttpException('连接已取消');
      },
    );

    await expectLater(
      service.downloadAndPrepare(
        release,
        channel: UpdateChannel.beta,
        onProgress: (_) {},
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.message,
          'message',
          '下载已取消',
        ),
      ),
    );

    expect(downloadAttempts, 1);
    expect(fallbackAttempts, 0);
    expect(File('${root.path}/$tag/package.zip.part').existsSync(), isFalse);
  });

  test('download starts from checked release source', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9-beta.1';
    final package = _validPackage();
    final packageDigest = sha256.convert(package).toString();
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '9.9.9-beta.1',
        'packageName': 'vscope_serial-windows-$tag.zip',
        'packageSize': package.length,
        'sha256': packageDigest,
        'executable': 'vscope_serial.exe',
      }),
    );
    final release = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'Gitee',
      body: '',
      prerelease: true,
      assets: [
        ReleaseAsset(
          name: 'update-manifest-$tag.json',
          size: manifest.length,
          downloadUrl: 'https://example.com/gitee-manifest',
        ),
        ReleaseAsset(
          name: 'vscope_serial-windows-$tag.zip',
          size: package.length,
          downloadUrl: 'https://example.com/gitee-package',
        ),
      ],
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, source, channel) async {
        throw StateError('unexpected $source fallback');
      },
      bytesFetcher: (_) async => manifest,
      fileDownloader: (_, destination, total, onProgress) async {
        await destination.writeAsBytes(package);
      },
    );

    final prepared = await service.downloadAndPrepare(
      release,
      channel: UpdateChannel.beta,
      onProgress: (_) {},
    );

    expect(prepared.release.source, 'Gitee');
  });

  test('rejects release without update assets', () async {
    final root = await Directory.systemTemp.createTemp('vscope-update-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v1.0.5';
    final release = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
      assets: const [
        ReleaseAsset(
          name: 'v1.0.5.zip',
          size: 100,
          downloadUrl: 'https://example.com/source.zip',
        ),
      ],
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher:
          (_, source, channel) async =>
              ReleaseInfo(tagName: tag, htmlUrl: '', source: source, body: ''),
    );

    expect(
      () => service.downloadAndPrepare(
        release,
        channel: UpdateChannel.stable,
        onProgress: (_) {},
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.message,
          'message',
          contains('尚未提供完整更新附件'),
        ),
      ),
    );
  });

  test('download is rejected when update lock is already held', () async {
    final service = UpdateService(
      runtimeGuard: _FakeUpdateRuntimeGuard(lockUnavailable: true),
    );
    final release = ReleaseInfo(
      tagName: 'v1.0.5',
      htmlUrl: '',
      source: 'GitHub',
      body: '',
    );

    expect(
      () => service.downloadAndPrepare(
        release,
        channel: UpdateChannel.stable,
        onProgress: (_) {},
      ),
      throwsA(
        isA<UpdateRuntimeGuardException>().having(
          (error) => error.message,
          'message',
          contains('已有更新任务正在进行'),
        ),
      ),
    );
  });

  test(
    'installer launch rejects other running instances before starting updater',
    () async {
      final root = await Directory.systemTemp.createTemp('vscope-launch-test-');
      addTearDown(() => root.delete(recursive: true));
      final service = UpdateService(
        updatesRoot: root,
        runtimeGuard: _FakeUpdateRuntimeGuard(otherProcessIds: [1234]),
      );
      final release = ReleaseInfo(
        tagName: 'v1.2.3',
        htmlUrl: '',
        source: 'GitHub',
        body: '',
      );
      final update = PreparedUpdate(
        release: release,
        manifest: const UpdateManifest(
          schemaVersion: 1,
          version: '1.2.3',
          packageName: '',
          packageSize: 0,
          sha256: '',
          executable: 'vscope_serial.exe',
        ),
        updateDirectory: Directory('${root.path}/update'),
        payloadDirectory: Directory('${root.path}/payload'),
      );

      expect(
        () => service.launchInstaller(update),
        throwsA(
          isA<UpdateDownloadException>().having(
            (error) => error.message,
            'message',
            contains('请先关闭其他 Vscope Serial 窗口'),
          ),
        ),
      );
    },
  );

  test('rejects zip path traversal', () async {
    final root = await Directory.systemTemp.createTemp('vscope-zip-test-');
    addTearDown(() => root.delete(recursive: true));
    final archive =
        Archive()
          ..addFile(ArchiveFile.bytes('../outside.txt', utf8.encode('unsafe')));
    final zip = File('${root.path}/unsafe.zip')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    expect(
      () => UpdateService.extractPackageSafely(
        zip,
        Directory('${root.path}/payload'),
      ),
      throwsFormatException,
    );
  });

  test('rejects exact parent path and Windows alternate stream path', () async {
    final root = await Directory.systemTemp.createTemp('vscope-zip-test-');
    addTearDown(() => root.delete(recursive: true));
    for (final unsafePath in ['..', 'payload.exe:stream']) {
      final archive =
          Archive()
            ..addFile(ArchiveFile.bytes(unsafePath, utf8.encode('unsafe')));
      final zip = File('${root.path}/unsafe.zip')
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      expect(
        () => UpdateService.extractPackageSafely(
          zip,
          Directory('${root.path}/payload'),
        ),
        throwsFormatException,
      );
    }
  });

  test('rejects package with mismatched SHA-256', () async {
    final root = await Directory.systemTemp.createTemp('vscope-hash-test-');
    addTearDown(() => root.delete(recursive: true));
    const tag = 'v9.9.9';
    final package = _validPackage();
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '9.9.9',
        'packageName': 'vscope_serial-windows-$tag.zip',
        'packageSize': package.length,
        'sha256': List.filled(64, '0').join(),
        'executable': 'vscope_serial.exe',
      }),
    );
    final release = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'GitHub',
      body: '',
      assets: [
        ReleaseAsset(
          name: 'update-manifest-$tag.json',
          size: manifest.length,
          downloadUrl: 'https://example.com/manifest',
        ),
        ReleaseAsset(
          name: 'vscope_serial-windows-$tag.zip',
          size: package.length,
          downloadUrl: 'https://example.com/package',
        ),
      ],
    );
    final service = UpdateService(
      updatesRoot: root,
      releaseFetcher: (_, source, channel) async {
        throw Exception('$source unavailable');
      },
      bytesFetcher: (_) async => manifest,
      fileDownloader: (_, destination, total, onProgress) async {
        await destination.writeAsBytes(package);
      },
    );

    expect(
      () => service.downloadAndPrepare(
        release,
        channel: UpdateChannel.stable,
        onProgress: (_) {},
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
  });

  test('finds valid rollback slot for each update channel', () async {
    final root = await Directory.systemTemp.createTemp('vscope-rollback-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = UpdateService(updatesRoot: root);
    final rollbackDir = Directory('${root.path}/rollback/beta');
    final payload = Directory('${rollbackDir.path}/payload');
    await payload.create(recursive: true);
    for (final entry
        in {
          'vscope_serial.exe': 'app',
          'vscope_updater.exe': 'updater',
          'app-files.json': '{"schemaVersion":1,"files":[]}',
        }.entries) {
      await File('${payload.path}/${entry.key}').writeAsString(entry.value);
    }
    await File('${rollbackDir.path}/update-manifest.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'version': '1.2.3-beta.1',
        'packageName': '',
        'packageSize': 0,
        'sha256': '',
        'executable': 'vscope_serial.exe',
      }),
    );
    await File('${rollbackDir.path}/rollback.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'channel': 'beta',
        'version': '1.2.3-beta.1',
        'createdAt': '2026-06-17T00:00:00Z',
      }),
    );

    final update = await service.findRollbackUpdate(UpdateChannel.beta);

    expect(update, isNotNull);
    expect(update!.channel, UpdateChannel.beta);
    expect(update.tagName, 'v1.2.3-beta.1');
  });
}

List<int> _validPackage() {
  final archive = Archive();
  for (final entry
      in {
        'vscope_serial.exe': 'app',
        'vscope_updater.exe': 'updater',
        'app-files.json': '{"schemaVersion":1,"files":[]}',
      }.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

final class _FakeUpdateRuntimeGuard implements UpdateRuntimeGuard {
  final bool lockUnavailable;
  final List<int> otherProcessIds;

  _FakeUpdateRuntimeGuard({
    this.lockUnavailable = false,
    this.otherProcessIds = const <int>[],
  });

  @override
  Future<T> runWithUpdateLock<T>(Future<T> Function() action) {
    if (lockUnavailable) {
      throw const UpdateRuntimeGuardException('已有更新任务正在进行，请稍后再试');
    }
    return action();
  }

  @override
  Future<List<int>> findOtherInstanceProcessIds() async => otherProcessIds;

  @override
  Future<void> requestCloseProcesses(List<int> processIds) async {}

  @override
  Future<bool> waitForOtherInstancesToExit(Duration timeout) async =>
      otherProcessIds.isEmpty;
}
