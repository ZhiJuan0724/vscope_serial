import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/changelog_service.dart';

void main() {
  group('ChangelogService', () {
    test('parses version sections', () {
      const content = '''
# Changelog

## v1.0.6-beta.1 - 2026-06-17

### Added
- Beta

## v1.0.4 - 2026-05-31

### Added
- A

## v1.0.3 - 2026-05-30

### Fixed
- B
''';

      final entries = ChangelogService.parse(content);

      expect(entries, hasLength(3));
      expect(entries[0].version, 'v1.0.6-beta.1');
      expect(entries[0].date, '2026-06-17');
      expect(entries[0].body, contains('- Beta'));
      expect(entries[1].version, 'v1.0.4');
      expect(entries[1].date, '2026-05-31');
      expect(entries[1].body, contains('- A'));
      expect(entries[2].version, 'v1.0.3');
    });

    test('normalizes v prefix', () {
      expect(ChangelogService.normalizeVersion('v1.0.4'), '1.0.4');
      expect(ChangelogService.normalizeVersion('1.0.4'), '1.0.4');
      expect(
        ChangelogService.normalizeVersion('v1.0.6-beta.1'),
        '1.0.6-beta.1',
      );
    });

    test('parses third-level headings and list items in entry body', () {
      final lines = ChangelogService.parseBody('''
### Added
- New feature

Plain text
''');

      expect(lines[0].type, ChangelogLineType.heading);
      expect(lines[0].text, 'Added');
      expect(lines[1].type, ChangelogLineType.listItem);
      expect(lines[1].text, 'New feature');
      expect(lines[2].type, ChangelogLineType.text);
      expect(lines[2].text, isEmpty);
      expect(lines[3].text, 'Plain text');
    });
  });
}
