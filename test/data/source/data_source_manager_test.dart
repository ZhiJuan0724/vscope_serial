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
      const durationMs = 500;
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

      expect(
        receivedData.length,
        greaterThanOrEqualTo(minExpected),
        reason:
            'Manager+1KHz随机源应达到90%速率(≥$minExpected包)，'
            '实际${receivedData.length}包(达成率${achievement.toStringAsFixed(1)}%)',
      );
    });
  });
}
