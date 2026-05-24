import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
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

    test('Y轴全零时跳过自适应', () {
      for (int i = 0; i < 4; i++) {
        vm.ingestParsedResultForTest(ParseResult.ok([0], bytesConsumed: 1));
      }
      final oldViewport = vm.viewport;

      vm.fitYAxis();

      expect(vm.viewport.yMin, oldViewport.yMin);
      expect(vm.viewport.yMax, oldViewport.yMax);
      expect(vm.hintText, contains('Y轴数据范围为0'));
    });

    test('X轴点数小于等于3时跳过自适应', () {
      for (int i = 0; i < 3; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      final oldViewport = vm.viewport;

      vm.fitXAxis();

      expect(vm.viewport.xMin, oldViewport.xMin);
      expect(vm.viewport.xMax, oldViewport.xMax);
      expect(vm.hintText, contains('X轴数据点过少'));
    });

    test('状态文本包含关键信息', () {
      final status = vm.statusText;
      expect(status.contains('X:'), true);
      expect(status.contains('Y:'), true);
      expect(status.contains('点数:'), true);
    });

    test('非FireWater解析器保留随机源开关但不能单独启动', () {
      vm.setUseRandomSource(true);
      vm.setParserType(ParserType.zobow);

      expect(vm.useRandomSource, true);
      expect(vm.hintText, contains('随机源已保留'));

      vm.startPlotting();

      expect(vm.isPlotting, false);
      expect(vm.hintText, contains('随机源仅支持 FireWater'));
    });

    test('众邦初始化帧使用4字节小端通道号', () {
      final frame = PlotViewModel.buildZobowInitFrame([
        0x01020304,
        0x11223344,
        0xAABBCCDD,
        0x00000005,
      ]);

      expect(frame.length, 18);
      expect(frame.sublist(0, 16), [
        0x04,
        0x03,
        0x02,
        0x01,
        0x44,
        0x33,
        0x22,
        0x11,
        0xDD,
        0xCC,
        0xBB,
        0xAA,
        0x05,
        0x00,
        0x00,
        0x00,
      ]);

      final crc = calculateCrc(
        frame.sublist(0, 16),
        crc16Polys['CRC-16/MODBUS']!,
      );
      expect(frame[16], crc & 0xFF);
      expect(frame[17], (crc >> 8) & 0xFF);
    });

    test('众邦初始化帧支持8通道', () {
      final frame = PlotViewModel.buildZobowInitFrame([1, 2, 3, 4, 5, 6, 7, 8]);

      expect(frame.length, 34);
      expect(frame.sublist(0, 32), [
        1,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        3,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        5,
        0,
        0,
        0,
        6,
        0,
        0,
        0,
        7,
        0,
        0,
        0,
        8,
        0,
        0,
        0,
      ]);

      final crc = calculateCrc(
        frame.sublist(0, 32),
        crc16Polys['CRC-16/MODBUS']!,
      );
      expect(frame[32], crc & 0xFF);
      expect(frame[33], (crc >> 8) & 0xFF);
    });

    test('众邦初始化发送失败时不进入绘图并断开连接', () {
      serialService.isConnected = true;
      vm.setParserType(ParserType.zobow);

      vm.startPlotting();

      expect(vm.isPlotting, false);
      expect(serialService.isConnected, false);
      expect(vm.hintText, contains('协议初始化发送失败'));
    });

    test('stopPlotting先更新UI状态并阻止重复停止', () async {
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.startPlotting();
      expect(vm.isPlotting, true);

      final stopFuture = vm.stopPlotting();

      expect(vm.isPlotting, false);
      expect(vm.isStopping, true);
      expect(vm.hintText, contains('正在停止绘图'));

      expect(identical(vm.stopPlotting(), stopFuture), true);

      await stopFuture;
      expect(vm.isStopping, false);
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
