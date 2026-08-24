import 'package:flutter/material.dart';

import '../../data/models/modbus_models.dart';
import '../../data/models/serial_config.dart';
import '../../services/changelog_service.dart';
import '../../services/probe_backend.dart';
import '../../services/update_checker.dart';
import '../../services/update_service.dart';

// 纯数据类型重导出：让 app_info_dialog.dart 只依赖本文件的窄接口，
// 同时仍能引用更新/版本说明/探针后端相关数据结构，而不直接 import 服务文件。
export '../../services/changelog_service.dart'
    show ChangelogEntry, ChangelogLine, ChangelogLineType;
export '../../services/probe_backend.dart' show ProbeBackendAvailability;
export '../../services/update_checker.dart'
    show ReleaseInfo, UpdateChannel, UpdateCheckResult, UpdateSourcePreference;
export '../../services/update_service.dart'
    show PreparedUpdate, RollbackUpdate, UpdateDownloadProgress;

/// 应用元信息与版本说明读取能力。
class AppInfoActions {
  const AppInfoActions({
    required this.appName,
    required this.displayVersion,
    required this.buildTime,
    required this.loadChangelog,
    required this.parseChangelogBody,
  });

  final String appName;
  final Future<String> Function() displayVersion;
  final Future<DateTime?> Function() buildTime;

  /// 读取与 [currentVersion] 相邻的最新版本说明。
  final Future<List<ChangelogEntry>> Function(String currentVersion)
  loadChangelog;

  /// 将版本说明正文解析为可展示的行。
  final List<ChangelogLine> Function(String body) parseChangelogBody;
}

/// 更新检查、下载安装与回退能力。
class UpdateActions {
  const UpdateActions({
    required this.checkForUpdate,
    required this.findPreparedUpdate,
    required this.downloadAndPrepare,
    required this.cancelDownload,
    required this.launchInstaller,
    required this.findRollbackUpdates,
    required this.launchRollbackInstaller,
    required this.findOtherRunningInstanceProcessIds,
    required this.requestCloseOtherRunningInstances,
    required this.waitForOtherRunningInstancesToExit,
  });

  final Future<UpdateCheckResult> Function(
    UpdateChannel channel,
    UpdateSourcePreference source,
  )
  checkForUpdate;

  final Future<PreparedUpdate?> Function(ReleaseInfo release)
  findPreparedUpdate;

  final Future<PreparedUpdate> Function(
    ReleaseInfo release, {
    required UpdateChannel channel,
    required bool allowSourceFallback,
    required void Function(UpdateDownloadProgress progress) onProgress,
  })
  downloadAndPrepare;

  final void Function() cancelDownload;
  final Future<void> Function(PreparedUpdate update) launchInstaller;
  final Future<List<RollbackUpdate>> Function() findRollbackUpdates;
  final Future<void> Function(RollbackUpdate update) launchRollbackInstaller;
  final Future<List<int>> Function() findOtherRunningInstanceProcessIds;
  final Future<void> Function(List<int> processIds)
  requestCloseOtherRunningInstances;
  final Future<bool> Function(Duration timeout)
  waitForOtherRunningInstancesToExit;
}

/// 探针后端检测与 RTT 接收队列占用能力。
class ProbeDetectionActions {
  const ProbeDetectionActions({
    required this.checkBackendAvailability,
    required this.queuedBytes,
  });

  final Future<Map<String, ProbeBackendAvailability>> Function({
    bool? prepareBundledOpenOcd,
  })
  checkBackendAvailability;

  final int Function() queuedBytes;
}

/// 崩溃转储开关与调试用原生崩溃触发能力。
class CrashDumpActions {
  const CrashDumpActions({
    required this.setEnabled,
    required this.triggerTestCrash,
  });

  final Future<void> Function(bool enabled) setEnabled;
  final void Function() triggerTestCrash;
}

/// 数据连接状态与各接收队列内存占用能力（来自 DataConnectionService）。
class DataConnectionActions {
  const DataConnectionActions({
    required this.isConnectionBusy,
    required this.isNetworkConnection,
    required this.setNetworkConnectionsEnabled,
    required this.selectSerialProfile,
    required this.rawRetentionUsedBytes,
    required this.rawTextCacheUsedBytes,
    required this.shellQueueUsedBytes,
    required this.ymodemQueueUsedBytes,
  });

  final bool Function() isConnectionBusy;
  final bool Function() isNetworkConnection;
  final void Function(bool enabled) setNetworkConnectionsEnabled;
  final void Function(String pageId, {bool? forceReload}) selectSerialProfile;
  final int Function() rawRetentionUsedBytes;
  final int Function() rawTextCacheUsedBytes;
  final int Function() shellQueueUsedBytes;
  final int Function() ymodemQueueUsedBytes;
}

/// Modbus 运行模式能力；服务未装配时为 null。
class ModbusActions {
  const ModbusActions({required this.mode, required this.setMode});

  final ModbusMode Function() mode;
  final Future<void> Function(ModbusMode value) setMode;
}

/// SSH 连接状态能力；服务未装配时为 null。
class SshStatusActions {
  const SshStatusActions({
    required this.isConnected,
    required this.isConnecting,
  });

  final bool Function() isConnected;
  final bool Function() isConnecting;
}

/// 应用设置读写的窄接口，仅暴露应用信息对话框实际使用的字段与方法。
///
/// 组合根用真实 [AppSettings] 委托实现，测试可注入独立实现。
abstract interface class SettingsActions {
  int get plotHistoryMemoryLimitGiB;
  set plotHistoryMemoryLimitGiB(int value);

  String get rttJlinkExecutablePath;
  set rttJlinkExecutablePath(String value);
  String get rttOpenocdExecutablePath;
  set rttOpenocdExecutablePath(String value);
  String get rttPyocdPythonPath;
  set rttPyocdPythonPath(String value);

  bool get autoUpdateCheckEnabled;
  set autoUpdateCheckEnabled(bool value);
  bool get disableNotifications;
  set disableNotifications(bool value);
  bool get diagnosticLoggingEnabled;
  set diagnosticLoggingEnabled(bool value);
  bool get crashDumpEnabled;
  set crashDumpEnabled(bool value);
  bool get connectionShortcutsEnabled;
  set connectionShortcutsEnabled(bool value);
  bool get networkConnectionsEnabled;
  set networkConnectionsEnabled(bool value);
  bool get separateSerialProfiles;
  set separateSerialProfiles(bool value);

  String get updateChannel;
  set updateChannel(String value);
  String get updateSource;
  set updateSource(String value);

  Map<String, SerialConfig> get serialPageProfiles;
  set serialPageProfiles(Map<String, SerialConfig> value);

  void setSeparateSerialProfiles(bool enabled);
  Future<void> save();
  Future<void> flushPendingSave();
  Future<void> resetToDefaults();
}

/// 各接收队列的内存上限常量，供内存上限展示使用。
class MemoryLimits {
  const MemoryLimits({
    required this.rawRetentionLimitBytes,
    required this.rawTextCacheLimitBytes,
    required this.shellQueueLimitBytes,
    required this.ymodemQueueLimitBytes,
  });

  final int rawRetentionLimitBytes;
  final int rawTextCacheLimitBytes;
  final int shellQueueLimitBytes;
  final int ymodemQueueLimitBytes;
}

/// 应用信息对话框所需的全部注入能力集合。
///
/// 由组合根装配；对话框内部仅依赖这些窄接口，不再直接接触具体服务。
class AppInfoDialogActions {
  const AppInfoDialogActions({
    required this.appInfo,
    required this.update,
    required this.probeDetection,
    required this.crashDump,
    required this.dataConnection,
    required this.settings,
    required this.memoryLimits,
    required this.showNotification,
    this.modbus,
    this.sshStatus,
  });

  final AppInfoActions appInfo;
  final UpdateActions update;
  final ProbeDetectionActions probeDetection;
  final CrashDumpActions crashDump;
  final DataConnectionActions dataConnection;
  final SettingsActions settings;
  final MemoryLimits memoryLimits;
  final void Function(String message, {ScaffoldMessengerState? messenger})
  showNotification;
  final ModbusActions? modbus;
  final SshStatusActions? sshStatus;
}
