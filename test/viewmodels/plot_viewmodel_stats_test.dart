import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

void _ingestSequentialPoints(PlotViewModel vm, int count) {
  for (int i = 0; i < count; i++) {
    vm.ingestParsedResultForTest(
      ParseResult.ok([i.toDouble()], bytesConsumed: 4),
    );
  }
}

/// 统计逻辑使用确定性数据注入，避免随机源 Isolate 调度导致单测波动。
void main() {
  group('PlotViewModel 统计信息测试', () {
    late PlotViewModel vm;

    setUp(() async {
      await AppLogger().init();
      vm = PlotViewModel(SerialService());
    });

    tearDown(() {
      vm.dispose();
      AppLogger().disposeLogger();
    });

    test('默认统计当前显示窗口范围', () {
      _ingestSequentialPoints(vm, 10);
      vm.updateViewport(vm.viewport.copyWith(xMin: 2, xMax: 5));

      vm.toggleStats();

      final stats = vm.statsText;
      expect(stats, isNotNull);
      expect(stats, contains('Max: 5'));
      expect(stats, contains('Min: 2'));
      expect(stats, contains('Avg: 3.5'));
      expect(stats, contains('N: 4'));
      expect(stats, contains('Range: 2 ~ 5'));
    });

    test('启用统计范围后使用S1/S2范围', () {
      _ingestSequentialPoints(vm, 10);
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 9));

      vm.toggleStats();
      vm.toggleStatsRange();
      vm.setStatsX1(3);
      vm.setStatsX2(4);

      final stats = vm.statsText;
      expect(stats, isNotNull);
      expect(stats, contains('Max: 4'));
      expect(stats, contains('Min: 3'));
      expect(stats, contains('Avg: 3.5'));
      expect(stats, contains('N: 2'));
      expect(stats, contains('Range: 3 ~ 4'));
    });
  });
}
