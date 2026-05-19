import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/source/random_data_source.dart';

void main() {
  group('RandomDataSource', () {
    test('默认参数创建', () {
      final source = RandomDataSource();
      expect(source.channelCount, 4);
      expect(source.minValue, 0.0);
      expect(source.maxValue, 32768.0);
      expect(source.intervalMs, 100);
      expect(source.isActive, false);
    });

    test('自定义参数创建', () {
      final source = RandomDataSource(
        channelCount: 8,
        minValue: 100.0,
        maxValue: 1000.0,
        intervalMs: 50,
      );
      expect(source.channelCount, 8);
      expect(source.minValue, 100.0);
      expect(source.maxValue, 1000.0);
      expect(source.intervalMs, 50);
    });

    test('启动后生成数据', () async {
      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 10,
      );

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();

      // 等待 Isolate 启动完成
      await Future.delayed(const Duration(milliseconds: 20));
      expect(source.isActive, true);

      // 等待生成至少3包数据
      await Future.delayed(const Duration(milliseconds: 50));

      source.stop();
      await subscription.cancel();

      // 验证收到了数据
      expect(receivedData.length, greaterThanOrEqualTo(3));

      // 验证数据格式：FireWater 格式 "v1,v2,v3,v4\n"
      for (final data in receivedData) {
        final text = String.fromCharCodes(data);
        expect(text.endsWith('\n'), true);

        final parts = text.trim().split(',');
        expect(parts.length, 4);

        for (final part in parts) {
          final value = double.tryParse(part);
          expect(value, isNotNull);
          expect(value! >= 0.0 && value <= 32768.0, true);
        }
      }
    });

    test('高频生成测试 - 1KHz', () async {
      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 1ms = 1000Hz
      );

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();

      // 运行100ms，理论上应该生成约100包
      await Future.delayed(const Duration(milliseconds: 100));

      source.stop();
      await subscription.cancel();

      // 允许一定误差，但至少应该生成50包以上
      expect(receivedData.length, greaterThanOrEqualTo(50),
          reason: '1KHz运行100ms应至少生成50包，实际生成${receivedData.length}包');

      // 验证生成速率接近1000包/秒
      final rate = receivedData.length * 10; // 100ms * 10 = 1s
      expect(rate, greaterThanOrEqualTo(500),
          reason: '实际生成速率约 $rate 包/秒，远低于1000Hz');
    });

    test('不同通道数生成正确数据', () async {
      for (final channelCount in [1, 4, 8, 16]) {
        final source = RandomDataSource(
          channelCount: channelCount,
          intervalMs: 10,
        );

        final completer = Completer<Uint8List>();
        final subscription = source.byteStream.listen((data) {
          if (!completer.isCompleted) {
            completer.complete(data);
          }
        });

        source.start();
        final data = await completer.future.timeout(const Duration(seconds: 1));
        source.stop();
        await subscription.cancel();

        final text = String.fromCharCodes(data);
        final parts = text.trim().split(',');
        expect(parts.length, channelCount,
            reason: '通道数$channelCount应生成$channelCount个值');
      }
    });

    test('停止后不再生成数据', () async {
      final source = RandomDataSource(intervalMs: 10);

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();
      await Future.delayed(const Duration(milliseconds: 30));
      source.stop();

      final countAfterStop = receivedData.length;

      // 等待一段时间，确认没有新数据
      await Future.delayed(const Duration(milliseconds: 50));

      await subscription.cancel();

      expect(receivedData.length, countAfterStop,
          reason: '停止后不应再生成数据');
      expect(source.isActive, false);
    });

    test('数据值在范围内', () async {
      final source = RandomDataSource(
        minValue: 1000.0,
        maxValue: 2000.0,
        intervalMs: 10,
      );

      final completer = Completer<Uint8List>();
      final subscription = source.byteStream.listen((data) {
        if (!completer.isCompleted) {
          completer.complete(data);
        }
      });

      source.start();
      final data = await completer.future.timeout(const Duration(seconds: 1));
      source.stop();
      await subscription.cancel();

      final text = String.fromCharCodes(data);
      final parts = text.trim().split(',');

      for (final part in parts) {
        final value = double.parse(part);
        expect(value >= 1000.0 && value <= 2000.0, true,
            reason: '值 $value 不在范围 [1000, 2000] 内');
      }
    });
  });
}
