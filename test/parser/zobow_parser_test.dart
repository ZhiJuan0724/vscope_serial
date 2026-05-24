import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/parser/zobow_parser.dart';

/// 众邦电控解析器单元测试
///
/// 测试覆盖：
/// - 正确帧的解析
/// - CRC错误帧的拒绝
/// - 滑动窗口分包（模拟字节流不整帧到达）
/// - 缓冲区溢出处理
/// - uint16/int16 数据类型转换
void main() {
  group('ZobowParser', () {
    late ZobowParser parser;
    late ParserConfig config;

    setUp(() {
      config = ParserConfig.zobowDefault();
      parser = ZobowParser(config);
    });

    tearDown(() {
      parser.dispose();
    });

    /// 构造一帧测试数据
    ///
    /// [values] 4个通道的uint16值
    /// 返回10字节数据（8字节数据 + 2字节CRC16/MODBUS小端序）
    Uint8List buildFrame(List<int> values) {
      assert(values.length == 4);
      final bytes = Uint8List(10);
      final buffer = ByteData.sublistView(bytes);
      for (int i = 0; i < 4; i++) {
        buffer.setUint16(i * 2, values[i], Endian.little);
      }
      final crc = calculateCrc(
        Uint8List.sublistView(bytes, 0, 8),
        crc16Polys['CRC-16/MODBUS']!,
      );
      bytes[8] = crc & 0xFF;
      bytes[9] = (crc >> 8) & 0xFF;
      return bytes;
    }

    Uint8List buildFrameWithCount(List<int> values) {
      final bytes = Uint8List(values.length * 2 + 2);
      final buffer = ByteData.sublistView(bytes);
      for (int i = 0; i < values.length; i++) {
        buffer.setUint16(i * 2, values[i], Endian.little);
      }
      final dataLength = values.length * 2;
      final crc = calculateCrc(
        Uint8List.sublistView(bytes, 0, dataLength),
        crc16Polys['CRC-16/MODBUS']!,
      );
      bytes[dataLength] = crc & 0xFF;
      bytes[dataLength + 1] = (crc >> 8) & 0xFF;
      return bytes;
    }

    test('正确帧解析', () async {
      final frame = buildFrame([100, 200, 300, 400]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0], [100.0, 200.0, 300.0, 400.0]);
    });

    test('8通道帧解析', () async {
      config.channelCount = 8;
      parser = ZobowParser(config);
      final frame = buildFrameWithCount([
        100,
        200,
        300,
        400,
        500,
        600,
        700,
        800,
      ]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0], [
        100.0,
        200.0,
        300.0,
        400.0,
        500.0,
        600.0,
        700.0,
        800.0,
      ]);
      expect(results[0].length, 8);
    });

    test('CRC错误帧应被拒绝', () async {
      final frame = buildFrame([100, 200, 300, 400]);
      // 篡改CRC
      frame[8] = 0xFF;
      frame[9] = 0xFF;

      final results = <List<double>>[];
      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 0);
    });

    test('滑动窗口分包 - 逐字节到达', () async {
      final frame = buildFrame([1000, 2000, 3000, 4000]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      // 逐字节发送
      for (final byte in frame) {
        parser.feed(Uint8List.fromList([byte]));
      }
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0], [1000.0, 2000.0, 3000.0, 4000.0]);
    });

    test('滑动窗口分包 - 半帧到达', () async {
      final frame = buildFrame([111, 222, 333, 444]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      // 先发送前5字节
      parser.feed(Uint8List.sublistView(frame, 0, 5));
      await Future.delayed(const Duration(milliseconds: 20));
      expect(results.length, 0); // 不完整，不应解析

      // 再发送后5字节
      parser.feed(Uint8List.sublistView(frame, 5, 10));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0], [111.0, 222.0, 333.0, 444.0]);
    });

    test('多帧连续到达', () async {
      final frame1 = buildFrame([100, 200, 300, 400]);
      final frame2 = buildFrame([500, 600, 700, 800]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      // 合并发送
      final combined = Uint8List(20);
      combined.setRange(0, 10, frame1);
      combined.setRange(10, 20, frame2);
      parser.feed(combined);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 2);
      expect(results[0], [100.0, 200.0, 300.0, 400.0]);
      expect(results[1], [500.0, 600.0, 700.0, 800.0]);
    });

    test('int16 数据类型转换', () async {
      // 设置通道0为int16
      config.zobowChannelTypes[0] = DataType.int16;
      parser = ZobowParser(config);

      final frame = buildFrame([0xFFFF, 100, 200, 300]); // 0xFFFF as int16 = -1
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0][0], -1.0); // int16: 0xFFFF = -1
      expect(results[0][1], 100.0); // 其他通道仍为uint16
    });

    test('混合数据类型', () async {
      // Ch0: int16, Ch1: uint16, Ch2: int16, Ch3: uint16
      config.zobowChannelTypes = [
        DataType.int16,
        DataType.uint16,
        DataType.int16,
        DataType.uint16,
      ];
      parser = ZobowParser(config);

      final frame = buildFrame([
        0xFFFE,
        1000,
        0x8000,
        500,
      ]); // -2, 1000, -32768, 500
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
      expect(results[0][0], -2.0); // int16: 0xFFFE = -2
      expect(results[0][1], 1000.0); // uint16
      expect(results[0][2], -32768.0); // int16: 0x8000 = -32768
      expect(results[0][3], 500.0); // uint16
    });

    test('reset 清空缓冲区', () async {
      final frame = buildFrame([100, 200, 300, 400]);
      final results = <List<double>>[];

      parser.outputStream.listen((result) {
        if (result.success && result.values != null) {
          results.add(result.values!);
        }
      });

      // 发送半帧
      parser.feed(Uint8List.sublistView(frame, 0, 5));
      parser.reset(); // 重置
      await Future.delayed(const Duration(milliseconds: 20));

      // 再发送完整帧
      parser.feed(frame);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(results.length, 1);
    });
  });
}
