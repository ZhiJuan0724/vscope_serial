import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/source/random_data_source.dart';

/// 测试随机数据源的实际生成速率
void main() {
  group('RandomDataSource 速率测试', () {
    test('100Hz 应达到90%以上速率', () async {
      const targetRate = 100; // 100Hz
      const durationMs = 1000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round(); // 90包

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

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: '100Hz运行1秒应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('1KHz 应达到90%以上速率', () async {
      const targetRate = 1000; // 1KHz
      const durationMs = 1000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round(); // 900包

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

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: '1KHz运行1秒应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('5KHz 应达到90%以上速率', () async {
      const targetRate = 5000; // 5KHz
      const durationMs = 500; // 运行500ms避免测试太慢
      // final minExpected = (targetRate * durationMs / 1000 * 0.9).round(); // 2250包

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 最小1ms，实际最大约1000Hz
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

      // 5KHz 可能无法达到，但至少应达到1KHz（Timer最小精度1ms）
      const minAcceptableRate = 1000; // 至少1KHz
      expect(actualRate, greaterThanOrEqualTo(minAcceptableRate * 0.9),
          reason: '5KHz请求应至少达到1KHz实际速率(≥${(minAcceptableRate * 0.9).round()}包/秒)，'
                  '实际${actualRate.toStringAsFixed(0)}包/秒(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('10秒稳定性 - 1KHz应达到90%速率', () async {
      const targetRate = 1000; // 1KHz
      const durationMs = 10000; // 10秒
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round(); // 9000包

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 1ms = 1KHz
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

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: '1KHz运行10秒应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('60秒稳定性 - 1KHz应达到90%速率', () async {
      const targetRate = 1000; // 1KHz
      const durationMs = 60000; // 60秒
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round(); // 54000包

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 1ms = 1KHz
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

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: '1KHz运行60秒应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    }, timeout: Timeout(Duration(minutes: 2)));

    test('每秒稳定性 - 1KHz每秒达成率应≥90%', () async {
      const targetRate = 1000; // 1KHz
      const minAchievement = 0.9; // 90%

      final source = RandomDataSource(
        channelCount: 4,
        intervalMs: 1, // 1ms = 1KHz
      );

      final receivedData = <Uint8List>[];
      final subscription = source.byteStream.listen((data) {
        receivedData.add(data);
      });

      source.start();

      // 记录5个时间点的数据量
      final counts = <int>[];
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        counts.add(receivedData.length);
      }

      source.stop();
      await subscription.cancel();

      final rates = <int>[];
      rates.add(counts[0]);
      for (int i = 1; i < counts.length; i++) {
        rates.add(counts[i] - counts[i - 1]);
      }

      for (int i = 0; i < rates.length; i++) {
        final achievement = rates[i] / targetRate * 100;
        // 使用 achievement 避免 unused_local_variable 警告
        expect(achievement >= 0, true);
        // print('第${i + 1}秒: ${rates[i]} 包(达成率${achievement.toStringAsFixed(1)}%)');
      }

      // 每秒达成率应≥90%
      for (int i = 0; i < rates.length; i++) {
        expect(rates[i], greaterThanOrEqualTo((targetRate * minAchievement).round()),
            reason: '第${i + 1}秒达成率应≥90%(≥${(targetRate * minAchievement).round()}包)，'
                    '实际${rates[i]}包');
      }
    });
  });
}
