import 'package:flutter/services.dart';

class ChangelogEntry {
  final String version;
  final String date;
  final String body;

  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.body,
  });

  String get title => date.isEmpty ? version : '$version - $date';
}

class ChangelogService {
  static List<ChangelogEntry>? _cachedEntries;

  Future<List<ChangelogEntry>> loadEntries() async {
    final cached = _cachedEntries;
    if (cached != null) return cached;

    final content = await rootBundle.loadString('CHANGELOG.md');
    final entries = parse(content);
    _cachedEntries = entries;
    return entries;
  }

  Future<List<ChangelogEntry>> currentAndPrevious(String currentVersion) async {
    final entries = await loadEntries();
    if (entries.isEmpty) return const [];

    final normalized = normalizeVersion(currentVersion);
    final index = entries.indexWhere(
      (entry) => normalizeVersion(entry.version) == normalized,
    );
    if (index < 0) return entries.take(2).toList(growable: false);
    return entries.skip(index).take(2).toList(growable: false);
  }

  static List<ChangelogEntry> parse(String content) {
    final headingPattern = RegExp(
      r'^##\s+(v?\d+(?:\.\d+){1,3})(?:\s+-\s+(.+))?\s*$',
      multiLine: true,
    );
    final matches = headingPattern.allMatches(content).toList(growable: false);
    final entries = <ChangelogEntry>[];

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final nextStart =
          i + 1 < matches.length ? matches[i + 1].start : content.length;
      final body = content.substring(match.end, nextStart).trim();
      entries.add(
        ChangelogEntry(
          version: _ensureVPrefix(match.group(1)!.trim()),
          date: (match.group(2) ?? '').trim(),
          body: body,
        ),
      );
    }

    return entries;
  }

  static String normalizeVersion(String value) {
    return value.trim().replaceFirst(RegExp(r'^[vV]'), '');
  }

  static String _ensureVPrefix(String value) {
    return value.startsWith(RegExp(r'[vV]')) ? value : 'v$value';
  }
}
