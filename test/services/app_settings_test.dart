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
            ..maxVisiblePoints = 40000000
            ..discardInitialPacketCount = 8
            ..snapHighlightEnabled = false
            ..snapHighlightDiameter = 12
            ..showGrid = false
            ..gridDensity = 'dense'
            ..useRandomSource = true
            ..randomFrequency = 500
            ..followEnabled = true
            ..parserType = 'zobow'
            ..sendProtocolType = 'rProtocol'
            ..receiveCustomProtocolId = 'receive'
            ..sendCustomProtocolId = 'send'
            ..rChannelAddresses = List.filled(16, '0x10')
            ..justFloatChannelCount = 8
            ..zobowProfileId = 'z-profile'
            ..rProfileId = 'r-profile'
            ..zobowPresetViewMode = 'list'
            ..autoUpdateCheckEnabled = true
            ..updateChannel = 'beta'
            ..disableNotifications = true
            ..rawDataDisplayLineLimit = 500
            ..rawDataShellMode = true
            ..rawDataShellEnabled = true
            ..rawDataShellInputMode = 'key'
            ..rawDataTerminalFontSize = 20
            ..rawDataTerminalFontFamily = 'Courier New'
            ..rawDataShellTheme = 'dark'
            ..rawDataShellCursor = 'block'
            ..ymodemSaveDirectoryPolicy = 'custom'
            ..xMin = 10
            ..xMax = 20
            ..yMin = 30
            ..yMax = 40;

      await settings.resetToDefaults();

      expect(settings.lastPort, isNull);
      expect(settings.baudRate, 115200);
      expect(settings.refreshFps, 60);
      expect(settings.plotFontSizeDelta, 0);
      expect(settings.maxVisiblePoints, 1000000);
      expect(settings.discardInitialPacketCount, 0);
      expect(settings.snapHighlightEnabled, isTrue);
      expect(settings.snapHighlightDiameter, 8);
      expect(settings.showGrid, isTrue);
      expect(settings.gridDensity, 'normal');
      expect(settings.useRandomSource, isFalse);
      expect(settings.randomFrequency, 1000);
      expect(settings.followEnabled, isFalse);
      expect(settings.parserType, 'fireWater');
      expect(settings.sendProtocolType, 'none');
      expect(settings.receiveCustomProtocolId, isEmpty);
      expect(settings.sendCustomProtocolId, isEmpty);
      expect(settings.rChannelAddresses, List.filled(16, ''));
      expect(settings.justFloatChannelCount, 0);
      expect(settings.zobowProfileId, isEmpty);
      expect(settings.rProfileId, isEmpty);
      expect(settings.zobowPresetViewMode, 'grid');
      expect(settings.autoUpdateCheckEnabled, isFalse);
      expect(settings.updateChannel, 'stable');
      expect(settings.disableNotifications, isFalse);
      expect(settings.rawDataDisplayLineLimit, 10000);
      expect(settings.rawDataShellMode, isFalse);
      expect(settings.rawDataShellEnabled, isFalse);
      expect(settings.rawDataShellInputMode, 'line');
      expect(settings.rawDataTerminalFontSize, 13);
      expect(settings.rawDataTerminalFontFamily, 'Consolas');
      expect(settings.rawDataShellTheme, 'light');
      expect(settings.rawDataShellCursor, 'verticalBar');
      expect(settings.ymodemSaveDirectoryPolicy, 'exports');
      expect(settings.xMin, 0);
      expect(settings.xMax, 1000);
      expect(settings.yMin, 0);
      expect(settings.yMax, 32768);
    },
  );
}
