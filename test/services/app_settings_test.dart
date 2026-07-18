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
            ..discardInitialPacketCount = 8
            ..keepPlotOnRestart = true
            ..snapHighlightEnabled = false
            ..snapHighlightDiameter = 12
            ..snapHighlightColorMode = 'channel'
            ..statsToolbarEnabled = true
            ..triggerToolbarEnabled = true
            ..previewToolbarEnabled = true
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
      expect(settings.discardInitialPacketCount, 0);
      expect(settings.keepPlotOnRestart, isFalse);
      expect(settings.snapHighlightEnabled, isTrue);
      expect(settings.snapHighlightDiameter, 8);
      expect(settings.snapHighlightColorMode, 'cursor');
      expect(settings.statsToolbarEnabled, isFalse);
      expect(settings.triggerToolbarEnabled, isFalse);
      expect(settings.previewToolbarEnabled, isFalse);
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
      expect(settings.parserType, 'fireWater');
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
      expect(settings.xMin, 0);
      expect(settings.xMax, 1000);
      expect(settings.yMin, 0);
      expect(settings.yMax, 32768);
    },
  );
}
