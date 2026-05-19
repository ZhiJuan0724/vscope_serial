import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

/// 测试 PlotViewModel 统计信息准确性
void main() {
  group('PlotViewModel 统计信息测试', () {
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

    test('1KHz运行时状态文本统计准确', () async {
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);
      vm.clearData();
      vm.startPlotting();

      // 运行2秒让数据稳定
      await Future.delayed(const Duration(seconds: 2));

      final status = vm.statusText;
      // print('状态文本: $status');

      // 检查状态文本包含每秒点数
      expect(status.contains('/s)'), true,
          reason: '状态文本应包含每秒点数，实际: $status');

      // 提取每秒点数
      final match = RegExp(r'\((\d+(?:\.\d+)?)/s\)').firstMatch(status);
      expect(match, isNotNull,
          reason: '状态文本应匹配 /s 格式，实际: $status');

      final reportedRate = double.parse(match!.group(1)!);
      // print('报告速率: $reportedRate /s');

      // 报告速率应接近实际速率（允许±20%误差）
      expect(reportedRate, greaterThan(800),
          reason: '1KHz下报告速率应>800/s，实际$reportedRate/s');

      vm.stopPlotting();
    });

    test('统计速率与实际接收速率一致', () async {
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);
      vm.clearData();
      vm.startPlotting();

      // 运行3秒
      await Future.delayed(const Duration(seconds: 3));

      final actualCount = vm.pointCount;
      final actualRate = actualCount / 3.0;

      final status = vm.statusText;
      final match = RegExp(r'\((\d+(?:\.\d+)?)/s\)').firstMatch(status);
      final reportedRate = match != null ? double.parse(match.group(1)!) : 0.0;

      // print('实际总点数: $actualCount, 实际平均速率: ${actualRate.toStringAsFixed(1)}/s');
      // print('报告速率: $reportedRate/s');

      // 报告速率应接近实际平均速率（±30%）
      final ratio = reportedRate / actualRate;
      expect(ratio, greaterThan(0.7),
          reason: '报告速率应≥实际速率的70%，实际比例${(ratio * 100).toStringAsFixed(1)}%');
      expect(ratio, lessThan(1.3),
          reason: '报告速率应≤实际速率的130%，实际比例${(ratio * 100).toStringAsFixed(1)}%');

      vm.stopPlotting();
    });

    test('高频下统计不丢数据', () async {
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1000);
      vm.clearData();
      vm.startPlotting();

      // 运行5秒
      await Future.delayed(const Duration(seconds: 5));

      final pointCount = vm.pointCount;
      final expectedMin = 1000 * 5 * 0.9; // 90%

      // print('5秒接收: $pointCount 包');

      expect(pointCount, greaterThanOrEqualTo(expectedMin.round()),
          reason: '5秒应接收≥${expectedMin.round()}包，实际$pointCount包');

      vm.stopPlotting();
    });
  });
}
