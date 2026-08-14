import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/constants/rtt_configuration.dart';
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
            ..mainTabOrder = const [
              'plot',
              'rawData',
              'shell',
              'rtt',
              'probePlot',
            ]
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
            ..plotRenderEngine = 'd3d11'
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
            ..probePlotWindowPointLimit = 200000
            ..probePlotHistoryMemoryLimitMiB = 1024
            ..probePlotLodQuality = 'balanced'
            ..probePlotShowGrid = false
            ..probePlotGridDensity = 'dense'
            ..probePlotBackground = 'dark'
            ..probePlotFloatingPanelOpacity = 0.4
            ..probePlotFontSizeDelta = 5
            ..probePlotFontBold = true
            ..probePlotFollowPositionRatio = 0.6
            ..probePlotObservationClickToPlace = true
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
            ..connectionShortcutsEnabled = false
            ..crashDumpEnabled = false
            ..rawDataDisplayLineLimit = 500
            ..rawDataAutoLineBreakIntervalMs = 250
            ..rawDataShellInputMode = 'key'
            ..rawDataTerminalFontSize = 20
            ..rawDataTerminalFontFamily = 'Courier New'
            ..rawDataShellTheme = 'dark'
            ..rawDataShellCursor = 'block'
            ..shellEncoding = 'GBK'
            ..shellLineEnding = '\n'
            ..shellLocalEcho = false
            ..shellScrollbackLines = 50000
            ..sshKeepAliveEnabled = false
            ..ymodemSaveDirectoryPolicy = 'custom'
            ..rawMultiSendProfileId = 'multi-send'
            ..rttBackendSelection = 'external-openocd'
            ..rttJlinkExecutablePath = 'jlink.exe'
            ..rttOpenocdExecutablePath = 'openocd.exe'
            ..rttPyocdPythonPath = 'python.exe'
            ..rttPyocdCmsisDapVersion = 'v2'
            ..rttBuiltinHelperPath = 'helper.exe'
            ..rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg'
            ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg'
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
            ..rttViewerPollingIntervalMs = 250
            ..probeRttPollingIntervalMs = 500
            ..rttEncoding = 'GBK'
            ..rttDisplayMode = 'hex'
            ..rttTimestampEnabled = true
            ..rttAutoScroll = false
            ..rttFontFamily = 'Courier New'
            ..rttFontSize = 18
            ..rttHistoryLineLimit = 200000
            ..rttTerminalColors = [0xFF123456]
            ..rttTerminalLabels = ['旧标注']
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
      expect(settings.mainTabOrder, ['rawData', 'plot']);
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
      expect(settings.plotLodQuality, 'balanced');
      expect(settings.plotRenderEngine, 'd3d11');
      expect(settings.plotRenderEngineDefaultApplied, isTrue);
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
      expect(settings.probePlotWindowPointLimit, 100000);
      expect(settings.probePlotHistoryMemoryLimitMiB, 256);
      expect(settings.probePlotLodQuality, 'balanced');
      expect(settings.probePlotShowGrid, isTrue);
      expect(settings.probePlotGridDensity, 'normal');
      expect(settings.probePlotBackground, 'light');
      expect(settings.probePlotFloatingPanelOpacity, 0.9);
      expect(settings.probePlotFontSizeDelta, 0);
      expect(settings.probePlotFontBold, isFalse);
      expect(settings.probePlotFollowPositionRatio, 0.9);
      expect(settings.probePlotObservationClickToPlace, isFalse);
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
      expect(settings.connectionShortcutsEnabled, isTrue);
      expect(settings.crashDumpEnabled, isTrue);
      expect(settings.rawDataDisplayLineLimit, 100000);
      expect(settings.rawDataAutoLineBreakIntervalMs, 100);
      expect(settings.rawDataShellInputMode, 'line');
      expect(settings.rawDataTerminalFontSize, 13);
      expect(settings.rawDataTerminalFontFamily, 'Consolas');
      expect(settings.rawDataShellTheme, 'light');
      expect(settings.rawDataShellCursor, 'verticalBar');
      expect(settings.shellEncoding, 'UTF-8');
      expect(settings.shellLineEnding, '\r');
      expect(settings.shellLocalEcho, isFalse);
      expect(settings.shellScrollbackLines, 10000);
      expect(settings.sshKeepAliveEnabled, isTrue);
      expect(settings.ymodemSaveDirectoryPolicy, 'exports');
      expect(settings.rawMultiSendProfileId, isEmpty);
      expect(settings.rttBackendSelection, 'automatic');
      expect(settings.rttJlinkExecutablePath, isEmpty);
      expect(settings.rttOpenocdExecutablePath, isEmpty);
      expect(settings.rttPyocdPythonPath, isEmpty);
      expect(settings.rttPyocdCmsisDapVersion, 'automatic');
      expect(settings.rttBuiltinHelperPath, isEmpty);
      expect(settings.rttOpenocdInterfaceConfig, 'interface/cmsis-dap.cfg');
      expect(settings.rttOpenocdTargetConfig, isEmpty);
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
      expect(settings.rttViewerPollingIntervalMs, 10);
      expect(settings.probeRttPollingIntervalMs, 10);
      expect(settings.rttEncoding, 'UTF-8');
      expect(settings.rttDisplayMode, 'text');
      expect(settings.rttTimestampEnabled, isFalse);
      expect(settings.rttAutoScroll, isTrue);
      expect(settings.rttFontFamily, 'Consolas');
      expect(settings.rttFontSize, 13);
      expect(settings.rttHistoryLineLimit, 100000);
      expect(
        settings.rttTerminalColors,
        RttConfiguration.defaultTerminalColors,
      );
      expect(
        settings.rttTerminalLabels,
        RttConfiguration.defaultTerminalLabels,
      );
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

    test('新配置的串口与探针绘图质量默认使用均衡且启用D3D11', () {
      expect(settings.plotLodQuality, 'balanced');
      expect(settings.probePlotLodQuality, 'balanced');
      expect(settings.plotRenderEngine, 'd3d11');
      expect(settings.plotRenderEngineDefaultApplied, isTrue);
    });

    test('串口绘图目标刷新率可持久化到120并限制越界值', () async {
      settings.refreshFps = 120;
      await settings.save();
      await settings.flushPendingSave();
      await settings.debugInitializeAt(settingsPath);
      expect(settings.refreshFps, 120);

      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'performance': {'refreshFps': 240},
          },
        }),
      );
      await settings.debugInitializeAt(settingsPath);
      expect(settings.refreshFps, 120);
    });

    test('串口绘图引擎可持久化D3D11且无效值回退D3D11', () async {
      settings.plotRenderEngine = 'd3d11';
      await settings.save();
      await settings.flushPendingSave();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotRenderEngine, 'd3d11');
      final decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final serialPlot = decoded['serialPlot'] as Map<String, dynamic>;
      final performance = serialPlot['performance'] as Map<String, dynamic>;
      expect(performance['renderEngine'], 'd3d11');
      expect(performance['renderEngineDefaultApplied'], isTrue);

      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'performance': {'renderEngine': 'unknown'},
          },
        }),
      );
      await settings.debugInitializeAt(settingsPath);
      expect(settings.plotRenderEngine, 'd3d11');
    });

    test('旧用户首次升级强制迁移D3D11，之后手动选择Canvas保持不变', () async {
      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'performance': {'renderEngine': 'canvas'},
          },
        }),
      );

      await settings.debugInitializeAt(settingsPath);
      await settings.flushPendingSave();
      expect(settings.plotRenderEngine, 'd3d11');
      expect(settings.plotRenderEngineDefaultApplied, isTrue);

      var decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      var performance =
          (decoded['serialPlot'] as Map<String, dynamic>)['performance']
              as Map<String, dynamic>;
      expect(performance['renderEngine'], 'd3d11');
      expect(performance['renderEngineDefaultApplied'], isTrue);

      settings.plotRenderEngine = 'canvas';
      await settings.save();
      await settings.flushPendingSave();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotRenderEngine, 'canvas');
      expect(settings.plotRenderEngineDefaultApplied, isTrue);

      decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      performance =
          (decoded['serialPlot'] as Map<String, dynamic>)['performance']
              as Map<String, dynamic>;
      expect(performance['renderEngine'], 'canvas');
      expect(performance['renderEngineDefaultApplied'], isTrue);
    });

    test('串口绘图缩放修饰键默认Shift并持久化Ctrl选择', () async {
      expect(settings.plotGestureModifier, 'shift');

      settings.plotGestureModifier = 'control';
      await settings.save();
      await settings.flushPendingSave();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotGestureModifier, 'control');
      final decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final serialPlot = decoded['serialPlot'] as Map<String, dynamic>;
      final interaction = serialPlot['interaction'] as Map<String, dynamic>;
      expect(interaction['zoomModifier'], 'control');
    });

    test('无效的串口绘图缩放修饰键回退为Shift', () async {
      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'interaction': {'zoomModifier': 'alt'},
          },
        }),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotGestureModifier, 'shift');
    });

    test('串口绘图发送默认显示在数据收发并可持久化关闭', () async {
      expect(settings.showPlotSendDataInRaw, isTrue);

      settings.showPlotSendDataInRaw = false;
      await settings.save();
      await settings.flushPendingSave();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.showPlotSendDataInRaw, isFalse);
      final decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final serialPlot = decoded['serialPlot'] as Map<String, dynamic>;
      final interaction = serialPlot['interaction'] as Map<String, dynamic>;
      expect(interaction['showSentDataInRaw'], isFalse);
    });

    test('已有配置保留用户选择的绘图质量', () async {
      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'performance': {'lodQuality': 'performance'},
          },
          'probePlot': {
            'performance': {'lodQuality': 'quality'},
          },
        }),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotLodQuality, 'performance');
      expect(settings.probePlotLodQuality, 'quality');
    });

    test('旧配置未记录串口绘图质量时迁移并写回均衡', () async {
      for (final legacyValue in <Object?>[null, '']) {
        await File(settingsPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 2,
            'serialPlot': {
              'performance': {
                'renderEngine': 'd3d11',
                'renderEngineDefaultApplied': true,
              },
            },
          }),
        );
        if (legacyValue != null) {
          final decoded =
              jsonDecode(await File(settingsPath).readAsString())
                  as Map<String, dynamic>;
          final performance =
              (decoded['serialPlot'] as Map<String, dynamic>)['performance']
                  as Map<String, dynamic>;
          performance['lodQuality'] = legacyValue;
          await File(
            settingsPath,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(decoded));
        }

        await settings.debugInitializeAt(settingsPath);
        await settings.flushPendingSave();

        expect(settings.plotLodQuality, 'balanced');
        final migrated =
            jsonDecode(await File(settingsPath).readAsString())
                as Map<String, dynamic>;
        final performance =
            (migrated['serialPlot'] as Map<String, dynamic>)['performance']
                as Map<String, dynamic>;
        expect(performance['lodQuality'], 'balanced');
      }
    });

    test('连续保存合并后写入完整的最新快照', () async {
      settings.baudRate = 9600;
      final first = settings.save();
      settings.dataBits = 7;
      final second = settings.save();
      settings.lastMainPage = 'plot';
      settings.diagnosticLoggingEnabled = true;
      settings.connectionShortcutsEnabled = false;
      settings.crashDumpEnabled = false;
      settings.xMeasurementLine1Color = 0xFF123456;
      settings.yMeasurementLine2Opacity = 0.45;
      settings.yMeasurementSnapEnabled = false;
      settings.xMultiMeasurementEnabled = true;
      settings.yMultiMeasurementEnabled = true;
      settings.mainTabOrder = const [
        'plot',
        'rawData',
        'shell',
        'rtt',
        'probePlot',
      ];
      settings.probePlotWindowPointLimit = 180000;
      settings.probePlotHistoryMemoryLimitMiB = 512;
      settings.probePlotLodQuality = 'balanced';
      settings.probePlotBackground = 'dark';
      final third = settings.save();

      await Future.wait([first, second, third]);
      await settings.flushPendingSave();
      final decoded =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final global = decoded['global'] as Map<String, dynamic>;
      final navigation = global['navigation'] as Map<String, dynamic>;
      final behavior = global['behavior'] as Map<String, dynamic>;
      final serial = decoded['serial'] as Map<String, dynamic>;
      final serialPlot = decoded['serialPlot'] as Map<String, dynamic>;
      final serialPlotInteraction =
          serialPlot['interaction'] as Map<String, dynamic>;
      final connection = serial['connection'] as Map<String, dynamic>;
      final measurements = global['plotMeasurements'] as Map<String, dynamic>;
      final deltaX = measurements['deltaX'] as Map<String, dynamic>;
      final deltaY = measurements['deltaY'] as Map<String, dynamic>;
      final probePlot = decoded['probePlot'] as Map<String, dynamic>;
      final probePerformance = probePlot['performance'] as Map<String, dynamic>;
      final probeAppearance = probePlot['appearance'] as Map<String, dynamic>;

      expect(decoded['schemaVersion'], 2);
      expect(decoded.keys.take(3), ['schemaVersion', 'global', 'serial']);
      expect(decoded.containsKey('baudRate'), isFalse);
      expect(decoded.containsKey('probePlotBackground'), isFalse);
      expect(connection['baudRate'], 9600);
      expect(connection['dataBits'], 7);
      expect(navigation['lastPage'], 'plot');
      expect(behavior['diagnosticLogging'], isTrue);
      expect(behavior['connectionShortcuts'], isFalse);
      expect(behavior['crashDump'], isFalse);
      expect(deltaX['line1Color'], 0xFF123456);
      expect(deltaY['line2Opacity'], 0.45);
      expect(deltaY['snapEnabled'], isFalse);
      expect(serialPlotInteraction['deltaXMultiMeasurement'], isTrue);
      expect(serialPlotInteraction['deltaYMultiMeasurement'], isTrue);
      expect(navigation['pageOrder'], [
        'plot',
        'rawData',
        'shell',
        'rtt',
        'probePlot',
      ]);
      expect(probePerformance['windowPointLimit'], 180000);
      expect(probePerformance['historyMemoryLimitMiB'], 512);
      expect(probePerformance['lodQuality'], 'balanced');
      expect(probeAppearance['background'], 'dark');
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

    test('嵌套分组类型错误时恢复上一代完整配置', () async {
      settings.baudRate = 9600;
      await settings.save();
      settings.baudRate = 57600;
      await settings.save();
      await File(
        settingsPath,
      ).writeAsString(jsonEncode({'schemaVersion': 2, 'serial': 'invalid'}));

      await settings.debugInitializeAt(settingsPath);

      expect(settings.baudRate, 9600);
      expect(settings.takeRecoveryNotice(), isNotNull);
    });

    test('RTT 设置可保存并从严格校验的快照恢复', () async {
      settings
        ..rttBackendSelection = 'bundled-openocd'
        ..rttOpenocdExecutablePath = 'openocd.exe'
        ..rttPyocdPythonPath = 'python.exe'
        ..rttPyocdCmsisDapVersion = 'v2'
        ..rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg'
        ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg'
        ..rttProbeKind = 'cmsisDap'
        ..rttAutoDetectTarget = true
        ..rttClockKhz = 8000
        ..rttControlBlockMode = 'range'
        ..rttControlBlockRangeStart = 0x20000000
        ..rttControlBlockRangeEnd = 0x20010000
        ..rttViewerPollingIntervalMs = 25
        ..probeRttPollingIntervalMs = 40
        ..rttTimestampEnabled = true
        ..rttAutoScroll = false
        ..rttFontSize = 15
        ..rttHistoryLineLimit = 200000
        ..rttTerminalColors = List.generate(16, (index) => 0xFF000000 | index)
        ..rttTerminalLabels = List.generate(16, (index) => '通道 $index');
      await settings.save();
      await settings.debugInitializeAt(settingsPath);

      expect(settings.rttBackendSelection, 'bundled-openocd');
      expect(settings.rttOpenocdExecutablePath, 'openocd.exe');
      expect(settings.rttPyocdPythonPath, 'python.exe');
      expect(settings.rttPyocdCmsisDapVersion, 'v2');
      expect(settings.rttOpenocdInterfaceConfig, 'interface/cmsis-dap.cfg');
      expect(settings.rttOpenocdTargetConfig, 'target/stm32f4x.cfg');
      expect(settings.rttProbeKind, 'cmsisDap');
      expect(settings.rttAutoDetectTarget, isTrue);
      expect(settings.rttClockKhz, 8000);
      expect(settings.rttControlBlockMode, 'range');
      expect(settings.rttControlBlockRangeStart, 0x20000000);
      expect(settings.rttControlBlockRangeEnd, 0x20010000);
      expect(settings.rttViewerPollingIntervalMs, 25);
      expect(settings.probeRttPollingIntervalMs, 40);
      expect(settings.rttTimestampEnabled, isTrue);
      expect(settings.rttAutoScroll, isFalse);
      expect(settings.rttFontSize, 15);
      expect(settings.rttHistoryLineLimit, 200000);
      expect(
        settings.rttTerminalColors,
        List.generate(16, (index) => 0xFF000000 | index),
      );
      expect(
        settings.rttTerminalLabels,
        List.generate(16, (index) => '通道 $index'),
      );
    });

    test('旧版 RTT 控制块地址迁移为指定地址模式', () async {
      await File(
        settingsPath,
      ).writeAsString(jsonEncode({'rttControlBlockAddress': 0x20001000}));

      await settings.debugInitializeAt(settingsPath);

      expect(settings.rttControlBlockMode, 'address');
      expect(settings.rttControlBlockAddress, 0x20001000);
      final migrated =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      expect(migrated['schemaVersion'], 2);
      expect(migrated.containsKey('rttControlBlockAddress'), isFalse);
      expect(
        ((migrated['rtt'] as Map<String, dynamic>)['controlBlock']
            as Map<String, dynamic>)['address'],
        0x20001000,
      );
    });

    test('旧版标签顺序加载后移除已关闭页面', () async {
      await File(settingsPath).writeAsString(
        jsonEncode({
          'mainTabOrder': ['shell', 'plot', 'rawData', 'rtt', 'probePlot'],
          'visibleMainPages': ['plot', 'rtt'],
        }),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.visibleMainPages, ['plot', 'rtt']);
      expect(settings.mainTabOrder, ['plot', 'rtt']);
    });

    test('旧版页面开关只用于迁移且保存后不再输出遗留字段', () async {
      await File(settingsPath).writeAsString(
        jsonEncode({
          'rawDataShellMode': true,
          'rawDataShellEnabled': true,
          'rttPageEnabled': true,
        }),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.visibleMainPages, [
        'rawData',
        'shell',
        'plot',
        'rtt',
        'probePlot',
      ]);
      final migrated =
          jsonDecode(await File(settingsPath).readAsString())
              as Map<String, dynamic>;
      final navigation =
          (migrated['global'] as Map<String, dynamic>)['navigation']
              as Map<String, dynamic>;
      expect(navigation.containsKey('shellPageEnabled'), isFalse);
      expect(navigation.containsKey('probePagesEnabled'), isFalse);
      expect((migrated['rawData'] as Map).containsKey('legacyShell'), isFalse);
    });

    test('嵌套格式可严格校验并完整恢复不同功能的同名设置', () async {
      await File(settingsPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 2,
          'serialPlot': {
            'appearance': {'background': 'dark', 'showGrid': false},
          },
          'probePlot': {
            'appearance': {'background': 'light', 'showGrid': true},
            'performance': {
              'windowPointLimit': 120000,
              'historyMemoryLimitMiB': 384,
              'lodQuality': 'quality',
            },
          },
        }),
      );

      await settings.debugInitializeAt(settingsPath);

      expect(settings.plotBackground, 'dark');
      expect(settings.showGrid, isFalse);
      expect(settings.probePlotBackground, 'light');
      expect(settings.probePlotShowGrid, isTrue);
      expect(settings.probePlotWindowPointLimit, 120000);
      expect(settings.probePlotHistoryMemoryLimitMiB, 384);
    });
  });
}
