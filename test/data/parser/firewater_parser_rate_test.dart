import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/parser/firewater_parser.dart';

/// 测试 FireWater 解析器在高频下的解析速率
void main() {
  group('FireWaterParser 高频解析测试', () {
    test('1KHz数据流解析应达到90%速率', () async {
      const targetRate = 1000;
      const durationMs = 1000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      final line = '100.0,200.0,300.0,400.0\n';
      final bytes = Uint8List.fromList(line.codeUnits);

      // 模拟1KHz数据流：严格1ms发送一包
      final stopwatch = Stopwatch()..start();
      int sent = 0;
      while (stopwatch.elapsedMilliseconds < durationMs) {
        final elapsed = stopwatch.elapsedMilliseconds;
        final targetSent = elapsed; // 1KHz = 1包/ms
        while (sent < targetSent) {
          parser.feed(bytes);
          sent++;
        }
        await Future.delayed(const Duration(milliseconds: 1));
      }
      stopwatch.stop();

      await Future.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      final actualDurationSec = stopwatch.elapsedMilliseconds / 1000.0;
      final actualRate = sent / actualDurationSec;
      final achievement = results.length / sent * 100; // 达成率 = 解析数/发送数
      // 使用 actualRate 和 achievement 避免 unused_local_variable 警告
      expect(actualRate >= 0, true);
      expect(achievement >= 0, true);

      // print('发送: $sent 包, 解析: ${results.length} 包, 发送速率: ${actualRate.toStringAsFixed(0)}/s, 达成率: ${achievement.toStringAsFixed(1)}%');

      expect(
        results.length,
        greaterThanOrEqualTo(minExpected),
        reason:
            '1KHz数据流解析应达到90%速率(≥$minExpected包)，'
            '实际${results.length}包(发送$sent包, 达成率${achievement.toStringAsFixed(1)}%)',
      );
    });

    test('解析器每秒稳定性', () async {
      const minAchievement = 0.9;

      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      final line = '100.0,200.0,300.0,400.0\n';
      final bytes = Uint8List.fromList(line.codeUnits);

      final counts = <int>[];
      final sentCounts = <int>[];
      int totalSent = 0;
      for (int sec = 0; sec < 3; sec++) {
        final startCount = results.length;
        final startSent = totalSent;
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 1000) {
          final elapsed = stopwatch.elapsedMilliseconds;
          final targetSent = sec * 1000 + elapsed;
          while (totalSent < targetSent) {
            parser.feed(bytes);
            totalSent++;
          }
          await Future.delayed(const Duration(milliseconds: 1));
        }
        await Future.delayed(const Duration(milliseconds: 20));
        counts.add(results.length - startCount);
        sentCounts.add(totalSent - startSent);
      }

      await subscription.cancel();

      for (int i = 0; i < counts.length; i++) {
        final achievement = counts[i] / sentCounts[i] * 100;
        // 使用 achievement 避免 unused_local_variable 警告
        expect(achievement >= 0, true);
        // print('第${i + 1}秒: 发送${sentCounts[i]}包, 解析${counts[i]}包(达成率${achievement.toStringAsFixed(1)}%)');
      }

      for (int i = 0; i < counts.length; i++) {
        expect(
          counts[i],
          greaterThanOrEqualTo((sentCounts[i] * minAchievement).round()),
          reason: '第${i + 1}秒解析达成率应≥90%(发送${sentCounts[i]}包, 解析${counts[i]}包)',
        );
      }
    });

    test('解析器不丢数据 - 连续发送1000包', () async {
      final parser = FireWaterParser();
      final results = <dynamic>[];
      final subscription = parser.outputStream.listen((r) => results.add(r));

      final line = '1.0,2.0,3.0,4.0\n';
      final bytes = Uint8List.fromList(line.codeUnits);

      // 连续发送1000包
      for (int i = 0; i < 1000; i++) {
        parser.feed(bytes);
      }

      await Future.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      expect(
        results.length,
        1000,
        reason: '发送1000包应解析出1000包，实际${results.length}包',
      );
    });
  });
}
