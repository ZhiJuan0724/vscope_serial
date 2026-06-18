import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/update_checker.dart';
import 'package:vscope_serial/services/update_service.dart';

// Manual usage examples:
//
// Run from the project root when using the relative test path below. If the
// current shell is in another directory, pass this test file as an absolute path.
// Download cache is written to <current-directory>/updates.
//
// Test latest beta from Gitee:
// flutter test test\manual\latest_update_download_test.dart --dart-define=RUN_LATEST_UPDATE_DOWNLOAD=true --dart-define=UPDATE_CHANNEL=beta --dart-define=UPDATE_SOURCE=gitee
//
// Test latest stable from GitHub:
// flutter test test\manual\latest_update_download_test.dart --dart-define=RUN_LATEST_UPDATE_DOWNLOAD=true --dart-define=UPDATE_CHANNEL=stable --dart-define=UPDATE_SOURCE=github
//
// Omit UPDATE_SOURCE to use the normal app behavior: GitHub first, then Gitee.
const _enabled = bool.fromEnvironment('RUN_LATEST_UPDATE_DOWNLOAD');
const _channelValue = String.fromEnvironment(
  'UPDATE_CHANNEL',
  defaultValue: 'beta',
);
const _sourceValue = String.fromEnvironment('UPDATE_SOURCE');

void main() {
  test(
    'downloads latest update package regardless of current version',
    () async {
      final channel = _parseChannel(_channelValue);
      final source = _parseSource(_sourceValue);
      final checker = UpdateChecker();
      final service = UpdateService(
        updatesRoot: Directory('${Directory.current.path}/updates'),
      );

      // This intentionally ignores hasUpdate so a current build can validate
      // the latest release download path without installing an older version.
      final result = await checker.check(channel: channel, source: source);
      final release = result.latestRelease;
      expect(result.error, isNull);
      expect(release, isNotNull);
      // ignore: avoid_print
      print('selected release: ${release!.source} ${release.tagName}');

      final prepared = await service.downloadAndPrepare(
        release,
        channel: channel,
        onProgress: (progress) {
          final total = progress.total <= 0 ? 1 : progress.total;
          final percent = (progress.received / total * 100).clamp(0, 100);
          // ignore: avoid_print
          print(
            'download ${percent.toStringAsFixed(1)}% '
            '(${_formatBytes(progress.received)} / '
            '${_formatBytes(progress.total)})',
          );
        },
      );

      expect(prepared.release.tagName, release.tagName);
      if (source != null) {
        expect(prepared.release.source, source.label);
      }
      expect(prepared.manifest.version, release.tagName.substring(1));
      expect(prepared.payloadDirectory.existsSync(), isTrue);
      // ignore: avoid_print
      print('prepared update at: ${prepared.updateDirectory.path}');
    },
    skip:
        _enabled
            ? false
            : 'Manual network test. Enable with '
                '--dart-define=RUN_LATEST_UPDATE_DOWNLOAD=true',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

UpdateChannel _parseChannel(String value) {
  return switch (value.trim().toLowerCase()) {
    'stable' => UpdateChannel.stable,
    'beta' => UpdateChannel.beta,
    _ => throw ArgumentError('Unknown UPDATE_CHANNEL: $value'),
  };
}

UpdateReleaseSource? _parseSource(String value) {
  if (value.trim().isEmpty) return null;
  return UpdateReleaseSource.fromString(value);
}

String _formatBytes(num bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${bytes.toStringAsFixed(0)} B';
}
