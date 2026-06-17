import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/update_checker.dart';
import 'package:vscope_serial/services/update_service.dart';

const _enabled = bool.fromEnvironment('RUN_LATEST_UPDATE_DOWNLOAD');
const _channelValue = String.fromEnvironment(
  'UPDATE_CHANNEL',
  defaultValue: 'beta',
);

void main() {
  test(
    'downloads latest update package regardless of current version',
    () async {
      final channel = _parseChannel(_channelValue);
      final checker = UpdateChecker();
      final service = UpdateService();

      // This intentionally ignores hasUpdate so a current build can validate
      // the latest release download path without installing an older version.
      final result = await checker.check(channel: channel);
      final release = result.latestRelease;
      expect(result.error, isNull);
      expect(release, isNotNull);

      final prepared = await service.downloadAndPrepare(
        release!,
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

String _formatBytes(num bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${bytes.toStringAsFixed(0)} B';
}
