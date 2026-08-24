import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/text_encoding_codec.dart';
import 'package:vscope_serial/services/windows_code_page_codec.dart';

void main() {
  test('GBK 编解码往返', () {
    const text = '中文测试';
    final encoded = encodeWindowsCodePage(text, 936);
    expect(decodeWindowsCodePage(encoded, 936), text);
  });

  test('BIG5 编解码往返', () {
    const text = '中文測試';
    final encoded = encodeWindowsCodePage(text, 950);
    expect(decodeWindowsCodePage(encoded, 950), text);
  });

  test('Shift_JIS 编解码往返', () {
    const text = '日本語テスト';
    final encoded = encodeWindowsCodePage(text, 932);
    expect(decodeWindowsCodePage(encoded, 932), text);
  });

  test('EUC-KR 编解码往返', () {
    const text = '한국어테스트';
    final encoded = encodeWindowsCodePage(text, 949);
    expect(decodeWindowsCodePage(encoded, 949), text);
  });

  test('text_encoding_codec 按编码名路由到对应代码页', () {
    const text = '中文';
    expect(decodeTextBytes(encodeTextBytes(text, 'GBK'), 'GBK'), text);
    expect(decodeTextBytes(encodeTextBytes(text, 'BIG5'), 'BIG5'), text);
    expect(
      decodeTextBytes(encodeTextBytes(text, 'Shift_JIS'), 'Shift_JIS'),
      text,
    );
    expect(decodeTextBytes(encodeTextBytes(text, 'EUC-KR'), 'EUC-KR'), text);
  });

  test('空输入返回空结果', () {
    expect(decodeWindowsCodePage(Uint8List(0), 936), '');
    expect(encodeWindowsCodePage('', 936), isEmpty);
  });
}
