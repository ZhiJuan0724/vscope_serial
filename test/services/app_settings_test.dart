import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/app_settings.dart';

void main() {
  test(
    'resetToDefaults restores application settings without profile cleanup',
    () async {
      final settings =
          AppSettings()
            ..lastPort = 'COM9'
            ..baudRate = 9600
            ..refreshFps = 30
            ..plotFontSizeDelta = 4
            ..plotFontBold = true
            ..lastMainPage = 'plot'
            ..maxVisiblePoints = 40000000
            ..plotHistoryMemoryLimitGiB = 8
            ..discardInitialPacketCount = 8
            ..keepPlotOnRestart = true
            ..snapHighlightEnabled = false
            ..snapHighlightDiameter = 12
            ..snapHighlightColorMode = 'channel'
            ..xMeasurementLine1Color = 0xFF112233
            ..xMeasurementLine2Color = 0xFF445566
            ..yMeasurementLine1Color = 0xFF778899
            ..yMeasurementLine2Color = 0xFFAABBCC
            ..xMeasurementLine1Opacity = 0.2
            ..xMeasurementLine2Opacity = 0.3
            ..yMeasurementLine1Opacity = 0.4
            ..yMeasurementLine2Opacity = 0.5
            ..yMeasurementSnapEnabled = false
            ..statsToolbarEnabled = true
            ..triggerToolbarEnabled = true
            ..previewToolbarEnabled = true
            ..plotReceiveAggregationEnabled = true
            ..plotLodQuality = 'quality'
            ..showGrid = false
            ..gridDensity = 'dense'
            ..plotBackground = 'light'
            ..floatingPanelOpacity = 0.5
            ..plotLegendPanelRight = 10
            ..plotLegendPanelTop = 20
            ..plotLiveValuesPanelRight = 30
            ..plotLiveValuesPanelTop = 40
            ..observationClickToPlace = true
            ..useRandomSource = true
            ..randomFrequency = 500
            ..followEnabled = true
            ..followPositionRatio = 0.5
            ..yFitDisplayRatio = 0.95
            ..parserType = 'zobow'
            ..sendProtocolType = 'rProtocol'
            ..receiveCustomProtocolId = 'receive'
            ..sendCustomProtocolId = 'send'
            ..rChannelAddresses = List.filled(16, '0x10')
            ..rProtocolLooseChannelSettings = true
            ..justFloatChannelCount = 8
            ..zobowProfileId = 'z-profile'
            ..rProfileId = 'r-profile'
            ..zobowPresetViewMode = 'list'
            ..autoUpdateCheckEnabled = true
            ..updateChannel = 'beta'
            ..updateSource = 'gitee'
            ..disableNotifications = true
            ..diagnosticLoggingEnabled = true
            ..rawDataDisplayLineLimit = 500
            ..rawDataAutoLineBreakIntervalMs = 250
            ..rawDataShellMode = true
            ..rawDataShellEnabled = true
            ..rawDataShellInputMode = 'key'
            ..rawDataTerminalFontSize = 20
            ..rawDataTerminalFontFamily = 'Courier New'
            ..rawDataShellTheme = 'dark'
            ..rawDataShellCursor = 'block'
            ..shellEncoding = 'GBK'
            ..shellLineEnding = '\n'
            ..shellLocalEcho = false
            ..shellScrollbackLines = 50000
            ..ymodemSaveDirectoryPolicy = 'custom'
            ..rawMultiSendProfileId = 'multi-send'
            ..rttPageEnabled = true
            ..rttBackendMode = 'builtin'
            ..rttJlinkExecutablePath = 'jlink.exe'
            ..rttPyocdExecutablePath = 'pyocd.exe'
            ..rttBuiltinHelperPath = 'helper.exe'
            ..rttProbeKind = 'cmsisDap'
            ..rttLastProbeId = 'probe'
            ..rttTarget = 'target'
            ..rttAutoDetectTarget = true
            ..rttWireProtocol = 'jtag'
            ..rttClockKhz = 8000
            ..rttControlBlockMode = 'range'
            ..rttControlBlockAddress = 0x20001000
            ..rttControlBlockRangeStart = 0x20000000
            ..rttControlBlockRangeEnd = 0x20010000
            ..rttEncoding = 'GBK'
            ..rttDisplayMode = 'hex'
            ..rttTimestampEnabled = true
            ..rttAutoScroll = false
            ..rttFontFamily = 'Courier New'
            ..rttFontSize = 18
            ..rttHistoryLineLimit = 200000
            ..xMin = 10
            ..xMax = 20
            ..yMin = 30
            ..yMax = 40;

      await settings.resetToDefaults();

      expect(settings.lastPort, isNull);
      expect(settings.baudRate, 115200);
      expect(settings.refreshFps, 60);
      expect(settings.plotFontSizeDelta, 0);
      expect(settings.plotFontBold, isFalse);
      expect(settings.lastMainPage, 'rawData');
      expect(settings.maxVisiblePoints, 1000000);
      expect(settings.plotHistoryMemoryLimitGiB, 2);
      expect(settings.discardInitialPacketCount, 0);
      expect(settings.keepPlotOnRestart, isFalse);
      expect(settings.snapHighlightEnabled, isTrue);
      expect(settings.snapHighlightDiameter, 8);
      expect(settings.snapHighlightColorMode, 'cursor');
      expect(settings.xMeasurementLine1Color, isNull);
      expect(settings.xMeasurementLine2Color, isNull);
      expect(settings.yMeasurementLine1Color, isNull);
      expect(settings.yMeasurementLine2Color, isNull);
      expect(settings.xMeasurementLine1Opacity, 1);
      expect(settings.xMeasurementLine2Opacity, 1);
      expect(settings.yMeasurementLine1Opacity, 1);
      expect(settings.yMeasurementLine2Opacity, 1);
      expect(settings.yMeasurementSnapEnabled, isTrue);
      expect(settings.statsToolbarEnabled, isFalse);
      expect(settings.triggerToolbarEnabled, isFalse);
      expect(settings.previewToolbarEnabled, isFalse);
      expect(settings.plotReceiveAggregationEnabled, isFalse);
      expect(settings.plotLodQuality, 'performance');
      expect(settings.showGrid, isTrue);
      expect(settings.gridDensity, 'normal');
      expect(settings.plotBackground, 'dark');
      expect(settings.floatingPanelOpacity, 0.85);
      expect(settings.plotLegendPanelRight, isNull);
      expect(settings.plotLegendPanelTop, isNull);
      expect(settings.plotLiveValuesPanelRight, isNull);
      expect(settings.plotLiveValuesPanelTop, isNull);
      expect(settings.observationClickToPlace, isFalse);
      expect(settings.useRandomSource, isFalse);
      expect(settings.randomFrequency, 1000);
      expect(settings.followEnabled, isFalse);
      expect(settings.followPositionRatio, 0.9);
      expect(settings.yFitDisplayRatio, 0.8);
      expect(settings.parserType, 'zobow');
      expect(settings.sendProtocolType, 'none');
      expect(settings.receiveCustomProtocolId, isEmpty);
      expect(settings.sendCustomProtocolId, isEmpty);
      expect(settings.rChannelAddresses, List.filled(16, ''));
      expect(settings.rProtocolLooseChannelSettings, isFalse);
      expect(settings.justFloatChannelCount, 0);
      expect(settings.zobowProfileId, isEmpty);
      expect(settings.rProfileId, isEmpty);
      expect(settings.zobowPresetViewMode, 'grid');
      expect(settings.autoUpdateCheckEnabled, isFalse);
      expect(settings.updateChannel, 'stable');
      expect(settings.updateSource, 'auto');
      expect(settings.disableNotifications, isFalse);
      expect(settings.diagnosticLoggingEnabled, isFalse);
      expect(settings.rawDataDisplayLineLimit, 100000);
      expect(settings.rawDataAutoLineBreakIntervalMs, 100);
      expect(settings.rawDataShellMode, isFalse);
      expect(settings.rawDataShellEnabled, isFalse);
      expect(settings.rawDataShellInputMode, 'line');
      expect(settings.rawDataTerminalFontSize, 13);
      expect(settings.rawDataTerminalFontFamily, 'Consolas');
      expect(settings.rawDataShellTheme, 'light');
      expect(settings.rawDataShellCursor, 'verticalBar');
      expect(settings.shellEncoding, 'UTF-8');
      expect(settings.shellLineEnding, '\r\n');
      expect(settings.shellLocalEcho, isTrue);
      expect(settings.shellScrollbackLines, 10000);
      expect(settings.ymodemSaveDirectoryPolicy, 'exports');
      expect(settings.rawMultiSendProfileId, isEmpty);
      expect(settings.rttPageEnabled, isFalse);
      expect(settings.rttBackendMode, 'automatic');
      expect(settings.rttJlinkExecutablePath, isEmpty);
      expect(settings.rttPyocdExecutablePath, isEmpty);
      expect(settings.rttBuiltinHelperPath, isEmpty);
      expect(settings.rttProbeKind, 'jlink');
      expect(settings.rttLastProbeId, isEmpty);
      expect(settings.rttTarget, isEmpty);
      expect(settings.rttAutoDetectTarget, isFalse);
      expect(settings.rttWireProtocol, 'swd');
      expect(settings.rttClockKhz, 4000);
      expect(settings.rttControlBlockMode, 'automatic');
      expect(settings.rttControlBlockAddress, isNull);
      expect(settings.rttControlBlockRangeStart, isNull);
      expect(settings.rttControlBlockRangeEnd, isNull);
      expect(settings.rttEncoding, 'UTF-8');
      expect(settings.rttDisplayMode, 'text');
      expect(settings.rttTimestampEnabled, isFalse);
      expect(settings.rttAutoScroll, isTrue);
      expect(settings.rttFontFamily, 'Consolas');
      expect(settings.rttFontSize, 13);
      expect(settings.rttHistoryLineLimit, 100000);
      expect(settings.xMin, 0);
      expect(settings.xMax, 1000);
      expect(settings.yMin, 0);
      expect(settings.yMax, 32768);
    },
  );

  group('AppSettings file persistence', () {
    late Directory temporaryDirectory;
    late String settingsPath;
    final settings = AppSettings();

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'vscope_settings_test_',
      );
      settingsPath = '${temporaryDirectory.path}/settings.json';
      await settings.debugInitializeAt(settingsPath);
    });

    tearDown(() async {
      await settings.debugDetach();
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('连续保存合并后写入完整的最新快照', () async {
      settings.baudRate = 9600;
      final first = settings.save();
      settings.dataBits = 7;
      final second = settings.save();
      settings.lastMainPage = 'plot';
      settings.diagnosticLoggingEnabled = true;
      settings.xMeasurementLine1Color = 0xFF123456;
      settings.yMeasurementLine2Opacity = 0.45;
      settings.yMeasurementSnapEnabled = false;
      final third = settings.save();

      await Future.wait([first, second, third]);
      await settings.flushPendingSave();
      final decoded = jsonDecode(await File(settingsPath).readAsString());

      expect(decoded['baudRate'], 9600);
      expect(decoded['dataBits'], 7);
      expect(decoded['lastMainPage'], 'plot');
      expect(decoded['diagnosticLoggingEnabled'], isTrue);
      expect(decoded['xMeasurementLine1Color'], 0xFF123456);
      expect(decoded['yMeasurementLine2Opacity'], 0.45);
      expect(decoded['yMeasurementSnapEnabled'], isFalse);
    });

    test('截断主文件后自动恢复上一代备份', () async {
      settings.baudRate = 9600;
      await settings.save();
      settings.baudRate = 57600;
      await settings.save();
      await File(settingsPath).writeAsString('{"baudRate":');

      await settings.debugInitializeAt(settingsPath);

      expect(settings.baudRate, 9600);
      expect(settings.takeRecoveryNotice(), isNotNull);
      expect(jsonDecode(await File(settingsPath).readAsString()), isA<Map>());
    });

    test('字段类型错误时不应用半套设置并恢复备份', () async {
      settings
        ..baudRate = 19200
        ..lastMainPage = 'shell';
      await settings.save();
      settings
        ..baudRate = 38400
        ..lastMainPage = 'plot';
      await settings.save();
      await File(settingsPath).writeAsString(
        jsonEncode({'baudRate': 'invalid', 'lastMainPage': 'plot'}),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.baudRate, 19200);
      expect(settings.lastMainPage, 'shell');
    });

    test('RTT 设置可保存并从严格校验的快照恢复', () async {
      settings
        ..rttPageEnabled = true
        ..rttBackendMode = 'builtin'
        ..rttProbeKind = 'cmsisDap'
        ..rttAutoDetectTarget = true
        ..rttClockKhz = 8000
        ..rttControlBlockMode = 'range'
        ..rttControlBlockRangeStart = 0x20000000
        ..rttControlBlockRangeEnd = 0x20010000
        ..rttTimestampEnabled = true
        ..rttAutoScroll = false
        ..rttFontSize = 15
        ..rttHistoryLineLimit = 200000;
      await settings.save();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.rttPageEnabled, isTrue);
      expect(settings.rttBackendMode, 'builtin');
      expect(settings.rttProbeKind, 'cmsisDap');
      expect(settings.rttAutoDetectTarget, isTrue);
      expect(settings.rttClockKhz, 8000);
      expect(settings.rttControlBlockMode, 'range');
      expect(settings.rttControlBlockRangeStart, 0x20000000);
      expect(settings.rttControlBlockRangeEnd, 0x20010000);
      expect(settings.rttTimestampEnabled, isTrue);
      expect(settings.rttAutoScroll, isFalse);
      expect(settings.rttFontSize, 15);
      expect(settings.rttHistoryLineLimit, 200000);
    });

    test('旧版 RTT 控制块地址迁移为指定地址模式', () async {
      await File(
        settingsPath,
      ).writeAsString(jsonEncode({'rttControlBlockAddress': 0x20001000}));

      await settings.debugInitializeAt(settingsPath);

      expect(settings.rttControlBlockMode, 'address');
      expect(settings.rttControlBlockAddress, 0x20001000);
    });
  });
}
