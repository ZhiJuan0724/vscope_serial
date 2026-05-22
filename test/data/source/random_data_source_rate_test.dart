import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/source/random_data_source.dart';

/// 测试随机数据源的实际生成速率
void main() {
  group('RandomDataSource 速率测试', () {
    // 速率单测只覆盖短窗口健康度，长时间稳定性放到手工/集成验收。
    test('100Hz 应达到90%以上速率', () async {
      const targetRate = 100; // 100Hz
      const durationMs = 500;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 10, // 10ms = 100Hz
      );

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();
      await Future.delayed(const Duration(milliseconds: durationMs));
      source.stop();
      await subscription.cancel();

      final actualRate = receivedData.length * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      expect(
        receivedData.length,
        greaterThanOrEqualTo(minExpected),
        reason:
            '100Hz运行${durationMs}ms应达到90%速率(≥$minExpected包)，'
            '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)',
      );
    });

    test('1KHz 应达到90%以上速率', () async {
      const targetRate = 1000; // 1KHz
      const durationMs = 500;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 1ms = 1000Hz
      );

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();
      await Future.delayed(const Duration(milliseconds: durationMs));
      source.stop();
      await subscription.cancel();

      final actualRate = receivedData.length * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      expect(
        receivedData.length,
        greaterThanOrEqualTo(minExpected),
        reason:
            '1KHz运行${durationMs}ms应达到90%速率(≥$minExpected包)，'
            '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)',
      );
    });
  });
}
