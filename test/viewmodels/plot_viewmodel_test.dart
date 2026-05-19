import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

void main() {
  group('PlotViewModel', () {
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

    test('初始状态', () {
      expect(vm.isPlotting, false);
      expect(vm.dataPoints.isEmpty, true);
      expect(vm.pointCount, 0);
      expect(vm.activeChannelCount, 0);
      expect(vm.useRandomSource, false);
      expect(vm.followEnabled, false);
      expect(vm.vCursorEnabled, false);
      expect(vm.vCursorEnabled, false);
      expect(vm.cursor, null);
    });

    test('视口默认范围', () {
      expect(vm.viewport.xMin, 0.0);
      expect(vm.viewport.xMax, 1000.0);
      expect(vm.viewport.yMin, 0.0);
      expect(vm.viewport.yMax, 32768.0);
    });

    test('updateViewport创建新实例', () {
      final oldViewport = vm.viewport;
      final newViewport = vm.viewport.copyWith(xMin: 100, xMax: 500);

      vm.updateViewport(newViewport);

      // viewport 应该是新实例
      expect(vm.viewport, isNot(oldViewport));
      expect(vm.viewport.xMin, 100.0);
      expect(vm.viewport.xMax, 500.0);
    });

    test('updateFollowCursor X吸附到整数', () {
      vm.updateFollowCursor(30.4, 100.0, const Offset(50, 50));

      expect(vm.cursor, isNotNull);
      expect(vm.cursor!.x, 30.0); // 30.4 吸附到 30
      expect(vm.cursor!.x, 30.0); // 30.4 吸附到 30
    });

    test('updateFollowCursor 小数部分>=0.5向上取整', () {
      vm.updateFollowCursor(30.6, 100.0, const Offset(50, 50));

      expect(vm.cursor!.x, 31.0); // 30.6 吸附到 31
    });

    test('clearData清空数据', () {
      // 先添加一些数据
      vm.startPlotting();
      // 无法直接添加数据，测试清空逻辑
      vm.clearData();

      expect(vm.dataPoints.isEmpty, true);
      expect(vm.pointCount, 0);
    });

    test('setVCursorEnabled切换状态', () {
      expect(vm.vCursorEnabled, false);

      vm.setVCursorEnabled(true);
      expect(vm.vCursorEnabled, true);

      vm.setVCursorEnabled(false);
      expect(vm.vCursorEnabled, false);
    });

    test('setFollowEnabled切换状态', () {
      expect(vm.followEnabled, false);

      vm.setFollowEnabled(true);
      expect(vm.followEnabled, true);
    });

    test('zoomXIn缩小X范围', () {
      final oldRange = vm.viewport.xRange;
      vm.zoomXIn();
      expect(vm.viewport.xRange, lessThan(oldRange));
    });

    test('zoomXOut放大X范围', () {
      final oldRange = vm.viewport.xRange;
      vm.zoomXOut();
      expect(vm.viewport.xRange, greaterThan(oldRange));
    });

    test('resetViewport恢复默认', () {
      vm.updateViewport(vm.viewport.copyWith(xMin: 100, xMax: 500));
      expect(vm.viewport.xMin, 100.0);

      vm.resetViewport();
      expect(vm.viewport.xMin, 0.0);
      expect(vm.viewport.xMax, 1000.0);
    });

    test('状态文本包含关键信息', () {
      final status = vm.statusText;
      expect(status.contains('X:'), true);
      expect(status.contains('Y:'), true);
      expect(status.contains('点数:'), true);
    });

    test('canUndoZoom初始为false', () {
      expect(vm.canUndoZoom, false);
    });

    test('undoZoom恢复上一个视口', () {
      final originalXMin = vm.viewport.xMin;
      vm.zoomXIn();
      expect(vm.viewport.xMin, isNot(originalXMin));
      expect(vm.canUndoZoom, true);

      vm.undoZoom();
      expect(vm.viewport.xMin, originalXMin);
    });
  });
}
