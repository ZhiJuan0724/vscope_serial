import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

/// 测试 PlotViewModel 在高频数据下的接收速率
void main() {
  group('PlotViewModel 高频接收测试', () {
    late SerialService serialService;
    late PlotViewModel vm;

    setUp(() async {
      await AppLogger().init();
      serialService = SerialService();
      vm = PlotViewModel(serialService);
    });

    tearDown(() {
      vm.dispose();
      AppLogger().disposeLogger();
    });

    test('1KHz随机源接收应达到90%速率', () async {
      const targetRate = 1000;
      const durationMs = 1000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      // 启用随机源，1KHz
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);

      // 清空数据
      vm.clearData();

      // 开始绘图
      vm.startPlotting();
      expect(vm.isPlotting, true);

      // 等待1秒
      await Future.delayed(const Duration(milliseconds: durationMs));

      final pointCount = vm.pointCount;
      final actualRate = pointCount * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      vm.stopPlotting();

      print('ViewModel接收: $pointCount 包(达成率${achievement.toStringAsFixed(1)}%)');

      expect(pointCount, greaterThanOrEqualTo(minExpected),
          reason: 'ViewModel 1KHz接收应达到90%速率(≥$minExpected包)，'
                  '实际$pointCount包(达成率${achievement.toStringAsFixed(1)}%)');
    });

    test('1KHz每秒稳定性', () async {
      const targetRate = 1000;
      const minAchievement = 0.9;

      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);
      vm.clearData();
      vm.startPlotting();

      final counts = <int>[];
      for (int i = 0; i < 3; i++) {
        final startCount = vm.pointCount;
        await Future.delayed(const Duration(seconds: 1));
        counts.add(vm.pointCount - startCount);
      }

      vm.stopPlotting();

      for (int i = 0; i < counts.length; i++) {
        final achievement = counts[i] / targetRate * 100;
        print('第${i + 1}秒: ${counts[i]} 包(达成率${achievement.toStringAsFixed(1)}%)');
      }

      for (int i = 0; i < counts.length; i++) {
        expect(counts[i], greaterThanOrEqualTo((targetRate * minAchievement).round()),
            reason: '第${i + 1}秒ViewModel接收达成率应≥90%(≥${(targetRate * minAchievement).round()}包)，'
                    '实际${counts[i]}包');
      }
    });

    test('10秒稳定性', () async {
      const targetRate = 1000;
      const durationMs = 10000;
      final minExpected = (targetRate * durationMs / 1000 * 0.9).round();

      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);
      vm.clearData();
      vm.startPlotting();

      await Future.delayed(const Duration(milliseconds: durationMs));

      final pointCount = vm.pointCount;
      final actualRate = pointCount * 1000 / durationMs;
      final achievement = actualRate / targetRate * 100;

      vm.stopPlotting();

      print('10秒接收: $pointCount 包(达成率${achievement.toStringAsFixed(1)}%)');

      expect(pointCount, greaterThanOrEqualTo(minExpected),
          reason: 'ViewModel 1KHz运行10秒应达到90%速率(≥$minExpected包)，'
                  '实际$pointCount包(达成率${achievement.toStringAsFixed(1)}%)');
    }, timeout: Timeout(Duration(minutes: 2)));
  });
}
