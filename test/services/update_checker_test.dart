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
              },
        );

        final result = await checker.check();

        expect(result.error, isNull);
        expect(result.hasUpdate, isFalse);
        expect(result.latestRelease?.tagName, 'v$currentVersion');
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
