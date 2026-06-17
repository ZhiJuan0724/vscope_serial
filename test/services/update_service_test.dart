import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/update_checker.dart';
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
      releaseFetcher: (_, source) async {
        expect(source, 'Gitee');
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
    final gitee = ReleaseInfo(
      tagName: tag,
      htmlUrl: '',
      source: 'Gitee',
      body: '',
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
      releaseFetcher: (_, source) async {
        expect(source, 'Gitee');
        return gitee;
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
      releaseFetcher: (_, source) async {
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
