import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/j_scope_rtt_parser.dart';

void main() {
  test('J-Scope 解析支持分包、粘包和时间戳回绕', () {
    final parser = JScopeRttParser(
      JScopeFormat.parseChannelName('JScope_t4_f4_i2'),
    );
    Uint8List packet(int timestamp, double value, int integer) {
      final data =
          ByteData(10)
            ..setUint32(0, timestamp, Endian.little)
            ..setFloat32(4, value, Endian.little)
            ..setInt16(8, integer, Endian.little);
      return data.buffer.asUint8List();
    }

    final bytes = Uint8List.fromList([
      ...packet(0xfffffff0, 1.5, -2),
      ...packet(0x10, 2.5, 3),
    ]);
    expect(parser.add(Uint8List.sublistView(bytes, 0, 7)), isEmpty);
    final samples = parser.add(Uint8List.sublistView(bytes, 7));
    expect(samples.length, 2);
    expect(samples.first.values, [1.5, -2]);
    expect(samples.last.x, greaterThan(samples.first.x));
  });

  test('J-Scope 拒绝未知字段和超过十二个字段', () {
    expect(
      () => JScopeFormat.parseChannelName('JScope_f8'),
      throwsFormatException,
    );
    expect(
      () => JScopeFormat.parseChannelName(
        'JScope_u1_u1_u1_u1_u1_u1_u1_u1_u1_u1_u1_u1_u1',
      ),
      throwsFormatException,
    );
  });

  test('J-Scope 支持通道名中的紧凑 i4u4 格式', () {
    final format = JScopeFormat.parse('JScope_i4u4');

    expect(format.fields.length, 2);
    expect(format.packetLength, 8);
    expect(JScopeFormat.tryParse('普通日志通道'), isNull);
  });
}
