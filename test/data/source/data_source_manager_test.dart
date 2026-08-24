import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_source_config.dart';
import 'package:vscope_serial/data/source/data_source_manager.dart';
import 'package:vscope_serial/services/data_connection_service.dart';

void main() {
  group('DataSourceManager 随机源速率测试', () {
    late DataConnectionService connectionService;

    setUp(() {
      connectionService = DataConnectionService();
    });

    test('1KHz随机源通过Manager应达到90%速率', () async {
      const targetRate = 1000;
      const durationMs = 500;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final config = DataSourceConfig(
        useConnection: false,
        useRandom: true,
        randomChannelCount: 4,
        randomFrequencyHz: targetRate.toDouble(),
      );

      final manager = DataSourceManager(connectionService, config: config);
      final receivedData = <Uint8List>[];
      final subscription = manager.byteStream.listen(receivedData.add);

      await manager.start();
      await Future.delayed(const Duration(milliseconds: durationMs));
      await manager.stop();
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

    test('并发生命周期操作串行收敛且停止后不再输出旧事件', () async {
      final config = DataSourceConfig(
        useConnection: false,
        useRandom: true,
        randomChannelCount: 4,
        randomFrequencyHz: 1000,
      );
      final manager = DataSourceManager(connectionService, config: config);
      var received = 0;
      final subscription = manager.byteStream.listen((_) => received++);

      await Future.wait([
        manager.start(),
        manager.updateConfig(config.copyWith(randomFrequencyHz: 500)),
        manager.stop(),
      ]);
      final countAfterStop = received;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(manager.isActive, isFalse);
      expect(received, countAfterStop);

      await manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(manager.isActive, isTrue);
      expect(received, greaterThan(countAfterStop));
      await manager.stop();
      await subscription.cancel();
      await manager.dispose();
    });
  });
}
