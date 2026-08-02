import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/byte_size_formatter.dart';

void main() {
  test('formatByteSize 统一使用二进制单位并控制小数位', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(1023), '1023 B');
    expect(formatByteSize(1024), '1.0 KiB');
    expect(formatByteSize(1536), '1.5 KiB');
    expect(formatByteSize(1024 * 1024), '1.0 MiB');
    expect(formatByteSize(3 * 1024 * 1024 * 1024), '3.0 GiB');
  });
}
