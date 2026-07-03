import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';

import '../data/models/address_config_profile.dart';

class ZobowCProfileImportResult {
  final List<AddressChannelPreset> presets;
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
      // 部分平台无法用系统编码解码任意旧版字节流。
      // 即使注释不可读，上面的异常 UTF-8 候选仍能提供变量名兜底。
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

    final presets = <AddressChannelPreset>[];
    final seenAddresses = <int>{};
    var commentNameCount = 0;
    // 匹配 switch case 地址，支持十六进制 0xNN 和十进制数字。
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
      // 匹配 case 块内的 break;，避免贯穿到下一个 case 时误导入。
      if (!RegExp(r'\bbreak\s*;').hasMatch(block)) continue;

      final assignment = _findValueAssignment(block);
      if (assignment == null) continue;

      String? commentName;
      if (useComments) {
        final caseLine = _lineAt(switchBody, match.start);
        final assignmentLine = _lineAt(block, assignment.startOffset);
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
          _nameFromExpression(assignment.expression) ??
          _formatAddress(normalizedAddress);

      presets.add(AddressChannelPreset(name: name, address: normalizedAddress));
      seenAddresses.add(normalizedAddress);
      if (commentName != null) commentNameCount++;
    }

    return ZobowCProfileImportResult(
      presets: presets,
      commentNameCount: commentNameCount,
    );
  }

  static String? _extractFunctionBody(String source) {
    final functions = _extractFunctions(source);
    final namedMatch =
        functions
            .where((function) => function.name == 'ChxValueTable')
            .firstOrNull ??
        functions
            .where((function) => function.name == 'VisualScope')
            .firstOrNull;
    if (namedMatch != null) return namedMatch.body;

    return functions.length == 1 ? functions.single.body : null;
  }

  static List<_CFunction> _extractFunctions(String source) {
    final functions = <_CFunction>[];
    // 匹配普通 C 函数定义开头，提取函数名并定位后续花括号函数体。
    final functionMatches = RegExp(
      r'\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{',
      dotAll: true,
    ).allMatches(source);
    for (final match in functionMatches) {
      final name = match.group(1)!;
      if (_cControlKeywords.contains(name)) continue;
      final body = _balancedBody(source, match.end - 1);
      if (body == null) continue;
      functions.add(_CFunction(name: name, body: body));
    }
    return functions;
  }

  static String? _extractLongestSwitchBody(String source) {
    // 匹配 switch (...) { 的起点，函数内可能有多个 switch，后续取最长的。
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
    if (offset <= 0) {
      final end = source.indexOf('\n');
      return source.substring(0, end == -1 ? source.length : end);
    }
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
    // 匹配注释中连续的斜杠，统一当作分隔符清理。
    final slashSeparators = RegExp(r'/+');
    // 匹配连续空白，压缩成单个空格便于展示。
    final whitespace = RegExp(r'\s+');
    final cleaned =
        comment
            .replaceAll(slashSeparators, ' ')
            .replaceAll(whitespace, ' ')
            .trim();
    if (cleaned.isEmpty || _looksGarbled(cleaned)) return null;
    final numeric = _parseNumericComment(cleaned);
    if (numeric != null) return null;
    // 匹配至少一个可读的英文、数字、下划线或中文字符，过滤纯符号注释。
    final readableNameChar = RegExp(r'[A-Za-z0-9_\u4e00-\u9fff]');
    if (!readableNameChar.hasMatch(cleaned)) return null;
    return cleaned;
  }

  static bool _looksGarbled(String text) {
    if (text.contains('�') || text.contains('锟')) return true;
    // 匹配常见 GBK/UTF-8 错解后混入的异常符号片段。
    final mojibakeSymbol = RegExp(r'[μáà÷·′]');
    if (mojibakeSymbol.hasMatch(text)) return true;
    // 匹配中文字符，用于判断问号是否可能来自乱码而不是普通英文注释。
    final chineseChar = RegExp(r'[\u4e00-\u9fff]');
    // 匹配非 ASCII 字符，用于识别混合问号的异常编码文本。
    final nonAsciiChar = RegExp(r'[^\x00-\x7F]');
    if (text.contains('?') &&
        !chineseChar.hasMatch(text) &&
        nonAsciiChar.hasMatch(text)) {
      return true;
    }
    // 匹配常见中文乱码残片，出现较多时认为注释不可用。
    final mojibakeChineseFragment = RegExp(r'[閫氶亾鏁版嵁绋庤]');
    final suspicious = mojibakeChineseFragment.allMatches(text).length;
    return suspicious >= 3;
  }

  static int? _parseNumericComment(String text) {
    final compact = text.trim();
    // 匹配整段注释就是十六进制地址的情况，此类注释不作为名称。
    final hexAddressOnly = RegExp(r'^0[xX][0-9a-fA-F]+$');
    if (hexAddressOnly.hasMatch(compact)) {
      return int.tryParse(compact.substring(2), radix: 16);
    }
    // 匹配整段注释就是十进制地址的情况，此类注释不作为名称。
    final decimalAddressOnly = RegExp(r'^[0-9]+$');
    if (decimalAddressOnly.hasMatch(compact)) {
      return int.tryParse(compact);
    }
    return null;
  }

  static _CAssignment? _findValueAssignment(String block) {
    // 匹配 case 块内任意一条简单赋值语句，用于判断该 case 是否只有唯一赋值。
    final assignmentStatement = RegExp(
      r'(?:^|[;\n{}])\s*[A-Za-z_]\w*(?:(?:\s*\.|\s*->)\s*[A-Za-z_]\w*|\s*\[[^\]]+\])*\s*=\s*(.*?);',
      dotAll: true,
    );
    final assignments = assignmentStatement.allMatches(block).toList();
    if (assignments.length != 1) return null;

    // 匹配已知输出左值：VsTemp / VsTemp[i] / TxVar.VsCh[i]，提取等号右侧表达式。
    final knownValueAssignment = RegExp(
      r'\b(?:VsTemp(?:\s*\[\s*i\s*\])?|TxVar\s*\.\s*VsCh\s*\[\s*i\s*\])\s*=\s*(.*?);',
      dotAll: true,
    ).firstMatch(block);
    if (knownValueAssignment != null) {
      return _CAssignment(
        startOffset: knownValueAssignment.start,
        expression: knownValueAssignment.group(1)!,
      );
    }

    return _CAssignment(
      startOffset: assignments.single.start,
      expression: assignments.single.group(1)!,
    );
  }

  static String? _nameFromExpression(String expression) {
    // 匹配右值表达式末尾的行注释，生成名称时需要剔除。
    final lineComment = RegExp(r'//.*');
    final withoutComments = expression.replaceAll(lineComment, ' ');
    // 匹配表达式内所有空白，名称兜底时压缩成紧凑表达式。
    final whitespace = RegExp(r'\s+');
    final compact = withoutComments.replaceAll(whitespace, '').trim();
    return compact.isEmpty ? null : compact;
  }

  static String _formatAddress(int address) =>
      '0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  static const _cControlKeywords = {'if', 'for', 'while', 'switch', 'do'};
}

class _CFunction {
  final String name;
  final String body;

  const _CFunction({required this.name, required this.body});
}

class _CAssignment {
  final int startOffset;
  final String expression;

  const _CAssignment({required this.startOffset, required this.expression});
}
