import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_source_config.dart';
import 'package:vscope_serial/data/source/data_source_manager.dart';
import 'package:vscope_serial/services/serial_service.dart';

void main() {
  group('DataSourceManager 随机源速率测试', () {
    late SerialService serialService;

    setUp(() {
      serialService = SerialService();
    });

    test('1KHz随机源通过Manager应达到90%速率', () async {
      const targetRate = 1000;
      const durationMs = 1000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final config = DataSourceConfig(
        useSerial: false,
        useRandom: true,
        randomChannelCount: 4,
        randomIntervalMs: 1, // 1KHz
      );

      final manager = DataSourceManager(serialService, config: config);
      final receivedData = <Uint8List>[];
      final subscription = manager.byteStream.listen((data) {
        receivedData.add(data);
      });

      manager.start();
      await Future.delayed(const Duration(milliseconds: durationMs));
      manager.stop();
      await subscription.cancel();

      final actualRate = receivedData.length * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: 'Manager+1KHz随机源应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('1KHz随机源10秒稳定性', () async {
      const targetRate = 1000;
      const durationMs = 10000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final config = DataSourceConfig(
        useSerial: false,
        useRandom: true,
        randomChannelCount: 4,
        randomIntervalMs: 1,
      );

      final manager = DataSourceManager(serialService, config: config);
      final receivedData = <Uint8List>[];
      final subscription = manager.byteStream.listen((data) {
        receivedData.add(data);
      });

      manager.start();
      await Future.delayed(const Duration(milliseconds: durationMs));
      manager.stop();
      await subscription.cancel();

      final actualRate = receivedData.length * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      expect(receivedData.length, greaterThanOrEqualTo(minExpected),
          reason: 'Manager+1KHz运行10秒应达到90%速率(≥$minExpected包)，'
                  '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('1KHz随机源每秒稳定性', () async {
      const targetRate = 1000;
      const minAchievement = 0.9;

      final config = DataSourceConfig(
        useSerial: false,
        useRandom: true,
        randomChannelCount: 4,
        randomIntervalMs: 1,
      );

      final manager = DataSourceManager(serialService, config: config);
      final receivedData = <Uint8List>[];
      final subscription = manager.byteStream.listen((data) {
        receivedData.add(data);
      });

      manager.start();

      final counts = <int>[];
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
        counts.add(receivedData.length);
      }

      manager.stop();
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

      for (int i = 0; i < rates.length; i++) {
        expect(rates[i], greaterThanOrEqualTo((targetRate * minAchievement).round()),
            reason: '第${i + 1}秒达成率应≥90%(≥${(targetRate * minAchievement).round()}包)，'
                    '实际${rates[i]}包');
      }
    });
  });
}
