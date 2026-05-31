import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/changelog_service.dart';

void main() {
  group('ChangelogService', () {
    test('parses version sections', () {
      const content = '''
# Changelog

## v1.0.4 - 2026-05-31

### Added
- A

## v1.0.3 - 2026-05-30

### Fixed
- B
''';

      final entries = ChangelogService.parse(content);

      expect(entries, hasLength(2));
      expect(entries[0].version, 'v1.0.4');
      expect(entries[0].date, '2026-05-31');
      expect(entries[0].body, contains('- A'));
      expect(entries[1].version, 'v1.0.3');
    });

    test('normalizes v prefix', () {
      expect(ChangelogService.normalizeVersion('v1.0.4'), '1.0.4');
      expect(ChangelogService.normalizeVersion('1.0.4'), '1.0.4');
    });
  });
}
