import 'dart:io';

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

    test('添加观察时旧光标在视口外则放到当前视口内', () {
      for (int i = 0; i < 100; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 20, xMax: 40));
      vm.updateFollowCursor(1000, 0, const Offset(50, 50));

      vm.addObservation();

      expect(vm.observations, hasLength(1));
      expect(vm.observations.first.x, inInclusiveRange(20, 40));
      expect(vm.observations.first.x, 30);
    });

    test('clearData清空数据', () {
      // 先添加一些数据
      vm.startPlotting();
      // 无法直接添加数据，测试清空逻辑
      vm.clearData();

      expect(vm.dataPoints.isEmpty, true);
      expect(vm.pointCount, 0);
    });

    test('BIN 导入导出保留通道数据', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_bin_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1.5,2.5\n1,3.5,4.5\n');
      final csvError = await vm.importFromCsv(csv.path);
      expect(csvError, isNull);

      final binPath = '${dir.path}/plot.bin';
      final exported = await vm.exportToBin(binPath);
      expect(exported, binPath);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      final binError = await imported.importFromBin(binPath);
      expect(binError, isNull);
      expect(imported.dataPoints.length, 2);
      expect(imported.dataPoints[0].values, [1.5, 2.5]);
      expect(imported.dataPoints[1].values, [3.5, 4.5]);
    });

    test('导入导出保留通道名称和众邦地址', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_meta_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1,2\n1,3,4\n');
      expect(await vm.importFromCsv(csv.path), isNull);
      vm.setParserType(ParserType.zobow);
      vm.setChannelAlias(0, '主轴角度');
      vm.setChannelAlias(1, '速度');
      vm.setZobowChannelId(0, 0x00000095);
      vm.setZobowChannelId(1, 0x12345678);

      final binPath = '${dir.path}/plot.bin';
      expect(await vm.exportToBin(binPath), binPath);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(binPath), isNull);

      expect(imported.parserType, ParserType.zobow);
      expect(imported.channels[0].alias, '主轴角度');
      expect(imported.channels[1].alias, '速度');
      expect(imported.parserConfig.zobowChannelIds[0], 0x00000095);
      expect(imported.parserConfig.zobowChannelIds[1], 0x12345678);
    });

    test('CSV 导入在众邦模式下也会重建绘图窗口', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_csv_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      vm.setParserType(ParserType.zobow);
      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,11,22\n1,33,44\n');

      final error = await vm.importFromCsv(csv.path);

      expect(error, isNull);
      expect(vm.dataPoints.length, 2);
      expect(vm.dataPoints[0].values, [11.0, 22.0]);
      expect(vm.dataPoints[1].values, [33.0, 44.0]);
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

    test('测量和统计文本完整显示大数值', () {
      vm.setParserType(ParserType.fireWater);
      vm.ingestParsedResultForTest(ParseResult.ok([1234.5], bytesConsumed: 4));
      vm.ingestParsedResultForTest(ParseResult.ok([2345.5], bytesConsumed: 4));

      vm.toggleYMeasurement();
      vm.setYCursor1(1234.5);
      vm.setYCursor2(2345.5);
      final measurement = vm.measurementText!;
      expect(measurement, contains('1235'));
      expect(measurement, contains('2346'));
      expect(measurement, isNot(matches(RegExp(r'\d+(\.\d+)?[kKM]'))));

      vm.toggleStats();
      final stats = vm.statsText!;
      expect(stats, contains('2346'));
      expect(stats, contains('1235'));
      expect(stats, isNot(matches(RegExp(r'\d+(\.\d+)?[kKM]'))));
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

    test('JustFloat偏置通道参与Y轴自适应缩放', () {
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      vm.setChannelOffsetEnabled(0, true);

      for (final value in [1.0, 2.0, 5.0]) {
        vm.ingestParsedResultForTest(ParseResult.ok([value], bytesConsumed: 4));
      }

      vm.fitYAxis();

      expect(vm.channels[0].yScale, isNot(1.0));
      expect(vm.channels[0].yOffset, isNot(0.0));

      final fittedValues =
          [1.0, 5.0]
              .map(
                (value) =>
                    value * vm.channels[0].yScale + vm.channels[0].yOffset,
              )
              .toList();
      expect(fittedValues[0], greaterThan(vm.viewport.yMin));
      expect(fittedValues[1], lessThan(vm.viewport.yMax));
    });

    test('导入常量偏置通道时全自适应会将通道居中', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_const_bin_test_',
      );
      addTearDown(() => dir.delete(recursive: true));

      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      for (int i = 0; i < 4; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([
            10.0,
            1.0,
            3125.0,
            3125.0,
            3125.0,
            3125.0,
            4.0,
          ], bytesConsumed: 32),
        );
      }

      final binPath = '${dir.path}/constant.bin';
      expect(await vm.exportToBin(binPath), binPath);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(binPath), isNull);
      for (int i = 0; i < 7; i++) {
        imported.setChannelOffsetEnabled(i, true);
      }

      imported.fitAll();

      final center = (imported.viewport.yMin + imported.viewport.yMax) / 2;
      final values = imported.dataPoints.first.values;
      for (int i = 0; i < 7; i++) {
        final displayValue =
            values[i] * imported.channels[i].yScale +
            imported.channels[i].yOffset;
        expect(displayValue, closeTo(center, 1e-9));
      }
    });

    test('JustFloat重新识别更少通道时非活动偏置通道不参与自适应', () {
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      vm.setChannelOffsetEnabled(2, true);

      vm.ingestParsedResultForTest(
        ParseResult.ok([1.0, 2.0, 3.0], bytesConsumed: 12),
      );
      expect(vm.activeChannelCount, 3);

      vm.ingestParsedResultForTest(
        ParseResult.ok([10.0, 20.0], bytesConsumed: 8),
      );

      vm.fitYAxis();

      expect(vm.activeChannelCount, 2);
      expect(vm.channels[2].offsetEnabled, isTrue);
      expect(vm.channels[2].yScale, 1.0);
      expect(vm.channels[2].yOffset, 0.0);
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
