import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/serial_config.dart';
import '../../services/app_info.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/crash_dump_service.dart';
import '../../services/data_connection_service.dart';
import '../../services/modbus_client_service.dart';
import '../../services/native_serial_reader.dart';
import '../../services/probe_connection_service.dart';
import '../../services/ssh_connection_service.dart';
import '../../services/changelog_service.dart';
import '../../services/raw_receive_session.dart';
import '../../services/shell_receive_queue.dart';
import '../../services/update_checker.dart';
import '../../services/update_service.dart';
import '../../services/ymodem_service.dart';
import 'app_info_actions.dart';

/// 应用信息对话框的组合根：用真实服务装配 [AppInfoDialogActions]。
///
/// 这里集中了对话框所需的全部具体服务依赖；[AppInfoDialog] 内部只使用
/// [AppInfoDialogActions] 暴露的窄接口，从而可脱离具体服务独立构造与测试。
AppInfoDialogActions buildAppInfoDialogActions(BuildContext context) {
  final settings = AppSettings();
  // DataConnectionService 与 ProbeConnectionService 均为全局/Provider 单例，
  // 组合根一次性捕获，回调随后读取它们的实时状态。
  final dataService = context.read<DataConnectionService>();
  final probeService = context.read<ProbeConnectionService>();
  final modbusService = context.read<ModbusClientService?>();
  final sshService = context.read<SshConnectionService?>();
  // UpdateService 不是单例：下载与取消依赖同一实例的 generation 计数，
  // 更新/回退安装也共享同一运行时锁，因此必须在这里复用一个实例。
  final updateService = UpdateService();

  return AppInfoDialogActions(
    appInfo: AppInfoActions(
      appName: AppInfo.name,
      displayVersion: AppInfo.displayVersion,
      buildTime: AppInfo.buildTime,
      loadChangelog:
          (version) => ChangelogService().currentAndPrevious(version),
      parseChangelogBody: ChangelogService.parseBody,
    ),
    update: UpdateActions(
      checkForUpdate:
          (channel, source) => UpdateChecker().check(
            channel: channel,
            source: source.releaseSource,
          ),
      findPreparedUpdate:
          updateService.findPreparedUpdate,
      downloadAndPrepare:
          updateService.downloadAndPrepare,
      cancelDownload: updateService.cancelDownload,
      launchInstaller: updateService.launchInstaller,
      findRollbackUpdates: updateService.findRollbackUpdates,
      launchRollbackInstaller:
          updateService.launchRollbackInstaller,
      findOtherRunningInstanceProcessIds:
          updateService.findOtherRunningInstanceProcessIds,
      requestCloseOtherRunningInstances:
          updateService.requestCloseOtherRunningInstances,
      waitForOtherRunningInstancesToExit:
          updateService.waitForOtherRunningInstancesToExit,
    ),
    probeDetection: ProbeDetectionActions(
      checkBackendAvailability:
          ({bool? prepareBundledOpenOcd}) =>
              probeService.checkBackendAvailability(
                prepareBundledOpenOcd: prepareBundledOpenOcd ?? true,
              ),
      queuedBytes: () => probeService.queuedBytes,
    ),
    crashDump: CrashDumpActions(
      setEnabled: (enabled) => CrashDumpService().setEnabled(enabled),
      triggerTestCrash: NativeSerialReader.triggerTestCrash,
    ),
    dataConnection: DataConnectionActions(
      isConnectionBusy: () => dataService.isConnectionBusy,
      isNetworkConnection: () => dataService.isNetworkConnection,
      setNetworkConnectionsEnabled:
          dataService.setNetworkConnectionsEnabled,
      selectSerialProfile:
          (pageId, {forceReload}) => dataService.selectSerialProfile(
            pageId,
            forceReload: forceReload ?? false,
          ),
      rawRetentionUsedBytes: () => dataService.rawRetentionUsage.usedBytes,
      rawTextCacheUsedBytes: () => dataService.rawTextDisplayCacheBytes,
      shellQueueUsedBytes: () => dataService.shellPendingReceiveBytes,
      ymodemQueueUsedBytes: () => dataService.ymodemService.incomingBytes,
    ),
    settings: _AppSettingsActions(settings),
    memoryLimits: const MemoryLimits(
      rawRetentionLimitBytes: RawReceiveSession.rawRetentionLimitBytes,
      rawTextCacheLimitBytes: RawReceiveSession.textDisplayCacheLimitBytes,
      shellQueueLimitBytes: ShellReceiveQueue.defaultMaxBytes,
      ymodemQueueLimitBytes: YmodemService.defaultInputHighWaterBytes,
    ),
    showNotification:
        AppNotifications.show,
    modbus:
        modbusService == null
            ? null
            : ModbusActions(
              mode: () => modbusService.mode,
              setMode: modbusService.setMode,
            ),
    sshStatus:
        sshService == null
            ? null
            : SshStatusActions(
              isConnected: () => sshService.isConnected,
              isConnecting: () => sshService.isConnecting,
            ),
  );
}

/// 把 [SettingsActions] 窄接口委托给真实 [AppSettings] 单例。
class _AppSettingsActions implements SettingsActions {
  _AppSettingsActions(this._settings);

  final AppSettings _settings;

  @override
  int get plotHistoryMemoryLimitGiB => _settings.plotHistoryMemoryLimitGiB;
  @override
  set plotHistoryMemoryLimitGiB(int value) =>
      _settings.plotHistoryMemoryLimitGiB = value;

  @override
  String get rttJlinkExecutablePath => _settings.rttJlinkExecutablePath;
  @override
  set rttJlinkExecutablePath(String value) =>
      _settings.rttJlinkExecutablePath = value;
  @override
  String get rttOpenocdExecutablePath => _settings.rttOpenocdExecutablePath;
  @override
  set rttOpenocdExecutablePath(String value) =>
      _settings.rttOpenocdExecutablePath = value;
  @override
  String get rttPyocdPythonPath => _settings.rttPyocdPythonPath;
  @override
  set rttPyocdPythonPath(String value) => _settings.rttPyocdPythonPath = value;

  @override
  bool get autoUpdateCheckEnabled => _settings.autoUpdateCheckEnabled;
  @override
  set autoUpdateCheckEnabled(bool value) =>
      _settings.autoUpdateCheckEnabled = value;
  @override
  bool get disableNotifications => _settings.disableNotifications;
  @override
  set disableNotifications(bool value) =>
      _settings.disableNotifications = value;
  @override
  bool get diagnosticLoggingEnabled => _settings.diagnosticLoggingEnabled;
  @override
  set diagnosticLoggingEnabled(bool value) =>
      _settings.diagnosticLoggingEnabled = value;
  @override
  bool get crashDumpEnabled => _settings.crashDumpEnabled;
  @override
  set crashDumpEnabled(bool value) => _settings.crashDumpEnabled = value;
  @override
  bool get connectionShortcutsEnabled => _settings.connectionShortcutsEnabled;
  @override
  set connectionShortcutsEnabled(bool value) =>
      _settings.connectionShortcutsEnabled = value;
  @override
  bool get networkConnectionsEnabled => _settings.networkConnectionsEnabled;
  @override
  set networkConnectionsEnabled(bool value) =>
      _settings.networkConnectionsEnabled = value;
  @override
  bool get separateSerialProfiles => _settings.separateSerialProfiles;
  @override
  set separateSerialProfiles(bool value) =>
      _settings.separateSerialProfiles = value;

  @override
  String get updateChannel => _settings.updateChannel;
  @override
  set updateChannel(String value) => _settings.updateChannel = value;
  @override
  String get updateSource => _settings.updateSource;
  @override
  set updateSource(String value) => _settings.updateSource = value;

  @override
  Map<String, SerialConfig> get serialPageProfiles =>
      _settings.serialPageProfiles;
  @override
  set serialPageProfiles(Map<String, SerialConfig> value) =>
      _settings.serialPageProfiles = value;

  @override
  void setSeparateSerialProfiles(bool enabled) =>
      _settings.setSeparateSerialProfiles(enabled);

  @override
  Future<void> save() => _settings.save();

  @override
  Future<void> flushPendingSave() => _settings.flushPendingSave();

  @override
  Future<void> resetToDefaults() => _settings.resetToDefaults();
}
