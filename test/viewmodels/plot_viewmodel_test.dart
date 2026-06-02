import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

Future<void> _writeLegacyDat(File file) async {
  const channelCount = 4;
  const storedPointCount = 50010;
  final bytes = Uint8List(4 + channelCount * (32 + storedPointCount * 2));
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, bytes.length, Endian.little);
  data.setUint32(0x20, storedPointCount, Endian.little);
  const addresses = [0x91, 0x94, 0x73, 0x93];
  const values = [
    [1, -2],
    [3, -4],
    [5, -6],
    [7, -8],
  ];

  for (int channel = 0; channel < channelCount; channel++) {
    final channelNumber = channel + 1;
    final blockOffset = channel * storedPointCount * 2;
    final dataOffset = 0x04 + channelNumber * 32 + blockOffset + 50000 * 2;
    final addressOffset = dataOffset - 50000 * 2 - 12;
    data.setUint32(addressOffset, addresses[channel], Endian.little);
    for (int i = 0; i < values[channel].length; i++) {
      data.setInt16(dataOffset + i * 2, values[channel][i], Endian.little);
    }
  }
  await file.writeAsBytes(bytes);
}

void main() {
  group('PlotViewModel', () {
    late SerialService serialService;
    late PlotViewModel vm;

    setUp(() async {
      await AppLogger().init();
      final settings = AppSettings();
      settings.parserType = 'fireWater';
      settings.useRandomSource = false;
      settings.sendProtocolType = 'none';
      settings.rChannelAddresses = List.filled(16, '');
      settings.rProfileId = '';
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

    test('updateFollowCursor 没有数据时保留指针 X', () {
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 100));
      vm.updateFollowCursor(30.4, 100.0, const Offset(50, 50));

      expect(vm.cursor, isNotNull);
      expect(vm.cursor!.x, 30.4);
      expect(vm.cursor!.hasData, false);
    });

    test('updateFollowCursor 吸附到当前显示窗口内的最近点', () {
      for (int i = 0; i < 100; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 20, xMax: 40));

      vm.updateFollowCursor(10, 100.0, const Offset(50, 50));

      expect(vm.cursor!.x, 20.0);
      expect(vm.cursor!.hasData, true);
      expect(vm.cursor!.channelValues, [20.0]);
    });

    test('添加观察时使用当前显示窗口内的最近点', () {
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
      expect(vm.observations.first.x, 40);
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

    test('CSV 导入会报告读取解析和索引进度', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_csv_progress_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1\n0,11\n1,22\n');
      final stages = <String>[];

      final error = await vm.importFromCsv(
        csv.path,
        onProgress: (progress) => stages.add(progress.stage),
      );

      expect(error, isNull);
      expect(stages, contains('读取 CSV'));
      expect(stages, contains('建立绘图索引'));
      expect(stages, contains('加载可见窗口'));
    });

    test('旧版 DAT 导入跳过预留区并保留通道地址', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_dat_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dat = File('${dir.path}/legacy.dat');
      await _writeLegacyDat(dat);
      final stages = <String>[];

      final error = await vm.importFromLegacyDat(
        dat.path,
        onProgress: (progress) => stages.add(progress.stage),
      );

      expect(error, isNull);
      expect(vm.dataPoints.length, 10);
      expect(vm.dataPoints[0].values, [1, 3, 5, 7]);
      expect(vm.dataPoints[1].values, [-2, -4, -6, -8]);
      expect(vm.channels[0].alias, isEmpty);
      expect(vm.importedChannelAddresses, [
        0x00000091,
        0x00000094,
        0x00000073,
        0x00000093,
      ]);
      expect(vm.parserConfig.zobowChannelIds[0], 0x00000091);
      expect(vm.parserConfig.zobowChannelIds[2], 0x00000073);
      expect(stages, contains('读取 DAT'));
      expect(stages, contains('解析 DAT'));
      expect(stages, contains('建立绘图索引'));

      final binPath = '${dir.path}/legacy.bin';
      expect(await vm.exportToBin(binPath), binPath);
      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(binPath), isNull);
      expect(imported.channels[0].alias, isEmpty);
      expect(imported.importedChannelAddresses, vm.importedChannelAddresses);
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
      expect(measurement, contains('1234.5'));
      expect(measurement, contains('2345.5'));
      expect(measurement, isNot(matches(RegExp(r'\d+(\.\d+)?[kKM]'))));

      vm.toggleStats();
      final stats = vm.statsText!;
      expect(stats, contains('2345.5'));
      expect(stats, contains('1234.5'));
      expect(stats, isNot(matches(RegExp(r'\d+(\.\d+)?[kKM]'))));
    });

    test('开始绘图保留已开启的光标工具', () async {
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.setVCursorEnabled(true);
      vm.toggleXMeasurement();
      vm.toggleYMeasurement();
      vm.toggleStats();
      vm.toggleStatsRange();

      await vm.startPlotting();

      expect(vm.vCursorEnabled, isTrue);
      expect(vm.xMeasurementEnabled, isTrue);
      expect(vm.yMeasurementEnabled, isTrue);
      expect(vm.statsEnabled, isTrue);
      expect(vm.statsRangeEnabled, isTrue);
      expect(vm.measurementText, isNotNull);
      expect(vm.statsX1, isNotNull);
      expect(vm.statsX2, isNotNull);

      await vm.stopPlotting();
    });

    test('Y轴全零时跳过自适应', () {
      for (int i = 0; i < 4; i++) {
        vm.ingestParsedResultForTest(ParseResult.ok([0], bytesConsumed: 1));
      }
      final oldViewport = vm.viewport;

      vm.fitYAxis();

      expect(vm.viewport.yMin, oldViewport.yMin);
      expect(vm.viewport.yMax, oldViewport.yMax);
      expect(vm.lastStatusMessage, contains('Y轴数据范围为0'));
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

    test('JustFloat手动通道数写入持久化设置', () {
      final settings = AppSettings();
      settings.justFloatChannelCount = 0;

      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 6);

      expect(vm.parserConfig.channelCount, 6);
      expect(settings.justFloatChannelCount, 6);
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
      expect(vm.lastStatusMessage, contains('X轴数据点过少'));
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
      expect(vm.lastStatusMessage, contains('随机源已保留'));

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

    test('接收协议内置顺序固定', () {
      expect(ParserType.values, [
        ParserType.fireWater,
        ParserType.justFloat,
        ParserType.fixedFrame,
        ParserType.zobow,
      ]);
    });

    test('r协议命令保留十进制和0x输入形式并以LF结尾', () {
      final bytes = PlotViewModel.buildRProtocolCommand([
        ' 12 ',
        '0x10',
        '0X2A',
      ]);

      expect(utf8.decode(bytes), 'r 12 0x10 0X2A\n');
    });

    test('r协议地址校验支持自动连续前缀和固定通道截断', () {
      expect(
        PlotViewModel.validateRProtocolAddresses(['1', '0x10', '20', '']),
        ['1', '0x10', '20'],
      );
      expect(
        PlotViewModel.validateRProtocolAddresses([
          '1',
          '0x10',
          '20',
        ], requiredCount: 2),
        ['1', '0x10'],
      );
    });

    test('r协议地址校验拒绝空地址、固定通道不足和中间空洞', () {
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['', '0']),
        throwsFormatException,
      );
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['1'], requiredCount: 2),
        throwsFormatException,
      );
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['1', '', '2']),
        throwsFormatException,
      );
    });

    test('自动识别接收协议未开始绘图时为r协议显示16个地址槽位', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault());
      expect(vm.rAddressDisplayCount, SendProtocolConfig.maxChannelCount);

      vm.setParserType(ParserType.fireWater);
      vm.updateParserConfig(ParserConfig.fireWaterDefault());
      expect(vm.rAddressDisplayCount, SendProtocolConfig.maxChannelCount);
    });

    test('众邦模式强制内置发送协议并在离开后恢复选择', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      expect(vm.effectiveSendProtocolType, SendProtocolType.rProtocol);

      vm.setParserType(ParserType.zobow);
      expect(vm.effectiveSendProtocolType, SendProtocolType.zobowBuiltIn);
      expect(vm.sendProtocolType, SendProtocolType.rProtocol);

      vm.setParserType(ParserType.fireWater);
      expect(vm.effectiveSendProtocolType, SendProtocolType.rProtocol);
    });

    test('随机源无串口时自动将r协议切回无并继续绘图', () async {
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.setSendProtocolType(SendProtocolType.rProtocol);

      await vm.startPlotting();

      expect(vm.sendProtocolType, SendProtocolType.none);
      expect(vm.isPlotting, isTrue);
      await vm.stopPlotting();
    });

    test('开始绘图前检测陈旧串口状态并断开连接', () async {
      vm.setUseRandomSource(false);
      serialService.isConnected = true;
      vm.setParserType(ParserType.zobow);

      await vm.startPlotting();

      expect(vm.isPlotting, false);
      expect(serialService.isConnected, false);
      expect(vm.lastStatusMessage, contains('检测到串口已断开'));
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
