import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';

import '../data/models/zobow_config_profile.dart';

class ZobowCProfileImportResult {
  final List<ZobowChannelPreset> presets;
  final int commentNameCount;

  const ZobowCProfileImportResult({
    required this.presets,
    required this.commentNameCount,
  });

  bool get isEmpty => presets.isEmpty;
}

class ZobowCProfileImporter {
  static Future<ZobowCProfileImportResult> parseFile(
    String path, {
    bool useComments = true,
  }) async {
    final bytes = await File(path).readAsBytes();
    return parseBytes(bytes, useComments: useComments);
  }

  static ZobowCProfileImportResult parseBytes(
    Uint8List bytes, {
    bool useComments = true,
  }) {
    final candidates = <ZobowCProfileImportResult>[];
    try {
      candidates.add(parseSource(utf8.decode(bytes), useComments: useComments));
    } on FormatException {
      candidates.add(
        parseSource(
          utf8.decode(bytes, allowMalformed: true),
          useComments: useComments,
        ),
      );
    }

    try {
      candidates.add(parseSource(gbk.decode(bytes), useComments: useComments));
    } on FormatException {
      candidates.add(
        parseSource(
          gbk.decode(bytes, allowMalformed: true),
          useComments: useComments,
        ),
      );
    }

    try {
      candidates.add(
        parseSource(systemEncoding.decode(bytes), useComments: useComments),
      );
    } on FormatException {
      // Some platforms cannot decode arbitrary legacy byte streams with the
      // system codec. The malformed UTF-8 candidate above still provides a
      // variable-name fallback when comments are unreadable.
    }
    candidates.sort((a, b) {
      final comments = b.commentNameCount.compareTo(a.commentNameCount);
      if (comments != 0) return comments;
      return b.presets.length.compareTo(a.presets.length);
    });
    return candidates.first;
  }

  static ZobowCProfileImportResult parseSource(
    String source, {
    bool useComments = true,
  }) {
    final functionBody = _extractFunctionBody(source);
    if (functionBody == null) {
      return const ZobowCProfileImportResult(presets: [], commentNameCount: 0);
    }

    final switchBody = _extractLongestSwitchBody(functionBody);
    if (switchBody == null) {
      return const ZobowCProfileImportResult(presets: [], commentNameCount: 0);
    }

    final presets = <ZobowChannelPreset>[];
    final seenAddresses = <int>{};
    var commentNameCount = 0;
    final casePattern = RegExp(
      r'\bcase\s+((?:0[xX][0-9a-fA-F]+)|(?:[0-9]+))\s*:',
    );
    final matches = casePattern.allMatches(switchBody).toList();

    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      final address = _parseAddress(match.group(1)!);
      if (address == null) continue;
      final normalizedAddress = address & 0xFFFFFFFF;
      if (seenAddresses.contains(normalizedAddress)) continue;

      final blockStart = match.end;
      final blockEnd =
          i + 1 < matches.length ? matches[i + 1].start : switchBody.length;
      final block = switchBody.substring(blockStart, blockEnd);
      if (!RegExp(r'\bbreak\s*;').hasMatch(block)) continue;

      final assignment = RegExp(
        r'\bVsTemp(?:\s*\[\s*i\s*\])?\s*=\s*(.*?);',
        dotAll: true,
      ).firstMatch(block);
      if (assignment == null) continue;

      String? commentName;
      if (useComments) {
        final caseLine = _lineAt(switchBody, match.start);
        final assignmentLine = _lineAt(block, assignment.start);
        final caseComment = _validCommentName(
          _lineComment(caseLine),
          normalizedAddress,
        );
        final assignmentComment = _validCommentName(
          _lineComment(assignmentLine),
          normalizedAddress,
        );
        commentName = caseComment ?? assignmentComment;
      }
      final name =
          commentName ??
          _nameFromExpression(assignment.group(1)!) ??
          _formatAddress(normalizedAddress);

      presets.add(ZobowChannelPreset(name: name, address: normalizedAddress));
      seenAddresses.add(normalizedAddress);
      if (commentName != null) commentNameCount++;
    }

    return ZobowCProfileImportResult(
      presets: presets,
      commentNameCount: commentNameCount,
    );
  }

  static String? _extractFunctionBody(String source) {
    final functionMatch = RegExp(
      r'\bChxValueTable\s*\([^;{]*\)\s*\{',
      dotAll: true,
    ).firstMatch(source);
    if (functionMatch == null) return null;
    return _balancedBody(source, functionMatch.end - 1);
  }

  static String? _extractLongestSwitchBody(String source) {
    final switchMatches = RegExp(
      r'\bswitch\s*\([^)]*\)\s*\{',
      dotAll: true,
    ).allMatches(source);
    String? longestBody;
    for (final match in switchMatches) {
      final body = _balancedBody(source, match.end - 1);
      if (body == null) continue;
      if (longestBody == null || body.length > longestBody.length) {
        longestBody = body;
      }
    }
    return longestBody;
  }

  static String? _balancedBody(String source, int openBraceIndex) {
    var depth = 0;
    var inLineComment = false;
    var inBlockComment = false;
    var inString = false;
    var inChar = false;

    for (int i = openBraceIndex; i < source.length; i++) {
      final char = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';

      if (inLineComment) {
        if (char == '\n') inLineComment = false;
        continue;
      }
      if (inBlockComment) {
        if (char == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }
      if (inString) {
        if (char == '\\') {
          i++;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (inChar) {
        if (char == '\\') {
          i++;
        } else if (char == "'") {
          inChar = false;
        }
        continue;
      }

      if (char == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }
      if (char == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }
      if (char == '"') {
        inString = true;
        continue;
      }
      if (char == "'") {
        inChar = true;
        continue;
      }
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          return source.substring(openBraceIndex + 1, i);
        }
      }
    }
    return null;
  }

  static int? _parseAddress(String text) {
    if (text.startsWith('0x') || text.startsWith('0X')) {
      return int.tryParse(text.substring(2), radix: 16);
    }
    return int.tryParse(text);
  }

  static String _lineAt(String source, int offset) {
    final start = source.lastIndexOf('\n', offset - 1) + 1;
    final end = source.indexOf('\n', offset);
    return source.substring(start, end == -1 ? source.length : end);
  }

  static String? _lineComment(String line) {
    final index = line.indexOf('//');
    if (index < 0) return null;
    final comment = line.substring(index + 2).trim();
    if (comment.isEmpty) return null;
    return comment;
  }

  static String? _validCommentName(String? comment, int address) {
    if (comment == null) return null;
    final cleaned =
        comment
            .replaceAll(RegExp(r'/+'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (cleaned.isEmpty || _looksGarbled(cleaned)) return null;
    final numeric = _parseNumericComment(cleaned);
    if (numeric != null) return null;
    if (!RegExp(r'[A-Za-z0-9_\u4e00-\u9fff]').hasMatch(cleaned)) return null;
    return cleaned;
  }

  static bool _looksGarbled(String text) {
    if (text.contains('�') || text.contains('锟')) return true;
    if (RegExp(r'[μáà÷·′]').hasMatch(text)) return true;
    if (text.contains('?') &&
        !RegExp(r'[\u4e00-\u9fff]').hasMatch(text) &&
        RegExp(r'[^\x00-\x7F]').hasMatch(text)) {
      return true;
    }
    final suspicious = RegExp(r'[閫氶亾鏁版嵁绋庤]').allMatches(text).length;
    return suspicious >= 3;
  }

  static int? _parseNumericComment(String text) {
    final compact = text.trim();
    if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(compact)) {
      return int.tryParse(compact.substring(2), radix: 16);
    }
    if (RegExp(r'^[0-9]+$').hasMatch(compact)) {
      return int.tryParse(compact);
    }
    return null;
  }

  static String? _nameFromExpression(String expression) {
    final withoutComments = expression.replaceAll(RegExp(r'//.*'), ' ');
    final compact = withoutComments.replaceAll(RegExp(r'\s+'), '').trim();
    return compact.isEmpty ? null : compact;
  }

  static String _formatAddress(int address) =>
      '0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}';
}
