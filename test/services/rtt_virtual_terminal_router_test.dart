import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/rtt_virtual_terminal_router.dart';

void main() {
  test('虚拟终端切换支持跨块并保留到达顺序', () {
    final router = RttVirtualTerminalRouter();
    final first = router.add(Uint8List.fromList([0x41, 0xff]));
    final second = router.add(
      Uint8List.fromList([0x31, 0x42, 0xff, 0x46, 0x43]),
    );

    expect(first.single.terminal, 0);
    expect(first.single.data, [0x41]);
    expect(second.map((item) => item.terminal), [1, 15]);
    expect(second.map((item) => item.data), [
      [0x42],
      [0x43],
    ]);
  });

  test('非法虚拟终端序列不吞掉原始字节', () {
    final router = RttVirtualTerminalRouter();
    final result = router.add(Uint8List.fromList([0xff, 0x78, 0x41]));
    expect(result.single.terminal, 0);
    expect(result.single.data, [0xff, 0x78, 0x41]);
  });
}
