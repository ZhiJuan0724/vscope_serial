import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/math_channel_config.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';

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
      settings.triggerToolbarEnabled = false;
      settings.mathChannels = MathChannelConfig.createDefaults();
      settings.keepPlotOnRestart = false;
      settings.plotLegendPanelRight = null;
      settings.plotLegendPanelTop = null;
      settings.plotLiveValuesPanelRight = null;
      settings.plotLiveValuesPanelTop = null;
      settings.sendProtocolType = 'none';
      settings.rChannelAddresses = List.filled(16, '');
      settings.rProtocolLooseChannelSettings = false;
      settings.discardInitialPacketCount = 0;
      settings.zobowChannelIds = List.generate(
        ParserConfig.maxZobowChannelCount,
        (i) => i + 1,
      );
      settings.zobowChannelTypes = List.filled(
        ParserConfig.maxZobowChannelCount,
        DataType.int16,
      );
      settings.channelPresetBindings = [];
      settings.fixedFrameChannelTypes = List.filled(
        SendProtocolConfig.maxChannelCount,
        DataType.uint16,
      );
      settings.rProfileId = '';
      settings.xMin = 0;
      settings.xMax = 1000;
      settings.yMin = 0;
      settings.yMax = 32768;
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

    test('预览导航限制在完整数据范围内并退出跟随', () {
      for (var i = 0; i < 2000; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 200, xMax: 400));
      vm.setFollowEnabled(true);

      vm.movePreviewViewportTo(0);

      expect(vm.viewport.xMin, 0);
      expect(vm.viewport.xMax, 200);
      expect(vm.followEnabled, isFalse);
    });

    test('解析历史按实际通道数分配存储空间', () {
      for (var i = 0; i < 5000; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([1, 2, 3, 4], bytesConsumed: 16),
        );
      }

      expect(vm.parsedHistoryAllocatedValueSlotsForTest, 2 * 4096 * 4);
    });

    test('配置选择会递增配置修订号以刷新工具栏', () {
      final before = vm.profileRevision;

      vm.selectZobowProfile(null);

      expect(vm.profileRevision, before + 1);
    });

    test('背景切换会映射预设通道颜色但保留自定义颜色', () {
      const customColor = Color(0xFF123456);
      vm.setChannelColor(0, ChannelConfig.darkPresetColors.first);
      vm.setChannelColor(1, customColor);

      vm.setPlotBackground('light');

      expect(vm.plotBackground, 'light');
      expect(vm.channels[0].color, ChannelConfig.lightPresetColors.first);
      expect(vm.channels[1].color, customColor);

      vm.setPlotBackground('dark');

      expect(vm.channels[0].color, ChannelConfig.darkPresetColors.first);
      expect(vm.channels[1].color, customColor);
    });

    test('悬浮窗透明度限制在有效范围内', () {
      vm.setFloatingPanelOpacity(0.75);
      expect(vm.floatingPanelOpacity, 0.75);

      vm.setFloatingPanelOpacity(0.1);
      expect(vm.floatingPanelOpacity, 0.1);

      vm.setFloatingPanelOpacity(-1);
      expect(vm.floatingPanelOpacity, 0);

      vm.setFloatingPanelOpacity(2);
      expect(vm.floatingPanelOpacity, 1);
    });

    test('图例和实时值浮窗位置可保存到设置', () {
      expect(vm.legendPanelRight, 16);
      expect(vm.legendPanelTop, 96);
      expect(vm.liveValuesPanelRight, 16);
      expect(vm.liveValuesPanelTop(legendVisible: false), 96);
      expect(vm.liveValuesPanelTop(legendVisible: true), 240);

      vm.setLegendPanelPosition(right: 42.34, top: 88.86);
      vm.setLiveValuesPanelPosition(right: 123.45, top: 234.56);

      expect(vm.legendPanelRight, 42.3);
      expect(vm.legendPanelTop, 88.9);
      expect(vm.liveValuesPanelRight, 123.5);
      expect(vm.liveValuesPanelTop(legendVisible: false), 234.6);
      expect(vm.liveValuesPanelTop(legendVisible: true), 234.6);
      expect(AppSettings().plotLegendPanelRight, 42.3);
      expect(AppSettings().plotLegendPanelTop, 88.9);
      expect(AppSettings().plotLiveValuesPanelRight, 123.5);
      expect(AppSettings().plotLiveValuesPanelTop, 234.6);

      vm.setLegendPanelPosition(right: -1, top: 20);
      vm.setLiveValuesPanelPosition(right: double.infinity, top: 20);

      expect(vm.legendPanelRight, 42.3);
      expect(vm.liveValuesPanelRight, 123.5);
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

    testWidgets('拖动视口在同一帧内只通知一次', (tester) async {
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.updateViewport(
        vm.viewport.copyWith(xMin: 10, xMax: 110),
        fromDrag: true,
      );
      vm.updateViewport(
        vm.viewport.copyWith(xMin: 20, xMax: 120),
        fromDrag: true,
      );
      vm.updateViewport(
        vm.viewport.copyWith(xMin: 30, xMax: 130),
        fromDrag: true,
      );

      expect(vm.viewport.xMin, 30.0);
      expect(notifications, 0);
      await tester.pump();
      expect(notifications, 1);
    });

    test('jumpToXIndex 保持当前范围并移动视口中心', () {
      for (int i = 0; i < 1000; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 100, xMax: 500));

      vm.jumpToXIndex(900);

      expect(vm.viewport.xRange, 400.0);
      expect(vm.viewport.xMin, 700.0);
      expect(vm.viewport.xMax, 1100.0);
    });

    test('jumpToXIndex 拒绝无数据和越界索引', () {
      final oldViewport = vm.viewport.copy();

      vm.jumpToXIndex(0);

      expect(vm.viewport.xMin, oldViewport.xMin);
      expect(vm.viewport.xMax, oldViewport.xMax);
      expect(vm.minJumpXIndex, isNull);
      expect(vm.maxJumpXIndex, isNull);

      for (int i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }

      expect(vm.minJumpXIndex, 0);
      expect(vm.maxJumpXIndex, 9);
      expect(vm.canJumpToXIndex(-1), isFalse);
      expect(vm.canJumpToXIndex(10), isFalse);
      expect(vm.canJumpToXIndex(9), isTrue);

      vm.jumpToXIndex(-1);
      expect(vm.viewport.xMin, oldViewport.xMin);
      expect(vm.viewport.xMax, oldViewport.xMax);
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
      vm.setObservationClickToPlace(false);

      vm.addObservation();

      expect(vm.observationClickToPlace, isFalse);
      expect(vm.observations, hasLength(1));
      expect(vm.observations.first.x, inInclusiveRange(20, 40));
      expect(vm.observations.first.x, 40);
    });

    test('点击定位观察只在提交后新增观察', () {
      for (int i = 0; i < 100; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 20, xMax: 40));
      vm.setObservationClickToPlace(true);

      vm.startObservationPlacement();
      vm.updateObservationPlacement(31.6);

      expect(vm.observationPlacementActive, isTrue);
      expect(vm.observationPreview, isNotNull);
      expect(vm.observationPreview!.x, 32);
      expect(vm.observations, isEmpty);

      vm.commitObservationPlacement(34.7);

      expect(vm.observationPlacementActive, isFalse);
      expect(vm.observationPreview, isNull);
      expect(vm.observations.single.x, 35);
    });

    test('手动观察在当前窗口外时保留目标X且不伪造吸附数据', () {
      for (int i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 4));
      vm.setObservationClickToPlace(true);

      vm.startObservationPlacement();
      vm.commitObservationPlacement(8);

      expect(vm.observations.single.x, 8);
      expect(vm.observations.single.locked, isFalse);
      expect(vm.observations.single.hasData, isFalse);
      expect(vm.observations.single.channelValues, isNull);

      vm.updateObservation(0, 9);

      expect(vm.observations.single.x, 9);
      expect(vm.observations.single.hasData, isFalse);
    });

    test('观察锁定后不能拖动位置但仍可在管理逻辑中删除', () {
      for (int i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.addObservation();

      expect(vm.observations.single.locked, isFalse);
      vm.setObservationLocked(0, true);
      expect(vm.observations.single.locked, isTrue);

      final beforeX = vm.observations.single.x;
      vm.updateObservation(0, 5);
      expect(vm.observations.single.x, beforeX);

      vm.setObservationLocked(0, false);
      vm.updateObservation(0, 5);
      expect(vm.observations.single.x, 5);

      vm.setObservationLocked(0, true);
      vm.removeObservation(0);
      expect(vm.observations, isEmpty);
    });

    test('当前窗口外的观察可一键跳转到对应X位置', () {
      for (int i = 0; i < 100; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 20));
      vm.setObservationClickToPlace(true);
      vm.startObservationPlacement();
      vm.commitObservationPlacement(80);

      expect(vm.observations.single.x, 80);
      expect(vm.viewport.isVisibleX(vm.observations.single.x), isFalse);

      vm.jumpToObservation(0);

      expect(vm.observations.single.x, 80);
      expect(vm.viewport.isVisibleX(80), isTrue);
      expect(vm.viewport.xMin, 70);
      expect(vm.viewport.xMax, 90);
    });

    test('触发关闭时不检测条件', () {
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: false,
          channelIndex: 0,
          comparison: PlotTriggerComparison.greater,
          targetValue: 1,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.triggerPoint,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 1));

      expect(vm.triggeredCount, 0);
      expect(vm.observations, isEmpty);
    });

    test('触发条件支持大于小于和容差等于', () {
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          triggerLimit: 3,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );
      vm.ingestParsedResultForTest(ParseResult.ok([11], bytesConsumed: 1));
      expect(vm.triggeredCount, 1);

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.less,
          targetValue: 10,
          triggerLimit: 3,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );
      vm.ingestParsedResultForTest(ParseResult.ok([9], bytesConsumed: 1));
      expect(vm.triggeredCount, 1);

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.equal,
          targetValue: 10,
          triggerLimit: 3,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );
      vm.ingestParsedResultForTest(
        ParseResult.ok([
          10 + PlotTriggerConfig.equalTolerance / 2,
        ], bytesConsumed: 1),
      );
      expect(vm.triggeredCount, 1);
    });

    test('触发条件支持向上和向下越过阈值', () {
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.crossUp,
          targetValue: 10,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([9], bytesConsumed: 1));
      expect(vm.triggeredCount, 0);
      vm.ingestParsedResultForTest(ParseResult.ok([10], bytesConsumed: 1));
      expect(vm.triggeredCount, 1);

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.crossDown,
          targetValue: 10,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([11], bytesConsumed: 1));
      expect(vm.triggeredCount, 0);
      vm.ingestParsedResultForTest(ParseResult.ok([10], bytesConsumed: 1));
      expect(vm.triggeredCount, 1);
    });

    test('触发只对打开的普通通道生效且未配置不能左键开启', () {
      vm.setTriggerEnabled(true);
      expect(vm.triggerEnabled, isFalse);
      expect(vm.triggerToolbarEnabled, isFalse);

      vm.setChannelVisible(0, false);
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          channelIndex: 0,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      expect(vm.triggeredCount, 0);
    });

    test('触发通道候选按当前协议实际普通通道数过滤', () {
      vm.setParserType(ParserType.zobow);

      expect(vm.triggerCandidateChannels.map((channel) => channel.index), [
        0,
        1,
        2,
        3,
      ]);

      vm.updateParserConfig(
        vm.parserConfig.copyWith(
          type: ParserType.zobow,
          channelCount: ParserConfig.maxZobowChannelCount,
        ),
      );
      vm.setChannelVisible(2, false);

      expect(vm.triggerCandidateChannels.map((channel) => channel.index), [
        0,
        1,
        3,
        4,
        5,
        6,
        7,
      ]);

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          channelIndex: 15,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      expect(vm.triggerConfig.channelIndex, 0);
      expect(vm.triggerEnabled, isTrue);
    });

    test('无数据偏移的数学通道可按表达式原始值触发', () {
      final display = vm.mathChannels[0].display.copyWith(
        yOffset: 1000,
        yScale: 0.25,
      );
      expect(vm.configureMathChannel(0, 'CH0 + CH1', display), isTrue);
      expect(
        vm.triggerCandidateChannels.map((channel) => channel.index),
        contains(16),
      );

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          channelIndex: 16,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.triggerPoint,
          includeSystemTimeInNote: false,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([4, 7], bytesConsumed: 1));

      expect(vm.triggeredCount, 1);
      expect(vm.observations, hasLength(1));
      expect(vm.observations.single.x, 0);
      expect(vm.observations.single.channelValues, [4, 7, 11]);
      expect(vm.observations.single.note, contains('Math1'));
    });

    test('数学通道支持跨越触发判定', () {
      expect(
        vm.configureMathChannel(0, 'CH0 - CH1', vm.mathChannels[0].display),
        isTrue,
      );
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          channelIndex: 16,
          comparison: PlotTriggerComparison.crossUp,
          targetValue: 0,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([1, 2], bytesConsumed: 1));
      expect(vm.triggeredCount, 0);
      vm.ingestParsedResultForTest(ParseResult.ok([3, 2], bytesConsumed: 1));
      expect(vm.triggeredCount, 1);
    });

    test('含数据偏移或不可见的数学通道不可用于触发', () {
      expect(
        vm.configureMathChannel(0, 'CH0[1]', vm.mathChannels[0].display),
        isTrue,
      );
      expect(
        vm.configureMathChannel(1, 'CH0[-1]', vm.mathChannels[1].display),
        isTrue,
      );
      expect(
        vm.configureMathChannel(2, 'CH0 + 1', vm.mathChannels[2].display),
        isTrue,
      );
      vm.updateMathChannelDisplay(
        2,
        vm.mathChannels[2].display.copyWith(visible: false),
      );

      final candidates =
          vm.triggerCandidateChannels.map((channel) => channel.index).toSet();
      expect(candidates, isNot(contains(16)));
      expect(candidates, isNot(contains(17)));
      expect(candidates, isNot(contains(18)));
    });

    test('触发工具默认隐藏且关闭入口会关闭触发模式', () {
      expect(vm.triggerToolbarEnabled, isFalse);

      vm.setTriggerToolbarEnabled(true);
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
        ),
      );

      expect(vm.triggerToolbarEnabled, isTrue);
      expect(vm.triggerEnabled, isTrue);

      vm.setTriggerToolbarEnabled(false);

      expect(vm.triggerToolbarEnabled, isFalse);
      expect(vm.triggerEnabled, isFalse);
    });

    test('累计命中达到阈值后才触发并可继续监听多次', () {
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          hitThreshold: 2,
          triggerLimit: 2,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.triggerPoint,
          includeSystemTimeInNote: false,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([11], bytesConsumed: 1));
      expect(vm.triggerHitCount, 1);
      expect(vm.triggeredCount, 0);

      vm.ingestParsedResultForTest(ParseResult.ok([12], bytesConsumed: 1));
      expect(vm.triggerHitCount, 0);
      expect(vm.triggeredCount, 1);
      expect(vm.triggerEnabled, isTrue);
      expect(vm.observations.single.x, 1);
      expect(vm.observations.single.note, contains('累计 2 次'));
      expect(vm.observations.single.note, isNot(contains('触发于')));

      vm.ingestParsedResultForTest(ParseResult.ok([13], bytesConsumed: 1));
      vm.ingestParsedResultForTest(ParseResult.ok([14], bytesConsumed: 1));

      expect(vm.triggeredCount, 2);
      expect(vm.triggerEnabled, isFalse);
      expect(vm.observations, hasLength(2));
    });

    test('触发可标记本轮全部命中点并记录系统时间', () {
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
          hitThreshold: 3,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.allHits,
          includeSystemTimeInNote: true,
        ),
      );
      final now = DateTime(2026, 7, 7, 15, 4, 5);

      vm.ingestParsedResultForTestAt(
        ParseResult.ok([1], bytesConsumed: 1),
        now,
      );
      vm.ingestParsedResultForTestAt(
        ParseResult.ok([2], bytesConsumed: 1),
        now,
      );
      vm.ingestParsedResultForTestAt(
        ParseResult.ok([3], bytesConsumed: 1),
        now,
      );

      expect(vm.observations.map((item) => item.x), [0, 1, 2]);
      expect(vm.observations.first.note, contains('触发于 2026-07-07 15:04:05'));
    });

    test('触发观察保留触发点X而不吸附到当前可见窗口旧点', () {
      for (var i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(ParseResult.ok([0], bytesConsumed: 1));
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 4));
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.triggerPoint,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([7], bytesConsumed: 1));

      expect(vm.observations.single.x, 10);
      expect(vm.observations.single.locked, isTrue);
      expect(vm.observations.single.channelValues, [7]);
      expect(vm.observations.single.note, contains('第 1 次触发'));
    });

    test('观察上限限制手动和触发新增并在第100条备注记录上限', () {
      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      for (int i = 0; i < PlotViewModel.maxObservationCount; i++) {
        vm.addObservation();
      }

      expect(vm.observations, hasLength(PlotViewModel.maxObservationCount));
      expect(vm.observations.last.note, contains('观察已达 100 条上限'));

      vm.addObservation();
      expect(vm.observations, hasLength(PlotViewModel.maxObservationCount));

      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 0,
          action: PlotTriggerAction.markOnly,
          observationMode: PlotTriggerObservationMode.triggerPoint,
        ),
      );
      vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 1));
      expect(vm.observations, hasLength(PlotViewModel.maxObservationCount));
    });

    test('观察备注编辑和拖动后保留', () {
      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 1));
      vm.addObservation();

      vm.updateObservationNote(0, 'note');
      vm.updateObservation(0, 1);

      expect(vm.observations.single.x, 1);
      expect(vm.observations.single.note, 'note');
    });

    test('触发后继续接收N包后停止且N不包含触发包', () async {
      vm.setPlottingForTest(true);
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          action: PlotTriggerAction.stopAfterPackets,
          postTriggerPacketCount: 2,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([11], bytesConsumed: 1));
      expect(vm.triggerStopPacketsRemaining, 2);
      expect(vm.isPlotting, isTrue);

      vm.ingestParsedResultForTest(ParseResult.ok([0], bytesConsumed: 1));
      expect(vm.triggerStopPacketsRemaining, 1);
      expect(vm.isPlotting, isTrue);

      vm.ingestParsedResultForTest(ParseResult.ok([0], bytesConsumed: 1));
      await Future<void>.delayed(Duration.zero);

      expect(vm.triggerStopPacketsRemaining, isNull);
      expect(vm.triggerEnabled, isFalse);
      expect(vm.isPlotting, isFalse);
    });

    test('触发行为只在达到触发次数后执行', () async {
      vm.setPlottingForTest(true);
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          triggerLimit: 2,
          action: PlotTriggerAction.stopImmediately,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([11], bytesConsumed: 1));
      await Future<void>.delayed(Duration.zero);
      expect(vm.triggeredCount, 1);
      expect(vm.triggerEnabled, isTrue);
      expect(vm.isPlotting, isTrue);

      vm.ingestParsedResultForTest(ParseResult.ok([12], bytesConsumed: 1));
      await Future<void>.delayed(Duration.zero);
      expect(vm.triggeredCount, 2);
      expect(vm.triggerEnabled, isFalse);
      expect(vm.isPlotting, isFalse);
    });

    test('手动停止绘图会关闭未触发的触发模式', () async {
      vm.setPlottingForTest(true);
      vm.updateTriggerConfig(
        PlotTriggerConfig(
          enabled: true,
          comparison: PlotTriggerComparison.greater,
          targetValue: 10,
          action: PlotTriggerAction.stopImmediately,
          observationMode: PlotTriggerObservationMode.none,
        ),
      );

      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      expect(vm.triggerEnabled, isTrue);

      await vm.stopPlotting();

      expect(vm.triggerEnabled, isFalse);
      expect(vm.triggerHitCount, 0);
    });

    test('clearData清空数据', () {
      // 先添加一些数据
      vm.startPlotting();
      // 无法直接添加数据，测试清空逻辑
      vm.clearData();

      expect(vm.dataPoints.isEmpty, true);
      expect(vm.pointCount, 0);
    });

    test('开始绘图默认清空旧数据，开启保持绘图后继续追加', () async {
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1);

      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 1));

      await vm.startPlotting();
      vm.ingestParsedResultForTest(ParseResult.ok([3], bytesConsumed: 1));

      expect(vm.dataPoints.map((point) => point.index), [0]);
      expect(vm.pointCount, 1);

      await vm.stopPlotting();

      vm.setKeepPlotOnRestart(true);
      await vm.startPlotting();
      vm.ingestParsedResultForTest(ParseResult.ok([4], bytesConsumed: 1));

      expect(vm.dataPoints.map((point) => point.index), [0, 1]);
      expect(vm.dataPoints.map((point) => point.values.single), [3, 4]);
      expect(vm.pointCount, 2);

      await vm.stopPlotting();
    });

    test('保持绘图不会跨协议保留不兼容历史', () async {
      vm.setParserType(ParserType.fixedFrame);
      vm.ingestParsedResultForTest(
        ParseResult.ok([1], rawBytes: Uint8List(10)),
      );
      vm.ingestParsedResultForTest(
        ParseResult.ok([2], rawBytes: Uint8List(10)),
      );
      expect(vm.pointCount, 2);

      vm.setKeepPlotOnRestart(true);
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.setRandomFrequency(1);

      await vm.startPlotting();

      expect(vm.pointCount, 0);
      expect(vm.visiblePointCount, 0);
      expect(vm.lodIndex.isEmpty, isTrue);

      await vm.stopPlotting();
    });

    test('数学通道追加到显示数据且无效求值为NaN', () {
      vm.ingestParsedResultForTest(ParseResult.ok([10, 2], bytesConsumed: 8));
      vm.ingestParsedResultForTest(ParseResult.ok([8, 0], bytesConsumed: 8));

      expect(
        vm.configureMathChannel(0, 'CH0 / CH1', vm.mathChannels[0].display),
        true,
      );

      expect(
        vm.displayChannels.map((channel) => channel.alias),
        contains('Math1'),
      );
      expect(vm.displayDataPoints[0].values.last, 5);
      expect(vm.displayDataPoints[1].values.last.isNaN, true);
    });

    test('数学通道支持按X偏移取相邻点数据', () {
      vm.ingestParsedResultForTest(ParseResult.ok([1, 10], bytesConsumed: 8));
      vm.ingestParsedResultForTest(ParseResult.ok([2, 20], bytesConsumed: 8));
      vm.ingestParsedResultForTest(ParseResult.ok([3, 30], bytesConsumed: 8));

      expect(
        vm.configureMathChannel(0, 'CH1[-1] + CH0', vm.mathChannels[0].display),
        true,
      );

      final values = vm.displayDataPoints.map((point) => point.values.last);
      expect(values.elementAt(0), 21);
      expect(values.elementAt(1), 32);
      expect(values.elementAt(2).isNaN, true);

      expect(
        vm.configureMathChannel(0, 'CH1[1]', vm.mathChannels[0].display),
        true,
      );

      final shiftedValues = vm.displayDataPoints.map(
        (point) => point.values.last,
      );
      expect(shiftedValues.elementAt(0).isNaN, true);
      expect(shiftedValues.elementAt(1), 10);
      expect(shiftedValues.elementAt(2), 20);
    });

    test('数学通道缓存会在新点到来后补算受未来偏移影响的尾部点', () {
      vm.ingestParsedResultForTest(ParseResult.ok([1, 10], bytesConsumed: 8));
      vm.ingestParsedResultForTest(ParseResult.ok([2, 20], bytesConsumed: 8));

      expect(
        vm.configureMathChannel(0, 'CH1[-1]', vm.mathChannels[0].display),
        true,
      );

      final firstDisplay = vm.displayDataPoints;
      expect(firstDisplay[0].values.last, 20);
      expect(firstDisplay[1].values.last.isNaN, true);

      vm.ingestParsedResultForTest(ParseResult.ok([3, 30], bytesConsumed: 8));

      final nextDisplay = vm.displayDataPoints;
      expect(nextDisplay[1].values.last, 30);
      expect(nextDisplay[2].values.last.isNaN, true);
    });

    test('数学通道显示偏移和缩放不重建表达式数据缓存', () {
      for (int i = 0; i < 20; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble(), (i * 2).toDouble()], bytesConsumed: 8),
        );
      }

      expect(
        vm.configureMathChannel(0, 'CH0 + CH1', vm.mathChannels[0].display),
        true,
      );

      final firstDisplay = vm.displayDataPoints;

      vm.setChannelYOffset(16, 25);
      expect(identical(vm.displayDataPoints, firstDisplay), true);

      vm.zoomChannelYScale(16, 1.2);
      expect(identical(vm.displayDataPoints, firstDisplay), true);
    });

    test('观察和吸附高亮包含数学通道', () {
      vm.ingestParsedResultForTest(ParseResult.ok([10, 2], bytesConsumed: 8));
      vm.ingestParsedResultForTest(ParseResult.ok([8, 3], bytesConsumed: 8));
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 1));

      expect(
        vm.configureMathChannel(0, 'CH0 + CH1', vm.mathChannels[0].display),
        true,
      );

      vm.updateFollowCursor(0, 0, const Offset(10, 10));
      vm.addObservation();
      expect(vm.observations.single.channelValues, [10, 2, 12]);

      vm.setSnapHighlightColorMode('channel');
      vm.setXCursor1(0);

      final xCursorHighlights = vm.snapHighlights.take(3).toList();
      expect(xCursorHighlights, hasLength(3));
      expect(xCursorHighlights.last.y, 12);
      expect(xCursorHighlights.last.color, vm.mathChannels[0].display.color);
    });

    test('X测量线在视口外时切换高亮颜色不会吸附到边缘', () {
      for (int i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 4));
      vm.setXCursor1(2);
      expect(vm.snapHighlights, isNotEmpty);

      vm.updateViewport(vm.viewport.copyWith(xMin: 6, xMax: 9));
      vm.setSnapHighlightColorMode('channel');

      expect(vm.xCursor1, 2);
      expect(vm.snapHighlights, isEmpty);
    });

    test('丢弃包数会跳过开始后的前N个有效数据包', () {
      vm.setDiscardInitialPacketCount(2);
      vm.setPlottingForTest(true);

      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
      vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 1));

      expect(vm.pointCount, 0);
      expect(vm.dataPoints, isEmpty);

      vm.ingestParsedResultForTest(ParseResult.ok([3], bytesConsumed: 1));

      expect(vm.pointCount, 1);
      expect(vm.dataPoints.single.values, [3]);

      vm.clearData();
      vm.ingestParsedResultForTest(ParseResult.ok([4], bytesConsumed: 1));

      expect(vm.pointCount, 1);
      expect(vm.dataPoints.single.values, [4]);
    });

    test('BIN 导入导出保留通道数据', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_bin_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1.5,2.5\n1,3.5,4.5\n');
      final csvError = await vm.importFromCsv(csv.path);
      expect(csvError, isNull);

      final binPath = '${dir.path}/plot.bin';
      final progress = <PlotImportProgress>[];
      final exported = await vm.exportToBin(binPath, onProgress: progress.add);
      expect(exported, binPath);
      expect(progress, isNotEmpty);
      expect(progress.last.current, progress.last.total);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      final binError = await imported.importFromBin(binPath);
      expect(binError, isNull);
      expect(imported.dataPoints.length, 2);
      expect(imported.dataPoints[0].values, [1.5, 2.5]);
      expect(imported.dataPoints[1].values, [3.5, 4.5]);
    });

    test('BIN 导出会补全缺失后缀并保留观察位置备注和锁定状态', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_bin_observation_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1,2\n1,3,4\n2,5,6\n');
      expect(await vm.importFromCsv(csv.path), isNull);
      vm.updateFollowCursor(1, 0, const Offset(1, 1));
      vm.addObservation();
      vm.updateObservationNote(0, 'manual note');
      vm.setObservationLocked(0, true);

      final binPath = '${dir.path}/plot';
      final exportedPath = '$binPath.bin';
      expect(await vm.exportToBin(binPath), exportedPath);
      expect(File(exportedPath).existsSync(), isTrue);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(exportedPath), isNull);
      expect(imported.observations, hasLength(1));
      expect(imported.observations.single.x, 1);
      expect(imported.observations.single.note, 'manual note');
      expect(imported.observations.single.locked, isTrue);
      expect(imported.observations.single.channelValues, [3, 4]);
    });

    test('CSV 和 BIN 导出支持范围并重新编号X', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_export_range_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,10,20\n1,11,21\n2,12,22\n3,13,23\n');
      expect(await vm.importFromCsv(csv.path), isNull);
      vm.updateFollowCursor(2, 0, const Offset(1, 1));
      vm.addObservation();

      final outCsvPath = '${dir.path}/range.csv';
      expect(
        await vm.exportToCsv(outCsvPath, startIndex: 1, endIndex: 2),
        outCsvPath,
      );
      final outLines = await File(outCsvPath).readAsLines().then(
        (lines) => lines.where((line) => !line.startsWith('#')),
      );
      expect(outLines.toList(), [
        'x,y1,y2',
        '0,11.000000,21.000000',
        '1,12.000000,22.000000',
      ]);
      expect(
        await File(outCsvPath).readAsString(),
        isNot(contains('observations')),
      );

      final outBinPath = '${dir.path}/range.bin';
      expect(
        await vm.exportToBin(outBinPath, startIndex: 2, endIndex: 3),
        outBinPath,
      );
      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(outBinPath), isNull);
      expect(imported.dataPoints, hasLength(2));
      expect(imported.dataPoints[0].timestamp, 0);
      expect(imported.dataPoints[0].values, [12, 22]);
      expect(imported.dataPoints[1].timestamp, 1);
      expect(imported.dataPoints[1].values, [13, 23]);
    });

    test('BIN 导出取消后删除半成品', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_bin_cancel_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      for (var i = 0; i < 10; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }
      final token = PlotExportCancelToken()..cancel();
      final binPath = '${dir.path}/cancel.bin';

      final exported = await vm.exportToBin(binPath, cancelToken: token);

      expect(exported, isNull);
      expect(File(binPath).existsSync(), isFalse);
    });

    test('BIN 导出超过当前格式4GB上限时拒绝导出', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_bin_limit_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      vm.debugSetParsedHistoryForExportTest(
        pointCount: 40000000,
        channelCount: 16,
      );
      final binPath = '${dir.path}/too_large.bin';

      final exported = await vm.exportToBin(binPath);

      expect(exported, isNull);
      expect(File(binPath).existsSync(), isFalse);
      expect(vm.lastStatusMessage, contains('4GB'));
    });

    test('导入导出保留通道名称和众邦地址', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_meta_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1,2\n1,3,4\n');
      expect(await vm.importFromCsv(csv.path), isNull);
      vm.setParserType(ParserType.zobow);
      vm.setZobowChannelId(0, 0x00000095);
      vm.setZobowChannelId(1, 0x12345678);
      vm.setChannelAlias(0, '主轴角度');
      vm.setChannelAlias(1, '速度');

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

    test('BIN 导入导出保留 r 协议通道地址', () async {
      final dir = await Directory.systemTemp.createTemp('vscope_r_bin_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1,y2\n0,1,2\n1,3,4\n');
      expect(await vm.importFromCsv(csv.path), isNull);
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.setRChannelAddress(0, '16');
      vm.setRChannelAddress(1, '0x20');
      vm.setChannelAlias(0, '主轴角度');
      vm.setChannelAlias(1, '速度');

      final binPath = '${dir.path}/plot.bin';
      expect(await vm.exportToBin(binPath), binPath);

      final imported = PlotViewModel(serialService);
      addTearDown(imported.dispose);
      expect(await imported.importFromBin(binPath), isNull);

      expect(imported.sendProtocolType, SendProtocolType.rProtocol);
      expect(imported.rChannelAddresses.take(2), ['16', '0x20']);
      expect(imported.channels[0].alias, '主轴角度');
      expect(imported.channels[1].alias, '速度');
    });

    test('众邦通道地址和通道数据类型会写入设置并可重启恢复', () async {
      vm.setParserType(ParserType.zobow);
      vm.setZobowChannelId(0, 0x00000095);
      expect(await vm.setZobowChannelType(1, DataType.uint16), true);

      expect(AppSettings().zobowChannelIds[0], 0x00000095);
      expect(AppSettings().zobowChannelTypes[1], DataType.uint16);

      final restored = PlotViewModel(serialService);
      addTearDown(restored.dispose);
      restored.setParserType(ParserType.zobow);

      expect(restored.parserConfig.zobowChannelIds[0], 0x00000095);
      expect(restored.parserConfig.zobowChannelTypes[0], DataType.int16);
      expect(restored.parserConfig.zobowChannelTypes[1], DataType.uint16);
    });

    test('众邦快捷配置带入的通道名称会重启恢复', () {
      vm.setParserType(ParserType.zobow);
      vm.applyPresetToChannel(
        0,
        AddressChannelPreset(name: '主轴角度', address: 0x00000095),
      );

      final restored = PlotViewModel(serialService);
      addTearDown(restored.dispose);
      restored.setParserType(ParserType.zobow);

      expect(restored.parserConfig.zobowChannelIds[0], 0x00000095);
      expect(restored.channels[0].alias, '主轴角度');
    });

    test('手动修改众邦通道地址会清空快捷配置带入的通道名称', () {
      vm.setParserType(ParserType.zobow);
      vm.applyPresetToChannel(
        0,
        AddressChannelPreset(name: '主轴角度', address: 0x00000095),
      );

      vm.setZobowChannelId(0, 0x00000096);

      expect(vm.parserConfig.zobowChannelIds[0], 0x00000096);
      expect(vm.channels[0].alias, isEmpty);
      expect(AppSettings().channelPresetBindings, isEmpty);
    });

    test('固定帧逐通道数据类型会写入设置并可重启恢复', () async {
      vm.setParserType(ParserType.fixedFrame);
      vm.updateParserConfig(
        vm.parserConfig.copyWith(
          type: ParserType.fixedFrame,
          channelCount: 2,
          fixedFrameUniformDataType: false,
          fixedFrameChannelTypes: [
            DataType.int16,
            DataType.float,
            ...List.filled(14, DataType.uint16),
          ],
        ),
      );

      expect(AppSettings().fixedFrameChannelTypes[0], DataType.int16);
      expect(AppSettings().fixedFrameChannelTypes[1], DataType.float);

      final restored = PlotViewModel(serialService);
      addTearDown(restored.dispose);

      expect(restored.parserConfig.fixedFrameChannelTypes[0], DataType.int16);
      expect(restored.parserConfig.fixedFrameChannelTypes[1], DataType.float);
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

    test('测量统计工具开关只控制工具栏入口', () {
      expect(vm.statsToolbarEnabled, false);
      expect(vm.statsEnabled, false);
      expect(vm.statsRangeEnabled, false);

      vm.setStatsToolbarEnabled(true);

      expect(vm.statsToolbarEnabled, true);
      expect(vm.statsEnabled, false);
      expect(vm.statsRangeEnabled, false);
    });

    test('拖动画布时自动关闭跟随', () {
      vm.setFollowEnabled(true);

      vm.updateViewport(
        vm.viewport.copyWith(xMin: 100, xMax: 1100),
        fromDrag: true,
      );

      expect(vm.followEnabled, false);
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

    test('X范围达到显示上限后继续缩小不移动视口', () {
      vm.updateViewport(vm.viewport.copyWith(xMin: 100, xMax: 1000100));
      final before = vm.viewport.copy();

      vm.zoomXOut();

      expect(vm.viewport.xMin, before.xMin);
      expect(vm.viewport.xMax, before.xMax);
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

    test('开始绘图仅保留垂直光标开关', () async {
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.setVCursorEnabled(true);
      vm.updateFollowCursor(10, 0, const Offset(1, 1));
      vm.addObservation();
      vm.toggleXMeasurement();
      vm.toggleYMeasurement();
      vm.toggleStats();
      vm.toggleStatsRange();

      await vm.startPlotting();

      expect(vm.vCursorEnabled, isTrue);
      expect(vm.cursor, isNull);
      expect(vm.observations, isEmpty);
      expect(vm.xMeasurementEnabled, isFalse);
      expect(vm.yMeasurementEnabled, isFalse);
      expect(vm.statsEnabled, isFalse);
      expect(vm.statsRangeEnabled, isFalse);
      expect(vm.measurementText, isNull);
      expect(vm.statsX1, isNull);
      expect(vm.statsX2, isNull);

      await vm.stopPlotting();
    });

    test('导入数据后仅保留垂直光标开关', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vscope_cursor_import_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final csv = File('${dir.path}/input.csv');
      await csv.writeAsString('x,y1\n0,1\n1,2\n');

      vm.setVCursorEnabled(true);
      vm.updateFollowCursor(10, 0, const Offset(1, 1));
      vm.addObservation();
      vm.toggleXMeasurement();
      vm.toggleYMeasurement();
      vm.toggleStats();
      vm.toggleStatsRange();

      expect(await vm.importFromCsv(csv.path), isNull);

      expect(vm.vCursorEnabled, isTrue);
      expect(vm.cursor, isNull);
      expect(vm.observations, isEmpty);
      expect(vm.xMeasurementEnabled, isFalse);
      expect(vm.yMeasurementEnabled, isFalse);
      expect(vm.statsEnabled, isFalse);
      expect(vm.statsRangeEnabled, isFalse);
      expect(vm.measurementText, isNull);
      expect(vm.statsX1, isNull);
      expect(vm.statsX2, isNull);
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

    test('绑定偏置支持多组且组内同步偏移和缩放', () {
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      for (int i = 0; i < 4; i++) {
        vm.setChannelOffsetEnabled(i, true);
      }

      vm.setChannelYOffset(0, 100);
      vm.zoomChannelYScale(0, 2);
      vm.setChannelYOffset(2, 200);
      vm.zoomChannelYScale(2, 3);

      vm.setOffsetBindingGroup(0, {1});
      vm.setOffsetBindingGroup(2, {3});

      expect(vm.offsetBindingMemberIndices(0), [0, 1]);
      expect(vm.offsetBindingMemberIndices(2), [2, 3]);
      expect(vm.channels[1].yOffset, vm.channels[0].yOffset);
      expect(vm.channels[1].yScale, vm.channels[0].yScale);
      expect(vm.channels[3].yOffset, vm.channels[2].yOffset);
      expect(vm.channels[3].yScale, vm.channels[2].yScale);

      vm.setChannelYOffset(1, 320);
      vm.zoomChannelYScale(3, 0.5);

      expect(vm.channels[0].yOffset, 320);
      expect(vm.channels[1].yOffset, 320);
      expect(vm.channels[2].yScale, vm.channels[3].yScale);
      expect(vm.channels[0].offsetBindingGroupId, isNotNull);
      expect(vm.channels[2].offsetBindingGroupId, isNotNull);
      expect(
        vm.channels[0].offsetBindingGroupId,
        isNot(vm.channels[2].offsetBindingGroupId),
      );
    });

    test('绑定偏置Y自适应按组内所有通道合并计算', () {
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      vm.setChannelOffsetEnabled(0, true);
      vm.setChannelOffsetEnabled(1, true);
      vm.setOffsetBindingGroup(0, {1});

      vm.ingestParsedResultForTest(
        ParseResult.ok([0.0, 100.0], bytesConsumed: 8),
      );
      vm.ingestParsedResultForTest(
        ParseResult.ok([10.0, 200.0], bytesConsumed: 8),
      );

      vm.fitYAxis();

      expect(vm.channels[0].yScale, vm.channels[1].yScale);
      expect(vm.channels[0].yOffset, vm.channels[1].yOffset);
      final values = <double>[0, 10, 100, 200];
      final fitted =
          values
              .map(
                (value) =>
                    value * vm.channels[0].yScale + vm.channels[0].yOffset,
              )
              .toList();
      expect(fitted.reduce(math.min), greaterThan(vm.viewport.yMin));
      expect(fitted.reduce(math.max), lessThan(vm.viewport.yMax));
    });

    test('关闭偏置会移出绑定组并在组不足两通道时解散', () {
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 0);
      vm.setChannelOffsetEnabled(0, true);
      vm.setChannelOffsetEnabled(1, true);
      vm.setChannelOffsetEnabled(2, true);
      vm.setOffsetBindingGroup(0, {1, 2});

      vm.setChannelOffsetEnabled(1, false);

      expect(vm.channels[1].offsetBindingGroupId, isNull);
      expect(vm.channels[0].offsetBindingGroupId, isNotNull);
      expect(
        vm.channels[2].offsetBindingGroupId,
        vm.channels[0].offsetBindingGroupId,
      );

      vm.setChannelOffsetEnabled(2, false);

      expect(vm.channels[0].offsetBindingGroupId, isNull);
      expect(vm.channels[2].offsetBindingGroupId, isNull);
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

    test('随机源频率支持整数100KHz上限', () {
      vm.setRandomFrequency(100000.4);
      expect(vm.randomFrequency, 100000);

      vm.setRandomFrequency(0);
      expect(vm.randomFrequency, 1);
    });

    test('状态栏高速率统计不会被1000个样本限制在2000每秒', () {
      for (int ms = 500; ms <= 1000; ms++) {
        vm.recordRateSampleForTest(ms * 64, ms);
      }

      final match = RegExp(r'\(([\d.]+)/s\)').firstMatch(vm.statusText);
      expect(match, isNotNull);
      final rate = double.parse(match!.group(1)!);
      expect(rate, greaterThan(60000));
    });

    test('十万包速率统计只保留固定数量时间桶', () {
      for (int i = 0; i < 100000; i++) {
        vm.recordRateSampleForTest(i, i ~/ 100);
      }

      expect(vm.rateBucketCountForTest, lessThanOrEqualTo(49));
      expect(vm.highRateMode, true);
    });

    test('数据类型元数据替代绘制阶段全量整数扫描', () {
      vm.setParserType(ParserType.fireWater);
      vm.updateParserConfig(
        ParserConfig.fireWaterDefault()..fireWaterChannelCount = 2,
      );
      for (int i = 0; i < 2; i++) {
        vm.setChannelVisible(i, true);
        vm.setChannelOffsetEnabled(i, false);
        vm.setChannelYScale(i, 1);
      }
      for (final channel in vm.mathChannels) {
        if (channel.enabled) vm.disableMathChannel(channel.index);
      }
      vm.ingestParsedResultForTest(ParseResult.ok([1, 2], bytesConsumed: 1));
      expect(vm.displayYValuesAreInteger, true);

      vm.ingestParsedResultForTest(ParseResult.ok([3.5, 4], bytesConsumed: 1));
      expect(vm.displayYValuesAreInteger, false);

      vm.clearData();
      vm.ingestParsedResultForTest(ParseResult.ok([2, 4], bytesConsumed: 1));
      vm.setChannelYScale(0, 0.5);
      expect(vm.displayYValuesAreInteger, false);
    });

    test('数据、通道、视口和覆盖层revision互不串扰', () {
      final dataRevision = vm.dataRevision;
      final channelRevision = vm.channelConfigRevision;
      final viewportRevision = vm.viewportRevision;
      final overlayRevision = vm.overlayRevision;

      vm.setChannelColor(0, Colors.purple);
      expect(vm.channelConfigRevision, channelRevision + 1);
      expect(vm.dataRevision, dataRevision);
      expect(vm.viewportRevision, viewportRevision);
      expect(vm.overlayRevision, overlayRevision);

      vm.updateViewport(vm.viewport.copyWith(xMin: 10, xMax: 1010));
      expect(vm.viewportRevision, viewportRevision + 1);
      expect(vm.overlayRevision, overlayRevision);

      vm.updateCursor(CursorState(x: 10, y: 1, hasData: false));
      expect(vm.overlayRevision, overlayRevision + 1);
      expect(vm.dataRevision, dataRevision);
    });

    test('高频接收强制使用30fps但不修改用户刷新帧率', () {
      vm.setRefreshFps(60);

      for (int ms = 500; ms <= 1000; ms += 250) {
        vm.recordRateSampleForTest(ms * 20, ms);
      }

      expect(vm.highRateMode, true);
      expect(vm.refreshFps, 60);
      expect(vm.effectiveRefreshFps, 30);
      expect(vm.statusText, contains('高频模式 30fps'));
    });

    test('高频模式在10K附近不会反复切换并在低于8K后延迟退出', () {
      vm.setRefreshFps(60);
      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(6000, 300);

      expect(vm.highRateMode, true);

      vm.recordRateSampleForTest(10500, 800);
      expect(vm.highRateMode, true);

      vm.recordRateSampleForTest(13500, 1300);
      expect(vm.highRateMode, true);

      vm.recordRateSampleForTest(16500, 1800);
      vm.recordRateSampleForTest(19500, 2300);
      vm.recordRateSampleForTest(22500, 2800);
      expect(vm.highRateMode, true);

      vm.recordRateSampleForTest(25500, 3300);
      expect(vm.highRateMode, true);

      vm.recordRateSampleForTest(28500, 3800);
      vm.recordRateSampleForTest(31500, 4300);
      expect(vm.highRateMode, false);
      expect(vm.effectiveRefreshFps, 60);
    });

    test('串口源高频刷新批量按实测速率和有效fps计算', () {
      for (int ms = 500; ms <= 1000; ms += 250) {
        vm.recordRateSampleForTest(ms * 100, ms);
      }

      expect(vm.highRateMode, true);
      expect(vm.notifyBatchSizeForTest, inInclusiveRange(3300, 3350));
    });

    test('高频模式使用用户配置的当前精确窗口上限', () {
      vm.setMaxVisiblePoints(1000000);
      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(6000, 300);

      expect(vm.highRateMode, true);
      expect(vm.maxVisiblePoints, 1000000);
      expect(vm.effectiveMaxVisiblePoints, 1000000);
    });

    test('高频模式未达到用户窗口上限时保留当前精确窗口', () {
      vm.setMaxVisiblePoints(1000000);
      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(6000, 300);

      for (int i = 0; i < 200005; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }

      expect(vm.highRateMode, true);
      expect(vm.visiblePointCount, 200005);
      expect(vm.pointCount, greaterThan(vm.visiblePointCount));
      expect(vm.lodIndex.length, vm.pointCount);
    });

    test('高频模式超过40万点时不使用固定窗口上限', () {
      vm.setMaxVisiblePoints(1000000);
      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(6000, 300);
      final startPointCount = vm.pointCount;

      for (int i = 0; i < 400005; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 1),
        );
      }

      expect(vm.highRateMode, true);
      expect(vm.visiblePointCount, 400005);
      expect(vm.pointCount - startPointCount, 400005);
      expect(vm.lodIndex.length, vm.pointCount);
    });

    test('高频模式按实测速率降低LOD逐包更新压力', () {
      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(50000, 500);

      expect(vm.highRateMode, true);
      expect(vm.lodSampleStepForTest, greaterThan(1));
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
        '0',
        ' 12 ',
        '0x10',
        '0X2A',
      ]);

      expect(utf8.decode(bytes), 'r 0 12 0x10 0X2A\n');
    });

    test('r协议地址严格区分十进制和带0x前缀的十六进制', () {
      expect(PlotViewModel.parseRProtocolAddress('16'), 16);
      expect(PlotViewModel.parseRProtocolAddress('0x10'), 16);
      expect(PlotViewModel.parseRProtocolAddress('FF'), isNull);
      expect(PlotViewModel.parseRProtocolAddress('12x3'), isNull);
      expect(PlotViewModel.parseRProtocolAddress('0xGG'), isNull);
      expect(PlotViewModel.parseRProtocolAddress('4294967296'), isNull);
    });

    test('r协议预设应用到通道时保留配置进制', () {
      final revisionBefore = vm.channelConfigRevision;
      vm.applyRProtocolPresetToChannel(
        0,
        AddressChannelPreset(
          name: '十进制',
          address: 16,
          addressFormat: AddressValueFormat.decimal,
        ),
      );
      vm.applyRProtocolPresetToChannel(
        1,
        AddressChannelPreset(
          name: '十六进制',
          address: 16,
          addressFormat: AddressValueFormat.hexadecimal,
        ),
      );

      expect(vm.rChannelAddresses.take(2), ['16', '0x10']);
      expect(vm.channels[0].alias, '十进制');
      expect(vm.channelConfigRevision, greaterThan(revisionBefore));
    });

    test('r协议快捷配置带入的通道名称会重启恢复并在地址改变时清空', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.applyRProtocolPresetToChannel(
        0,
        AddressChannelPreset(
          name: '十进制',
          address: 16,
          addressFormat: AddressValueFormat.decimal,
        ),
      );

      final restored = PlotViewModel(serialService);
      addTearDown(restored.dispose);

      expect(restored.rChannelAddresses[0], '16');
      expect(restored.channels[0].alias, '十进制');

      restored.setRChannelAddress(0, '0x10');
      expect(restored.channels[0].alias, '十进制');

      restored.setRChannelAddress(0, '17');
      expect(restored.channels[0].alias, isEmpty);
      expect(AppSettings().channelPresetBindings, isEmpty);
    });

    test('绘图运行中锁定R和Zobow地址但允许修改名称', () {
      vm.setRChannelAddress(0, '10');
      vm.setZobowChannelId(0, 0x10);
      vm.setPlottingForTest(true);

      vm.setRChannelAddress(0, '20');
      vm.setZobowChannelId(0, 0x20);
      vm.applyRProtocolPresetToChannel(
        0,
        AddressChannelPreset(
          name: '运行中预设',
          address: 30,
          addressFormat: AddressValueFormat.decimal,
        ),
      );
      vm.applyPresetToChannel(
        0,
        AddressChannelPreset(name: '运行中Zobow', address: 0x30),
      );
      vm.setChannelAlias(0, '运行中名称');

      expect(vm.rChannelAddresses[0], '10');
      expect(vm.parserConfig.zobowChannelIds[0], 0x10);
      expect(vm.channels[0].alias, '运行中名称');
    });

    test('停止时可重置全部通道且运行中拒绝重置', () {
      vm.setRChannelAddress(0, '10');
      vm.setZobowChannelId(0, 0x20);
      vm.setChannelAlias(0, '自定义名称');
      vm.setChannelVisible(0, false);
      expect(vm.enableMathChannel(0, 'CH0 + CH1'), isTrue);

      expect(vm.resetAllChannels(), isTrue);
      expect(vm.rChannelAddresses.every((address) => address.isEmpty), isTrue);
      expect(vm.parserConfig.zobowChannelIds.first, 1);
      expect(vm.parserConfig.zobowChannelTypes.first, DataType.int16);
      expect(vm.parserConfig.fixedFrameChannelTypes.first, DataType.uint16);
      expect(vm.channels[0].alias, isEmpty);
      expect(vm.channels[0].visible, isTrue);
      expect(vm.mathChannels.every((channel) => !channel.enabled), isTrue);

      vm.setChannelAlias(0, '运行中保留');
      vm.setPlottingForTest(true);
      expect(vm.resetAllChannels(), isFalse);
      expect(vm.channels[0].alias, '运行中保留');
    });

    test('r协议地址校验支持0地址、自动连续前缀和固定通道截断', () {
      expect(PlotViewModel.validateRProtocolAddresses(['0', '0x0', '20', '']), [
        '0',
        '0x0',
        '20',
      ]);
      expect(
        PlotViewModel.validateRProtocolAddresses([
          '1',
          '0x10',
          '20',
        ], requiredCount: 2),
        ['1', '0x10'],
      );
    });

    test('r协议宽松通道设置会压紧非空地址并保留0地址', () {
      expect(
        PlotViewModel.validateRProtocolAddresses([
          '',
          '0',
          '',
          '0x10',
          ' 20 ',
        ], loose: true),
        ['0', '0x10', '20'],
      );
      expect(
        PlotViewModel.validateRProtocolAddresses(
          ['', '0', '', '0x10'],
          requiredCount: 3,
          loose: true,
        ),
        ['0', '0x10'],
      );
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['', ''], loose: true),
        throwsFormatException,
      );
    });

    test('r协议地址校验拒绝全空、固定通道不足和中间空洞', () {
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['', '']),
        throwsFormatException,
      );
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['1'], requiredCount: 2),
        throwsFormatException,
      );
      expect(
        () => PlotViewModel.validateRProtocolAddresses(['0', '', '2']),
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

    test('宽松通道设置下FireWater自动识别按非空r地址显示槽位', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.setParserType(ParserType.fireWater);
      vm.updateParserConfig(ParserConfig.fireWaterDefault());
      vm.setRChannelAddress(3, '0');
      vm.setRChannelAddress(5, '0x10');
      vm.setRProtocolLooseChannelSettings(true);
      vm.setPlottingForTest(true);
      expect(vm.rAddressDisplayCount, 3);
    });

    test('JustFloat自动识别运行时r协议按解析通道数显示', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault());

      expect(vm.rAddressDisplayCount, SendProtocolConfig.maxChannelCount);

      vm.setPlottingForTest(true);
      expect(vm.rAddressDisplayCount, 0);

      vm.ingestParsedResultForTest(
        ParseResult.ok([1, 2, 3], bytesConsumed: 12),
      );
      expect(vm.activeChannelCount, 3);
      expect(vm.rAddressDisplayCount, 3);

      vm.ingestParsedResultForTest(ParseResult.ok([4, 5], bytesConsumed: 8));
      expect(vm.activeChannelCount, 2);
      expect(vm.rAddressDisplayCount, 2);

      vm.setPlottingForTest(false);
      expect(vm.rAddressDisplayCount, SendProtocolConfig.maxChannelCount);
    });

    test('固定接收通道数时r协议按配置通道数显示', () {
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      for (var i = 0; i < 8; i++) {
        vm.setRChannelAddress(i, '${i + 1}');
      }

      vm.setParserType(ParserType.justFloat);
      vm.updateParserConfig(ParserConfig.justFloatDefault()..channelCount = 3);
      expect(vm.rAddressDisplayCount, 3);

      vm.setParserType(ParserType.fireWater);
      vm.updateParserConfig(
        ParserConfig.fireWaterDefault()..fireWaterChannelCount = 4,
      );
      expect(vm.rAddressDisplayCount, 4);
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

    test('绘图运行时拒绝修改随机源、协议、解析器和配置文件', () {
      final originalParser = vm.parserType;
      final originalSendProtocol = vm.sendProtocolType;
      final originalRandomSource = vm.useRandomSource;
      final originalChannelCount = vm.parserConfig.channelCount;
      final originalLooseSettings = vm.rProtocolLooseChannelSettings;
      final originalProfileRevision = vm.profileRevision;

      vm.setPlottingForTest(true);
      vm.setUseRandomSource(!originalRandomSource);
      vm.setParserType(ParserType.zobow);
      vm.setSendProtocolType(SendProtocolType.rProtocol);
      vm.setRProtocolLooseChannelSettings(!vm.rProtocolLooseChannelSettings);
      vm.updateParserConfig(
        vm.parserConfig.copyWith(channelCount: originalChannelCount + 1),
      );
      vm.selectRProfile(null);

      expect(vm.useRandomSource, originalRandomSource);
      expect(vm.parserType, originalParser);
      expect(vm.sendProtocolType, originalSendProtocol);
      expect(vm.parserConfig.channelCount, originalChannelCount);
      expect(vm.rProtocolLooseChannelSettings, originalLooseSettings);
      expect(vm.profileRevision, originalProfileRevision);
      expect(
        vm.lastStatusMessage,
        AppStrings.plot.inputConfigurationDisabledWhilePlotting,
      );

      vm.setPlottingForTest(false);
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

    test('stopPlotting后高频模式恢复用户配置刷新帧率', () async {
      vm.setRefreshFps(60);
      vm.setParserType(ParserType.fireWater);
      vm.setUseRandomSource(true);
      vm.startPlotting();
      expect(vm.isPlotting, true);

      vm.recordRateSampleForTest(0, 0);
      vm.recordRateSampleForTest(6000, 300);
      expect(vm.highRateMode, true);
      expect(vm.effectiveRefreshFps, 30);

      await vm.stopPlotting();

      expect(vm.highRateMode, false);
      expect(vm.refreshFps, 60);
      expect(vm.effectiveRefreshFps, 60);
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
