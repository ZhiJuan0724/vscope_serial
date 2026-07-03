import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/update_checker.dart';
import 'package:vscope_serial/services/update_service.dart';

// 手动使用示例：
//
// 使用下面的相对测试路径时，请从项目根目录运行。
// 如果当前 shell 位于其它目录，请传入该测试文件的绝对路径。
// 下载缓存会写入 <current-directory>/updates。
//
// 测试 Gitee 最新 beta：
// flutter test test\manual\latest_update_download_test.dart --dart-define=RUN_LATEST_UPDATE_DOWNLOAD=true --dart-define=UPDATE_CHANNEL=beta --dart-define=UPDATE_SOURCE=gitee
//
// 测试 GitHub 最新稳定版：
// flutter test test\manual\latest_update_download_test.dart --dart-define=RUN_LATEST_UPDATE_DOWNLOAD=true --dart-define=UPDATE_CHANNEL=stable --dart-define=UPDATE_SOURCE=github
//
// 省略 UPDATE_SOURCE 时使用应用正常行为：先 GitHub，后 Gitee。
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

      // 这里故意忽略 hasUpdate，方便当前构建验证最新 Release 下载链路，
      // 而不需要安装旧版本。
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
