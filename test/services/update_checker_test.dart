import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/app_info.dart';
import 'package:vscope_serial/services/update_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateChecker', () {
    test(
      'reports no update when latest release equals current version',
      () async {
        final currentVersion = await AppInfo.version();
        final checker = UpdateChecker(
          fetchJson:
              (_) async => {
                'tag_name': 'v$currentVersion',
                'html_url': 'https://example.com/releases/v$currentVersion',
                'body': '- 当前版本说明',
              },
        );

        final result = await checker.check();

        expect(result.error, isNull);
        expect(result.hasUpdate, isFalse);
        expect(result.latestRelease?.tagName, 'v$currentVersion');
        expect(result.latestRelease?.body, contains('当前版本说明'));
      },
    );

    test('reports update when latest release is newer', () async {
      final checker = UpdateChecker(
        fetchJson:
            (_) async => {
              'tag_name': 'v9.9.9',
              'html_url': 'https://example.com/releases/v9.9.9',
            },
      );

      final result = await checker.check();

      expect(result.error, isNull);
      expect(result.hasUpdate, isTrue);
      expect(result.latestRelease?.source, 'GitHub');
    });

    test('parses release assets used by automatic updates', () {
      final release = UpdateChecker.parseReleaseJson({
        'tag_name': 'v1.2.3',
        'assets': [
          {
            'name': 'vscope_serial-windows-v1.2.3.zip',
            'size': 123,
            'browser_download_url': 'https://example.com/package.zip',
            'digest': 'sha256:abc',
          },
        ],
      }, source: 'GitHub');

      expect(release.assets, hasLength(1));
      expect(release.assets.single.size, 123);
      expect(release.assets.single.digest, 'sha256:abc');
    });

    test('falls back to Gitee when GitHub request fails', () async {
      final currentVersion = await AppInfo.version();
      var callCount = 0;
      final checker = UpdateChecker(
        fetchJson: (uri) async {
          callCount++;
          if (callCount == 1) {
            throw Exception('github unavailable');
          }
          return {
            'tag_name': 'v$currentVersion',
            'html_url': 'https://gitee.com/releases/v$currentVersion',
          };
        },
      );

      final result = await checker.check();

      expect(result.error, isNull);
      expect(result.hasUpdate, isFalse);
      expect(result.latestRelease?.source, 'Gitee');
      expect(callCount, 2);
    });
  });
}
