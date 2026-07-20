import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/data/protocol/zobow_device_protocol_codec.dart';

void main() {
  group('ZobowDeviceProtocolCodec', () {
    test('初始化帧使用4字节小端通道号', () {
      final frame = zobowDeviceSendProtocol.buildInitFrame([
        0x01020304,
        0x11223344,
        0xAABBCCDD,
        0x00000005,
      ]);

      expect(frame.length, 18);
      expect(frame.sublist(0, 16), [
        0x04,
        0x03,
        0x02,
        0x01,
        0x44,
        0x33,
        0x22,
        0x11,
        0xDD,
        0xCC,
        0xBB,
        0xAA,
        0x05,
        0x00,
        0x00,
        0x00,
      ]);

      final crc = calculateCrc(
        frame.sublist(0, 16),
        crc16Polys['CRC-16/MODBUS']!,
      );
      expect(frame[16], crc & 0xFF);
      expect(frame[17], (crc >> 8) & 0xFF);
    });

    test('初始化帧支持8通道', () {
      final frame = zobowDeviceSendProtocol.buildInitFrame([
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);

      expect(frame.length, 34);
      expect(frame.sublist(0, 32), [
        1,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        3,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        5,
        0,
        0,
        0,
        6,
        0,
        0,
        0,
        7,
        0,
        0,
        0,
        8,
        0,
        0,
        0,
      ]);

      final crc = calculateCrc(
        frame.sublist(0, 32),
        crc16Polys['CRC-16/MODBUS']!,
      );
      expect(frame[32], crc & 0xFF);
      expect(frame[33], (crc >> 8) & 0xFF);
    });
  });
}
