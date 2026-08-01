import 'dart:convert';
import 'dart:typed_data';

import 'windows_code_page_codec.dart';

String decodeTextBytes(Uint8List data, String encoding) {
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
    'EUC-KR' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 949)),
    'Latin-1' => decodeOrFallback(latin1.decode),
    'ASCII' => decodeOrFallback(ascii.decode),
    _ => utf8.decode(data, allowMalformed: true),
  };
}

Uint8List encodeTextBytes(String text, String encoding) {
  final bytes = switch (encoding) {
    'UTF-8' => utf8.encode(text),
    'GBK' => encodeWindowsCodePage(text, 936),
    'BIG5' => encodeWindowsCodePage(text, 950),
    'Shift_JIS' => encodeWindowsCodePage(text, 932),
    'EUC-KR' => encodeWindowsCodePage(text, 949),
    'Latin-1' => latin1.encode(text),
    'ASCII' => ascii.encode(text),
    _ => utf8.encode(text),
  };
  return Uint8List.fromList(bytes);
}
