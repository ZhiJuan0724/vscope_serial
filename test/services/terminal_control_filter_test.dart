import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/terminal_control_filter.dart';

void main() {
  test('跨块过滤 ANSI CSI 颜色序列并保留文本', () {
    final filter = TerminalControlFilter();

    expect(filter.add('\x1b[3'), '');
    expect(filter.add('2m<inf>\x1b['), '<inf>');
    expect(filter.add('0m message\n'), ' message\n');
  });

  test('过滤 OSC 标题和其他不可见终端控制字符串', () {
    final filter = TerminalControlFilter();

    expect(filter.add('before\x1b]0;title'), 'before');
    expect(filter.add('\x07after\x1bPprivate'), 'after');
    expect(filter.add(' payload\x1b\\done'), 'done');
  });
}
