import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/parser/firewater_parser.dart';
import 'package:vscope_serial/data/models/parser_config.dart';

void main() {
  group('FireWaterParser', () {
    test('解析单行数据', () async {
      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      parser.feed(Uint8List.fromList('1.0,2.0,3.0,4.0\n'.codeUnits));

      await Future.delayed(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(results.length, 1);
      expect(results[0].success, true);
      expect(results[0].values, [1.0, 2.0, 3.0, 4.0]);
    });

    test('解析多行数据', () async {
      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      parser.feed(Uint8List.fromList('1.0,2.0\n3.0,4.0\n5.0,6.0\n'.codeUnits));

      await Future.delayed(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(results.length, 3);
      expect(results[0].values, [1.0, 2.0]);
      expect(results[1].values, [3.0, 4.0]);
      expect(results[2].values, [5.0, 6.0]);
    });

    test('分多次feed解析', () async {
      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      // 分两次发送，模拟网络/串口分包
      parser.feed(Uint8List.fromList('1.0,2.0,'.codeUnits));
      await Future.delayed(const Duration(milliseconds: 5));
      parser.feed(Uint8List.fromList('3.0,4.0\n'.codeUnits));

      await Future.delayed(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(results.length, 1);
      expect(results[0].values, [1.0, 2.0, 3.0, 4.0]);
    });

    test('高频数据解析 - 模拟1KHz', () async {
      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      // 模拟1KHz数据：1ms一包
      final line = '100.0,200.0,300.0,400.0\n';
      final bytes = Uint8List.fromList(line.codeUnits);

      // 发送1000包
      for (int i = 0; i < 1000; i++) {
        parser.feed(bytes);
      }

      await Future.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      expect(results.length, 1000, reason: '应解析出1000包数据，实际${results.length}包');

      for (final result in results) {
        expect(result.success, true);
        expect(result.values, [100.0, 200.0, 300.0, 400.0]);
      }
    });

    test('固定通道数模式', () async {
      final config = ParserConfig.fireWaterDefault()..fireWaterChannelCount = 4;
      final parser = FireWaterParser(config);
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      // 发送8通道数据，应截断为4通道
      parser.feed(
        Uint8List.fromList('1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0\n'.codeUnits),
      );

      await Future.delayed(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(results.length, 1);
      expect(results[0].values.length, 4);
      expect(results[0].values, [1.0, 2.0, 3.0, 4.0]);
    });

    test('通道数不足返回失败', () async {
      final config = ParserConfig.fireWaterDefault()..fireWaterChannelCount = 8;
      final parser = FireWaterParser(config);
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      // 只发送4通道数据，但要求8通道
      parser.feed(Uint8List.fromList('1.0,2.0,3.0,4.0\n'.codeUnits));

      await Future.delayed(const Duration(milliseconds: 10));
      await subscription.cancel();

      expect(results.length, 1);
      expect(results[0].success, false);
    });
  });
}
