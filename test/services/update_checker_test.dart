import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/app_info.dart';
import 'package:vscope_serial/services/update_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateChecker', () {
    test('reports no update when latest beta equals current version', () async {
      final currentVersion = await AppInfo.version();
      final checker = UpdateChecker(
        fetchJson:
            (_) async => [
              {
                'tag_name': 'v$currentVersion',
                'html_url': 'https://example.com/releases/v$currentVersion',
                'body': '- 当前版本说明',
                'prerelease': true,
              },
            ],
      );

      final result = await checker.check(channel: UpdateChannel.beta);

      expect(result.error, isNull);
      expect(result.hasUpdate, isFalse);
      expect(result.latestRelease?.tagName, 'v$currentVersion');
      expect(result.latestRelease?.body, contains('当前版本说明'));
    });

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

    test('stable channel rejects beta prerelease', () {
      expect(
        () => UpdateChecker.parseReleaseJson({
          'tag_name': 'v1.2.3-beta.1',
          'prerelease': true,
        }, source: 'GitHub'),
        throwsFormatException,
      );
    });

    test(
      'beta channel picks newest beta prerelease from release list',
      () async {
        final checker = UpdateChecker(
          fetchJson: (uri) async {
            expect(uri.toString(), contains('/releases?'));
            return [
              {'tag_name': 'v1.2.3', 'prerelease': false},
              {'tag_name': 'v1.2.4-beta.1', 'prerelease': true},
              {'tag_name': 'v1.2.4-beta.2', 'prerelease': true},
            ];
          },
        );

        final result = await checker.check(channel: UpdateChannel.beta);

        expect(result.error, isNull);
        expect(result.hasUpdate, isTrue);
        expect(result.latestRelease?.tagName, 'v1.2.4-beta.2');
        expect(result.latestRelease?.channel, UpdateChannel.beta);
      },
    );

    test('compares stable and beta versions with prerelease order', () {
      expect(
        UpdateChecker.compareVersions('v1.0.7-beta.2', 'v1.0.7-beta.1'),
        greaterThan(0),
      );
      expect(
        UpdateChecker.compareVersions('v1.0.7', 'v1.0.7-beta.2'),
        greaterThan(0),
      );
      expect(
        UpdateChecker.compareVersions('v1.0.8-beta.1', 'v1.0.7'),
        greaterThan(0),
      );
    });

    test('falls back to Gitee when GitHub request fails', () async {
      var callCount = 0;
      final checker = UpdateChecker(
        fetchJson: (uri) async {
          callCount++;
          if (callCount == 1) {
            throw Exception('github unavailable');
          }
          return {
            'tag_name': 'v9.9.9',
            'html_url': 'https://gitee.com/releases/v9.9.9',
          };
        },
      );

      final result = await checker.check();

      expect(result.error, isNull);
      expect(result.hasUpdate, isTrue);
      expect(result.latestRelease?.source, 'Gitee');
      expect(callCount, 2);
    });

    test('falls back to Gitee for beta channel', () async {
      var callCount = 0;
      final checker = UpdateChecker(
        fetchJson: (uri) async {
          callCount++;
          if (callCount == 1) {
            return [
              {'tag_name': 'v1.2.3', 'prerelease': false},
            ];
          }
          return [
            {'tag_name': 'v9.9.9-beta.1', 'html_url': 'https://gitee.com/beta'},
          ];
        },
      );

      final result = await checker.check(channel: UpdateChannel.beta);

      expect(result.error, isNull);
      expect(result.hasUpdate, isTrue);
      expect(result.latestRelease?.source, 'Gitee');
      expect(result.latestRelease?.tagName, 'v9.9.9-beta.1');
      expect(callCount, 2);
    });

    test('checks only selected source when source is specified', () async {
      final requestedUris = <Uri>[];
      final checker = UpdateChecker(
        fetchJson: (uri) async {
          requestedUris.add(uri);
          return [
            {'tag_name': 'v9.9.9-beta.1', 'html_url': 'https://gitee.com/beta'},
          ];
        },
      );

      final result = await checker.check(
        channel: UpdateChannel.beta,
        source: UpdateReleaseSource.gitee,
      );

      expect(result.error, isNull);
      expect(result.latestRelease?.source, 'Gitee');
      expect(requestedUris, hasLength(1));
      expect(requestedUris.single.host, 'gitee.com');
    });
  });
}
