import 'dart:convert';
import 'dart:typed_data';

import 'windows_code_page_codec.dart';

/// Shell 可选的文本编码。
const shellTextEncodings = <String>[
  'UTF-8',
  'GBK',
  'BIG5',
  'Shift_JIS',
  'EUC-KR',
  'Latin-1',
  'ASCII',
];

/// 保留跨串口数据块的不完整字符，并以流式方式输出完整文本。
///
/// 串口回调边界与字符边界无关。中文、日文和韩文双字节字符以及 UTF-8
/// 多字节字符可能拆到相邻回调中；直接逐包解码会产生替换字符或乱码。
class ShellStreamDecoder {
  ShellStreamDecoder(this.encoding);

  String encoding;
  Uint8List _carry = Uint8List(0);

  String add(Uint8List chunk) {
    if (chunk.isEmpty) return '';
    final bytes =
        Uint8List(_carry.length + chunk.length)
          ..setRange(0, _carry.length, _carry)
          ..setRange(_carry.length, _carry.length + chunk.length, chunk);
    final carryLength = _incompleteSuffixLength(bytes);
    final completeLength = bytes.length - carryLength;
    _carry =
        carryLength == 0
            ? Uint8List(0)
            : Uint8List.fromList(bytes.sublist(completeLength));
    if (completeLength == 0) return '';
    return _decode(Uint8List.sublistView(bytes, 0, completeLength));
  }

  String flush() {
    if (_carry.isEmpty) return '';
    final pending = _carry;
    _carry = Uint8List(0);
    return _decode(pending);
  }

  void reset({String? encoding}) {
    if (encoding != null) this.encoding = encoding;
    _carry = Uint8List(0);
  }

  int _incompleteSuffixLength(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    return switch (encoding) {
      'UTF-8' => _utf8IncompleteSuffixLength(bytes),
      'GBK' || 'BIG5' => _dbcsIncompleteSuffixLength(bytes, _isGenericDbcsLead),
      'EUC-KR' => _dbcsIncompleteSuffixLength(
        bytes,
        (byte) => byte >= 0xA1 && byte <= 0xFE,
      ),
      'Shift_JIS' => _dbcsIncompleteSuffixLength(bytes, _isShiftJisLead),
      _ => 0,
    };
  }

  int _utf8IncompleteSuffixLength(Uint8List bytes) {
    var start = bytes.length - 1;
    var continuationCount = 0;
    while (start >= 0 && (bytes[start] & 0xC0) == 0x80) {
      continuationCount++;
      start--;
    }
    if (start < 0) return 0;
    final lead = bytes[start];
    final expected = switch (lead) {
      >= 0xC2 && <= 0xDF => 2,
      >= 0xE0 && <= 0xEF => 3,
      >= 0xF0 && <= 0xF4 => 4,
      _ => 1,
    };
    final available = continuationCount + 1;
    return expected > available ? available : 0;
  }

  bool _isGenericDbcsLead(int byte) => byte >= 0x81 && byte <= 0xFE;

  int _dbcsIncompleteSuffixLength(
    Uint8List bytes,
    bool Function(int byte) isLead,
  ) {
    var index = 0;
    while (index < bytes.length) {
      if (!isLead(bytes[index])) {
        index++;
        continue;
      }
      if (index + 1 == bytes.length) return 1;
      index += 2;
    }
    return 0;
  }

  bool _isShiftJisLead(int byte) =>
      (byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC);

  String _decode(Uint8List data) {
    String decodeOrFallback(String Function(Uint8List) decode) {
      try {
        return decode(data);
      } on FormatException {
        return String.fromCharCodes(data);
      }
    }

    return switch (encoding) {
      'UTF-8' => utf8.decode(data, allowMalformed: true),
      'GBK' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 936)),
      'BIG5' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 950)),
      'Shift_JIS' => decodeOrFallback(
        (bytes) => decodeWindowsCodePage(bytes, 932),
      ),
      'EUC-KR' => decodeOrFallback(
        (bytes) => decodeWindowsCodePage(bytes, 949),
      ),
      'Latin-1' => latin1.decode(data),
      'ASCII' => ascii.decode(data, allowInvalid: true),
      _ => utf8.decode(data, allowMalformed: true),
    };
  }
}
