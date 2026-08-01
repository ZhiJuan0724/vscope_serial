import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/plot_configuration.dart';
import '../../core/constants/rtt_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../core/utils/app_logger.dart';
import '../../services/app_info.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/crash_dump_service.dart';
import '../../services/native_serial_reader.dart';
import '../../services/rtt_service.dart';
import '../../services/rtt_backend.dart';
import '../../services/changelog_service.dart';
import '../../services/raw_receive_session.dart';
import '../../services/serial_service.dart';
import '../../services/shell_receive_queue.dart';
import '../../services/update_checker.dart';
import '../../services/update_service.dart';
import '../../services/ymodem_service.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 打开应用信息、更新和版本说明窗口。
Future<void> showAppInfoDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const AppInfoDialog(),
  );
}

/// 直接打开全局高级设置页，跳过版本说明内容。
Future<void> showAppAdvancedSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const AppInfoDialog(showAdvancedSettingsOnly: true),
  );
}

/// 发现新版本后展示不可点击遮罩关闭的下载与安装流程。
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseInfo release, {
  UpdateSourcePreference sourcePreference = UpdateSourcePreference.auto,
}) async {
  final currentVersion = await AppInfo.displayVersion();
  if (!context.mounted) return;
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder:
        (context) => _UpdateAvailableDialog(
          release: release,
          currentVersion: currentVersion,
          sourcePreference: sourcePreference,
        ),
  );
}

double _dialogContentMaxHeight(BuildContext context) {
  return (MediaQuery.sizeOf(context).height * 0.72)
      .clamp(320.0, 620.0)
      .toDouble();
}

/// 应用信息弹窗的优选内容高度；小窗口仍由可用高度上限负责收缩。
const double _appInfoDialogPreferredContentHeight = 540;

double _appInfoDialogContentHeight(BuildContext context) {
  return (MediaQuery.sizeOf(context).height * 0.78)
      .clamp(320.0, _appInfoDialogPreferredContentHeight)
      .toDouble();
}

Widget _scrollWithoutScrollbar(BuildContext context, {required Widget child}) {
  return ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}

/// 单次更新下载/安装流程的状态容器。
///
/// 取消下载由 [UpdateService] 的 generation 处理，界面只反映当前这一次操作状态。
class _UpdateAvailableDialog extends StatefulWidget {
  final ReleaseInfo release;
  final String currentVersion;
  final UpdateSourcePreference sourcePreference;

  const _UpdateAvailableDialog({
    required this.release,
    required this.currentVersion,
    required this.sourcePreference,
  });

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  static const _canInstall = bool.fromEnvironment('dart.vm.product');
  final _service = UpdateService();
  late final UpdateChannel _channel = widget.release.channel;
  UpdateDownloadProgress? _progress;
  PreparedUpdate? _prepared;
  String? _error;
  bool _downloading = false;
  bool _installing = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _service.findPreparedUpdate(widget.release).then((value) {
      if (mounted && value != null) setState(() => _prepared = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text(AppStrings.appInfo.updateFound),
      content: SizedBox(
        width: 430,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _dialogContentMaxHeight(context),
          ),
          child: _scrollWithoutScrollbar(
            context,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.appInfo.currentVersion(widget.currentVersion),
                  ),
                  Text(
                    AppStrings.appInfo.latestVersion(widget.release.tagName),
                  ),
                  Text(AppStrings.appInfo.updateChannel(_channel.label)),
                  Text(AppStrings.appInfo.source(widget.release.source)),
                  if (widget.release.body.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      AppStrings.appInfo.changelog,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: _scrollWithoutScrollbar(
                        context,
                        child: SingleChildScrollView(
                          child: _ChangelogBody(body: widget.release.body),
                        ),
                      ),
                    ),
                  ],
                  if (_downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: _progress?.fraction),
                    const SizedBox(height: 6),
                    Text(
                      _progress == null
                          ? AppStrings.appInfo.preparingDownload
                          : '${_formatBytes(_progress!.received)} / '
                              '${_formatBytes(_progress!.total)}  '
                              '${_formatBytes(_progress!.bytesPerSecond.round())}/s',
                    ),
                  ],
                  if (_prepared != null) ...[
                    const SizedBox(height: 12),
                    Text(AppStrings.appInfo.updateReady),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (!_canInstall) ...[
                    const SizedBox(height: 12),
                    Text(AppStrings.appInfo.debugInstallUnsupported),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _downloading || _installing
                  ? null
                  : () => Navigator.of(context).pop(),
          child: Text(AppStrings.update.later),
        ),
        if (_downloading)
          TextButton(
            onPressed: () {
              _cancelled = true;
              _service.cancelDownload();
              setState(() {
                _error = AppStrings.appInfo.cancelingDownload;
              });
            },
            child: Text(AppStrings.update.cancelDownload),
          ),
        TextButton(
          onPressed:
              _downloading || _installing || widget.release.htmlUrl.isEmpty
                  ? null
                  : () => _openUrl(widget.release.htmlUrl),
          child: Text(AppStrings.update.openReleasePage),
        ),
        if (_prepared == null)
          ElevatedButton(
            onPressed: _downloading || !_canInstall ? null : _download,
            child: Text(AppStrings.update.downloadAndInstall),
          )
        else
          ElevatedButton(
            onPressed: _installing || !_canInstall ? null : _install,
            child: Text(
              _installing
                  ? AppStrings.update.startingUpdater
                  : AppStrings.update.restartAndInstall,
            ),
          ),
      ],
    );
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _cancelled = false;
      _error = null;
      _progress = null;
    });
    try {
      final prepared = await _service.downloadAndPrepare(
        widget.release,
        channel: _channel,
        allowSourceFallback:
            widget.sourcePreference == UpdateSourcePreference.auto,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) setState(() => _prepared = prepared);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  _cancelled
                      ? AppStrings.appInfo.downloadCanceled
                      : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _install() async {
    final prepared = _prepared;
    if (prepared == null) return;
    final canProceed = await _confirmAndCloseOtherInstances(_service);
    if (!canProceed) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await _service.launchInstaller(prepared);
      if (mounted) Navigator.of(context).pop();
      await windowManager.close();
    } catch (error) {
      if (mounted) {
        setState(() {
          _installing = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<bool> _confirmAndCloseOtherInstances(UpdateService service) async {
    final otherInstances = await service.findOtherRunningInstanceProcessIds();
    if (otherInstances.isEmpty) return true;
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(AppStrings.appInfo.multipleInstancesUpdateTitle),
            content: Text(AppStrings.appInfo.multipleInstancesUpdateMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(AppStrings.common.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(AppStrings.appInfo.closeOtherInstancesAndContinue),
              ),
            ],
          ),
    );
    if (confirmed != true) return false;
    await service.requestCloseOtherRunningInstances(otherInstances);
    final closed = await service.waitForOtherRunningInstancesToExit(
      const Duration(seconds: 10),
    );
    if (!closed && mounted) {
      setState(() {
        _error = AppStrings.appInfo.multipleInstancesCloseTimeout;
      });
    }
    return closed;
  }

  static String _formatBytes(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${bytes.toStringAsFixed(0)} B';
  }
}

/// 应用信息和全局高级设置的统一窗口。
///
/// 两个入口复用同一状态加载逻辑，`showAdvancedSettingsOnly` 仅改变初始可见内容。
class AppInfoDialog extends StatefulWidget {
  const AppInfoDialog({super.key, this.showAdvancedSettingsOnly = false});

  final bool showAdvancedSettingsOnly;

  @override
  State<AppInfoDialog> createState() => _AppInfoDialogState();
}

class _AppInfoDialogState extends State<AppInfoDialog> {
  final _checker = UpdateChecker();
  final _advancedSettingsScrollController = ScrollController();
  final _plotHistoryLimitController = TextEditingController(
    text: AppSettings().plotHistoryMemoryLimitGiB.toString(),
  );
  final _rttJlinkPathController = TextEditingController(
    text: AppSettings().rttJlinkExecutablePath,
  );
  final _rttOpenocdPathController = TextEditingController(
    text: AppSettings().rttOpenocdExecutablePath,
  );
  final _rttPyocdPythonPathController = TextEditingController(
    text: AppSettings().rttPyocdPythonPath,
  );
  Future<Map<String, RttBackendAvailability>>? _rttBackendAvailability;
  bool _autoUpdateCheckEnabled = AppSettings().autoUpdateCheckEnabled;
  bool _disableNotifications = AppSettings().disableNotifications;
  UpdateChannel _updateChannel = UpdateChannel.fromString(
    AppSettings().updateChannel,
  );
  UpdateSourcePreference _updateSourcePreference =
      UpdateSourcePreference.fromString(AppSettings().updateSource);
  bool _checking = false;
  bool _loadingRollback = false;
  String? _version;
  DateTime? _buildTime;
  List<ChangelogEntry> _changelogEntries = const [];
  UpdateCheckResult? _lastResult;
  List<RollbackUpdate> _rollbackUpdates = const [];

  @override
  void initState() {
    super.initState();
    if (widget.showAdvancedSettingsOnly) {
      _loadRollbackUpdates();
      return;
    }
    AppInfo.displayVersion()
        .then((value) {
          if (mounted) setState(() => _version = value);
          return ChangelogService().currentAndPrevious(value);
        })
        .then((entries) {
          if (mounted) setState(() => _changelogEntries = entries);
        });
    AppInfo.buildTime().then((value) {
      if (mounted) setState(() => _buildTime = value);
    });
  }

  @override
  void dispose() {
    _advancedSettingsScrollController.dispose();
    _plotHistoryLimitController.dispose();
    _rttJlinkPathController.dispose();
    _rttOpenocdPathController.dispose();
    _rttPyocdPythonPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showAdvancedSettingsOnly) {
      return _buildAdvancedSettingsDialog(context);
    }
    final release = _lastResult?.latestRelease;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Row(
        children: [
          const Icon(Icons.info_outline),
          const SizedBox(width: 8),
          Text(AppStrings.appInfo.title),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: _appInfoDialogContentHeight(context),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _appInfoDialogContentHeight(context),
          ),
          child: _scrollWithoutScrollbar(
            context,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: _InfoRow(
                          key: const ValueKey('app-info-name'),
                          label: AppStrings.appInfo.appName,
                          value: AppInfo.name,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 4,
                        child: _InfoRow(
                          key: const ValueKey('app-info-version'),
                          label: AppStrings.appInfo.version,
                          value: _version ?? AppStrings.appInfo.loading,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 7,
                        child: _InfoRow(
                          key: const ValueKey('app-info-build-time'),
                          label: AppStrings.appInfo.buildTime,
                          value: _formatBuildTime(_buildTime),
                        ),
                      ),
                    ],
                  ),
                  if (_changelogEntries.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.appInfo.releaseNotes,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    _ChangelogPreview(entries: _changelogEntries),
                  ],
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(AppStrings.appInfo.autoCheckUpdates),
                            const SizedBox(height: 2),
                            Text(
                              AppStrings.appInfo.autoCheckUpdatesHelp,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(
                                color:
                                    Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _autoUpdateCheckEnabled,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (value) {
                          setState(() => _autoUpdateCheckEnabled = value);
                          final settings =
                              AppSettings()..autoUpdateCheckEnabled = value;
                          settings.save();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildUpdateChannelAndSource(),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _resultText(
                        _lastResult!,
                        _version ?? AppStrings.appInfo.unknown,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            _lastResult!.error != null
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_lastResult!.hasUpdate && release != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => _openUrl(release.htmlUrl),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: Text(
                          AppStrings.appInfo.openReleasePage(release.source),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        ElevatedButton.icon(
          key: const ValueKey('check-for-update-button'),
          onPressed: _checking ? null : _checkForUpdate,
          icon:
              _checking
                  ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.update, size: 16),
          label: Text(
            _checking
                ? AppStrings.appInfo.checking
                : AppStrings.appInfo.manualCheckUpdates,
          ),
        ),
        OutlinedButton.icon(
          key: const ValueKey('download-and-install-button'),
          onPressed:
              _lastResult?.hasUpdate == true && release != null
                  ? () => showUpdateAvailableDialog(
                    context,
                    release,
                    sourcePreference: _updateSourcePreference,
                  )
                  : null,
          icon: const Icon(Icons.download, size: 16),
          label: Text(AppStrings.update.downloadAndInstall),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.close),
        ),
      ],
    );
  }

  Widget _buildUpdateChannelAndSource() {
    final helpStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final channelHelp =
        _updateChannel == UpdateChannel.beta
            ? AppStrings.appInfo.betaChannelHelp
            : AppStrings.appInfo.stableChannelHelp;
    final sourceHelp =
        _updateSourcePreference == UpdateSourcePreference.auto
            ? AppStrings.appInfo.updateSourceAutoHelp
            : AppStrings.appInfo.updateSourceLockedHelp(
              _updateSourcePreference.label,
            );

    return Column(
      key: const ValueKey('update-channel-and-source'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppStrings.appInfo.updateChannelAndSourceTitle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: NoAnimDropdown<UpdateChannel>(
                value: _updateChannel,
                hint: AppStrings.appInfo.updateChannelTitle,
                decoration: secondaryDialogFieldDecoration(
                  hintText: AppStrings.appInfo.updateChannelTitle,
                ),
                items: UpdateChannel.values
                    .map(
                      (channel) => DropdownMenuItem(
                        value: channel,
                        child: Text(channel.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _updateChannel = value;
                    _lastResult = null;
                  });
                  final settings = AppSettings()..updateChannel = value.value;
                  settings.save();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: NoAnimDropdown<UpdateSourcePreference>(
                value: _updateSourcePreference,
                hint: AppStrings.appInfo.updateSourceTitle,
                decoration: secondaryDialogFieldDecoration(
                  hintText: AppStrings.appInfo.updateSourceTitle,
                ),
                items: UpdateSourcePreference.values
                    .map(
                      (source) => DropdownMenuItem(
                        value: source,
                        child: Text(source.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _updateSourcePreference = value;
                    _lastResult = null;
                  });
                  final settings = AppSettings()..updateSource = value.value;
                  settings.save();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('$channelHelp；$sourceHelp', style: helpStyle),
      ],
    );
  }

  Widget _buildRollbackSection(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    final subtitleStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Text(AppStrings.appInfo.rollback, style: titleStyle),
        const SizedBox(height: 6),
        if (_loadingRollback)
          Text(AppStrings.appInfo.loadingRollback, style: subtitleStyle)
        else
          ...UpdateChannel.values.map((channel) {
            final update = _rollbackUpdateFor(channel);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.appInfo.rollbackVersion(
                        channel.label,
                        update?.tagName,
                      ),
                      style: subtitleStyle,
                    ),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      textStyle: Theme.of(context).textTheme.bodySmall,
                    ),
                    onPressed:
                        update == null ? null : () => _installRollback(update),
                    child: Text(AppStrings.appInfo.rollbackAction),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildMemoryLimitsSection(
    BuildContext context, {
    required int plotHistoryLimitGiB,
    required int plotHistoryUsedBytes,
    required int processRssBytes,
    required int rawRetentionUsedBytes,
    required int rawTextCacheUsedBytes,
    required int shellQueueUsedBytes,
    required int ymodemQueueUsedBytes,
    required int rttQueueUsedBytes,
    required int rttRawHistoryUsedBytes,
    required VoidCallback onApplyPlotHistoryLimit,
  }) {
    final emergencyRssLimitBytes = math.max(
      PlotConfiguration.baseEmergencyRssLimitBytes,
      (plotHistoryLimitGiB * PlotConfiguration.bytesPerGiB) +
          PlotConfiguration.emergencyRssHeadroomBytes,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MemoryLimitRow(
          title: AppStrings.appInfo.plotHistoryMemoryLimit,
          subtitle: AppStrings.appInfo.plotHistoryMemoryLimitSummary,
          usedBytes: plotHistoryUsedBytes,
          limitBytes: plotHistoryLimitGiB * PlotConfiguration.bytesPerGiB,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: kSecondaryDialogFieldWidth,
                child: TextField(
                  key: const ValueKey('app-plot-history-memory-limit'),
                  controller: _plotHistoryLimitController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: secondaryDialogFieldDecoration(
                    suffixText: AppStrings.plot.unitGiB,
                  ),
                  onSubmitted: (_) => onApplyPlotHistoryLimit(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onApplyPlotHistoryLimit,
                child: Text(AppStrings.common.apply),
              ),
            ],
          ),
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.plotEmergencyRssLimit,
          subtitle: AppStrings.appInfo.plotEmergencyRssLimitSummary,
          usedBytes: processRssBytes,
          limitBytes: emergencyRssLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.rawRetentionMemoryLimit,
          subtitle: AppStrings.appInfo.rawRetentionMemoryLimitSummary,
          usedBytes: rawRetentionUsedBytes,
          limitBytes: RawReceiveSession.rawRetentionLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.rawTextCacheMemoryLimit,
          subtitle: AppStrings.appInfo.rawTextCacheMemoryLimitSummary,
          usedBytes: rawTextCacheUsedBytes,
          limitBytes: RawReceiveSession.textDisplayCacheLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.shellQueueMemoryLimit,
          subtitle: AppStrings.appInfo.shellQueueMemoryLimitSummary,
          usedBytes: shellQueueUsedBytes,
          limitBytes: ShellReceiveQueue.defaultMaxBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.ymodemQueueMemoryLimit,
          subtitle: AppStrings.appInfo.ymodemQueueMemoryLimitSummary,
          usedBytes: ymodemQueueUsedBytes,
          limitBytes: YmodemService.defaultInputHighWaterBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.rttQueueMemoryLimit,
          subtitle: AppStrings.appInfo.rttQueueMemoryLimitSummary,
          usedBytes: rttQueueUsedBytes,
          limitBytes: RttConfiguration.receiveQueueLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.rttRawHistoryMemoryLimit,
          subtitle: AppStrings.appInfo.rttRawHistoryMemoryLimitSummary,
          usedBytes: rttRawHistoryUsedBytes,
          limitBytes: RttConfiguration.rawHistoryLimitBytes,
        ),
      ],
    );
  }

  Widget _buildResetSettingsSection(
    BuildContext context, {
    required Future<void> Function() onReset,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    final subtitleStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppStrings.appInfo.resetSettings, style: titleStyle),
        const SizedBox(height: 6),
        Text(AppStrings.appInfo.resetSettingsHelp, style: subtitleStyle),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.error,
              side: BorderSide(color: colorScheme.error),
            ),
            onPressed: onReset,
            icon: const Icon(Icons.restore, size: 16),
            label: Text(AppStrings.appInfo.resetSettings),
          ),
        ),
      ],
    );
  }

  Widget _buildProbeBackendSection(
    BuildContext context,
    StateSetter setDialogState,
  ) {
    final settings = AppSettings();
    _rttBackendAvailability ??=
        context.read<RttService>().checkBackendAvailability();

    void refreshAvailability() {
      setDialogState(() {
        _rttBackendAvailability =
            context.read<RttService>().checkBackendAvailability();
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _rttJlinkPathController,
          decoration: const InputDecoration(
            labelText: 'JLinkGDBServerCL.exe 路径',
            helperText: '留空时从 SEGGER 安装目录和 PATH 自动查找',
          ),
          onChanged: (value) {
            settings.rttJlinkExecutablePath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _rttOpenocdPathController,
          decoration: const InputDecoration(
            labelText: '外置 openocd.exe 路径',
            helperText: '留空时从 PATH 查找；仅影响外置 OpenOCD',
          ),
          onChanged: (value) {
            settings.rttOpenocdExecutablePath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _rttPyocdPythonPathController,
          decoration: const InputDecoration(
            labelText: '外置 pyOCD Python 路径',
            helperText: '指向能够 import pyocd 的 python.exe；当前仅支持 pyOCD 0.45.x',
          ),
          onChanged: (value) {
            settings.rttPyocdPythonPath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        FutureBuilder<Map<String, RttBackendAvailability>>(
          future: _rttBackendAvailability,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Text('正在检测探针后端...');

            String state(String id) {
              final status = snapshot.data![id];
              if (status == null || !status.available) return '未检测到';
              final version = status.version?.trim();
              return version == null || version.isEmpty
                  ? '已检测到（版本未知）'
                  : version;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('J-Link: ${state('external-jlink')}'),
                Text('内置 OpenOCD: ${state('bundled-openocd')}'),
                Text('外置 OpenOCD: ${state('external-openocd')}'),
                Text('外置 pyOCD: ${state('external-pyocd')}'),
              ],
            );
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: refreshAvailability,
            icon: const Icon(Icons.refresh),
            label: const Text('重新检测'),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedSettingsDialog(BuildContext dialogContext) {
    var disableNotifications = _disableNotifications;
    var diagnosticLoggingEnabled = AppSettings().diagnosticLoggingEnabled;
    var crashDumpEnabled = AppSettings().crashDumpEnabled;
    var connectionShortcutsEnabled = AppSettings().connectionShortcutsEnabled;
    var networkConnectionsEnabled = AppSettings().networkConnectionsEnabled;
    var separateSerialProfiles = AppSettings().separateSerialProfiles;
    // 探针后端属于连接能力设置，即使当前未显示探针页面也允许预先配置。
    const rttEnabled = true;
    var plotReceiveAggregationEnabled =
        AppSettings().plotReceiveAggregationEnabled;
    final notificationSectionKey = GlobalKey();
    final diagnosticsSectionKey = GlobalKey();
    final shortcutsSectionKey = GlobalKey();
    final pageSectionKey = GlobalKey();
    final probeBackendSectionKey = GlobalKey();
    final receivePerformanceSectionKey = GlobalKey();
    final memorySectionKey = GlobalKey();
    final rollbackSectionKey = GlobalKey();
    final resetSectionKey = GlobalKey();
    return StatefulBuilder(
      builder:
          (context, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.common.advancedSettings),
            content: SettingsNavigationView(
              scrollController: _advancedSettingsScrollController,
              items: [
                SettingsNavigationItem(
                  label: AppStrings.common.settingsNotifications,
                  anchorKey: notificationSectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.common.settingsDiagnostics,
                  anchorKey: diagnosticsSectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.common.settingsShortcuts,
                  anchorKey: shortcutsSectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.common.settingsPages,
                  anchorKey: pageSectionKey,
                ),
                if (rttEnabled)
                  SettingsNavigationItem(
                    label: AppStrings.common.settingsProbeBackend,
                    anchorKey: probeBackendSectionKey,
                  ),
                SettingsNavigationItem(
                  label: AppStrings.appInfo.receivePerformance,
                  anchorKey: receivePerformanceSectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.appInfo.memoryLimits,
                  anchorKey: memorySectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.common.settingsVersionRollback,
                  anchorKey: rollbackSectionKey,
                ),
                SettingsNavigationItem(
                  label: AppStrings.common.settingsReset,
                  anchorKey: resetSectionKey,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: notificationSectionKey,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      AppStrings.appInfo.disableNotifications,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      AppStrings.appInfo.disableNotificationsHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: disableNotifications,
                    onChanged: (value) {
                      setDialogState(() => disableNotifications = value);
                      setState(() => _disableNotifications = value);
                      final settings =
                          AppSettings()..disableNotifications = value;
                      settings.save();
                    },
                  ),
                  const Divider(height: 16),
                  SwitchListTile(
                    key: diagnosticsSectionKey,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      AppStrings.appInfo.diagnosticLogging,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      AppStrings.appInfo.diagnosticLoggingHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: diagnosticLoggingEnabled,
                    onChanged: (value) {
                      setDialogState(() => diagnosticLoggingEnabled = value);
                      final settings =
                          AppSettings()..diagnosticLoggingEnabled = value;
                      AppLogger().setDiagnosticEnabled(value);
                      settings.save();
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      AppStrings.appInfo.crashDump,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      AppStrings.appInfo.crashDumpHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: crashDumpEnabled,
                    onChanged: (value) async {
                      setDialogState(() => crashDumpEnabled = value);
                      final settings = AppSettings()..crashDumpEnabled = value;
                      final crashDumpService = CrashDumpService();
                      try {
                        await crashDumpService.setEnabled(value);
                        await settings.save();
                      } catch (error, stackTrace) {
                        AppLogger().error(
                          '更新原生崩溃转储开关失败: $error',
                          category: 'APP',
                          error: error,
                          stackTrace: stackTrace,
                        );
                        settings.crashDumpEnabled = !value;
                        try {
                          await crashDumpService.setEnabled(!value);
                        } catch (_) {
                          // 已记录原始失败；回滚同样失败时保持内存值并等待下次启动同步。
                        }
                        if (context.mounted) {
                          setDialogState(
                            () => crashDumpEnabled = settings.crashDumpEnabled,
                          );
                          AppNotifications.show('崩溃转储设置保存失败，请检查程序目录写入权限');
                        }
                      }
                    },
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 4),
                    Text(
                      AppStrings.appInfo.triggerTestCrashHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey(
                          'debug-trigger-native-crash-button',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed:
                            crashDumpEnabled
                                ? _confirmAndTriggerTestCrash
                                : null,
                        icon: const Icon(Icons.warning_amber_rounded, size: 16),
                        label: Text(AppStrings.appInfo.triggerTestCrash),
                      ),
                    ),
                  ],
                  const Divider(height: 16),
                  SwitchListTile(
                    key: shortcutsSectionKey,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '启用连接快捷键',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'F1 打开连接配置，F2 快捷连接，F3 快捷断开，F5 快捷重连；'
                      '关闭后全部不响应。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: connectionShortcutsEnabled,
                    onChanged: (value) {
                      setDialogState(() => connectionShortcutsEnabled = value);
                      final settings =
                          AppSettings()..connectionShortcutsEnabled = value;
                      unawaited(settings.save());
                    },
                  ),
                  const Divider(height: 16),
                  SwitchListTile(
                    key: pageSectionKey,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '启用网络连接',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '允许数据收发和绘图使用 TCP/UDP；Shell 不受影响。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: networkConnectionsEnabled,
                    onChanged:
                        SerialService().isNetworkConnection &&
                                SerialService().isConnectionBusy
                            ? null
                            : (value) {
                              setDialogState(
                                () => networkConnectionsEnabled = value,
                              );
                              SerialService().setNetworkConnectionsEnabled(
                                value,
                              );
                            },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '按页面独立保存串口参数',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '关闭时数据收发、Shell和绘图共用原全局参数；开启后分别保存。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: separateSerialProfiles,
                    onChanged:
                        SerialService().isConnectionBusy
                            ? null
                            : (value) {
                              final settings =
                                  AppSettings()
                                    ..setSeparateSerialProfiles(value);
                              setDialogState(
                                () => separateSerialProfiles = value,
                              );
                              SerialService().selectSerialProfile(
                                'rawData',
                                forceReload: true,
                              );
                              unawaited(settings.save());
                            },
                  ),
                  const Divider(height: 16),
                  if (rttEnabled) ...[
                    KeyedSubtree(
                      key: probeBackendSectionKey,
                      child: _buildProbeBackendSection(context, setDialogState),
                    ),
                    const Divider(height: 16),
                  ],
                  SwitchListTile(
                    key: receivePerformanceSectionKey,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      AppStrings.appInfo.plotReceiveAggregation,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      AppStrings.appInfo.plotReceiveAggregationHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: plotReceiveAggregationEnabled,
                    onChanged: (value) {
                      setDialogState(
                        () => plotReceiveAggregationEnabled = value,
                      );
                      context
                          .read<SerialService>()
                          .setPlotReceiveAggregationEnabled(value);
                    },
                  ),
                  const Divider(height: 16),
                  KeyedSubtree(
                    key: memorySectionKey,
                    child: StreamBuilder<int>(
                      stream: Stream<int>.periodic(
                        const Duration(milliseconds: 500),
                        (tick) => tick,
                      ),
                      builder: (context, _) {
                        final plotViewModel = context.read<PlotViewModel>();
                        final serialService = context.read<SerialService>();
                        final rttService = context.read<RttService?>();
                        final rttViewModel = context.read<RttViewModel?>();
                        final plotUsage = plotViewModel.plotRetentionUsage;
                        return _buildMemoryLimitsSection(
                          context,
                          plotHistoryLimitGiB:
                              plotViewModel.plotRetentionLimitGiB,
                          plotHistoryUsedBytes: plotUsage.usedBytes,
                          processRssBytes: ProcessInfo.currentRss,
                          rawRetentionUsedBytes:
                              serialService.rawRetentionUsage.usedBytes,
                          rawTextCacheUsedBytes:
                              serialService.rawTextDisplayCacheBytes,
                          shellQueueUsedBytes:
                              serialService.shellPendingReceiveBytes,
                          ymodemQueueUsedBytes:
                              serialService.ymodemService.incomingBytes,
                          rttQueueUsedBytes: rttService?.queuedBytes ?? 0,
                          rttRawHistoryUsedBytes:
                              rttViewModel?.rawHistoryBytes ?? 0,
                          onApplyPlotHistoryLimit: () {
                            final value = int.tryParse(
                              _plotHistoryLimitController.text,
                            );
                            if (value == null) return;
                            plotViewModel.setPlotRetentionLimitGiB(value);
                            _plotHistoryLimitController.text =
                                plotViewModel.plotRetentionLimitGiB.toString();
                            setDialogState(() {});
                          },
                        );
                      },
                    ),
                  ),
                  const Divider(height: 16),
                  KeyedSubtree(
                    key: rollbackSectionKey,
                    child: _buildRollbackSection(context),
                  ),
                  const Divider(height: 16),
                  KeyedSubtree(
                    key: resetSectionKey,
                    child: _buildResetSettingsSection(
                      context,
                      onReset: () async {
                        final didReset = await _confirmResetSettings();
                        if (didReset) {
                          if (!context.mounted) return;
                          final resetPlotLimit =
                              AppSettings().plotHistoryMemoryLimitGiB;
                          context
                              .read<PlotViewModel>()
                              .setPlotRetentionLimitGiB(resetPlotLimit);
                          setDialogState(() {
                            disableNotifications =
                                AppSettings().disableNotifications;
                            diagnosticLoggingEnabled =
                                AppSettings().diagnosticLoggingEnabled;
                            crashDumpEnabled = AppSettings().crashDumpEnabled;
                            connectionShortcutsEnabled =
                                AppSettings().connectionShortcutsEnabled;
                            networkConnectionsEnabled =
                                AppSettings().networkConnectionsEnabled;
                            separateSerialProfiles =
                                AppSettings().separateSerialProfiles;
                            plotReceiveAggregationEnabled =
                                AppSettings().plotReceiveAggregationEnabled;
                            _plotHistoryLimitController.text =
                                resetPlotLimit.toString();
                          });
                          try {
                            await CrashDumpService().setEnabled(
                              AppSettings().crashDumpEnabled,
                            );
                          } catch (error, stackTrace) {
                            AppLogger().error(
                              '恢复默认设置后同步崩溃转储开关失败: $error',
                              category: 'APP',
                              error: error,
                              stackTrace: stackTrace,
                            );
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(AppStrings.common.close),
              ),
            ],
          ),
    );
  }

  Future<void> _confirmAndTriggerTestCrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.appInfo.triggerTestCrashTitle),
            content: Text(AppStrings.appInfo.triggerTestCrashMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(AppStrings.common.cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  elevation: 0,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(AppStrings.appInfo.triggerTestCrash),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await AppSettings().flushPendingSave();
      AppLogger().fatal('用户从 Debug 高级设置主动触发原生崩溃测试', category: 'APP');
      await AppLogger().flush();
      NativeSerialReader.triggerTestCrash();
    } catch (error, stackTrace) {
      AppLogger().error(
        '触发原生崩溃测试失败: $error',
        category: 'APP',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) AppNotifications.show('触发原生崩溃测试失败：$error');
    }
  }

  Future<bool> _confirmResetSettings() async {
    final confirmCode = (math.Random.secure().nextInt(9000) + 1000).toString();
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var input = '';
        return StatefulBuilder(
          builder:
              (context, setDialogState) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                title: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(AppStrings.appInfo.confirmResetSettingsTitle),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppStrings.appInfo.resetSettingsWarning),
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.appInfo.resetSettingsKeepsProfiles,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    Text(AppStrings.appInfo.enterResetCode(confirmCode)),
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      onChanged: (value) => setDialogState(() => input = value),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: Text(AppStrings.common.cancel),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    onPressed:
                        input == confirmCode
                            ? () => Navigator.of(dialogContext).pop(true)
                            : null,
                    child: Text(AppStrings.appInfo.confirmReset),
                  ),
                ],
              ),
        );
      },
    );
    if (confirmed != true) return false;

    await AppSettings().resetToDefaults();
    if (!mounted) return true;
    final settings = AppSettings();
    setState(() {
      _autoUpdateCheckEnabled = settings.autoUpdateCheckEnabled;
      _disableNotifications = settings.disableNotifications;
      _updateChannel = UpdateChannel.fromString(settings.updateChannel);
      _updateSourcePreference = UpdateSourcePreference.fromString(
        settings.updateSource,
      );
      _lastResult = null;
    });
    AppNotifications.show(
      AppStrings.appInfo.resetSettingsDone,
      messenger: ScaffoldMessenger.maybeOf(context),
    );
    return true;
  }

  Future<void> _checkForUpdate() async {
    setState(() {
      _checking = true;
      _lastResult = null;
    });
    final result = await _checker.check(
      channel: _updateChannel,
      source: _updateSourcePreference.releaseSource,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastResult = result;
    });
  }

  Future<void> _loadRollbackUpdates() async {
    setState(() => _loadingRollback = true);
    final updates = await UpdateService().findRollbackUpdates();
    if (!mounted) return;
    setState(() {
      _rollbackUpdates = updates;
      _loadingRollback = false;
    });
  }

  RollbackUpdate? _rollbackUpdateFor(UpdateChannel channel) {
    for (final update in _rollbackUpdates) {
      if (update.channel == channel) return update;
    }
    return null;
  }

  Future<void> _installRollback(RollbackUpdate update) async {
    try {
      final service = UpdateService();
      final canProceed = await _confirmAndCloseOtherInstances(service);
      if (!canProceed) return;
      await service.launchRollbackInstaller(update);
      if (mounted) Navigator.of(context).pop();
      await windowManager.close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastResult = UpdateCheckResult.failed(error.toString());
      });
    }
  }

  Future<bool> _confirmAndCloseOtherInstances(UpdateService service) async {
    final otherInstances = await service.findOtherRunningInstanceProcessIds();
    if (otherInstances.isEmpty) return true;
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(AppStrings.appInfo.multipleInstancesUpdateTitle),
            content: Text(AppStrings.appInfo.multipleInstancesUpdateMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(AppStrings.common.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(AppStrings.appInfo.closeOtherInstancesAndContinue),
              ),
            ],
          ),
    );
    if (confirmed != true) return false;
    await service.requestCloseOtherRunningInstances(otherInstances);
    final closed = await service.waitForOtherRunningInstancesToExit(
      const Duration(seconds: 10),
    );
    if (!closed && mounted) {
      setState(() {
        _lastResult = UpdateCheckResult.failed(
          AppStrings.appInfo.multipleInstancesCloseTimeout,
        );
      });
    }
    return closed;
  }

  static String _formatBuildTime(DateTime? time) {
    if (time == null) return AppStrings.appInfo.unknown;
    final local = time.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }

  static String _resultText(UpdateCheckResult result, String currentVersion) {
    if (result.error != null) return result.error!;
    final release = result.latestRelease;
    if (release == null) return AppStrings.appInfo.noVersionInfo;
    if (result.hasUpdate) {
      return AppStrings.appInfo.updateAvailable(
        release.channel.label,
        release.tagName,
        release.source,
      );
    }
    return AppStrings.appInfo.noUpdate(
      currentVersion: currentVersion,
      channel: release.channel.label,
      tagName: release.tagName,
      source: release.source,
    );
  }
}

class _MemoryLimitRow extends StatelessWidget {
  const _MemoryLimitRow({
    required this.title,
    required this.subtitle,
    required this.usedBytes,
    required this.limitBytes,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final int usedBytes;
  final int limitBytes;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppStrings.appInfo.memoryUsage(
                        _formatMemoryLimit(usedBytes),
                        _formatMemoryLimit(limitBytes),
                        _formatMemoryPercent(usedBytes, limitBytes),
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 16), trailing!],
            ],
          ),
        ),
      ],
    );
  }
}

String _formatMemoryLimit(int bytes) {
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  if (bytes <= 0) return '0 B';
  if (bytes % gib == 0) return '${bytes ~/ gib} GiB';
  if (bytes % mib == 0) return '${bytes ~/ mib} MiB';
  return '${(bytes / mib).toStringAsFixed(1)} MiB';
}

String _formatMemoryPercent(int usedBytes, int limitBytes) {
  if (limitBytes <= 0) return '0.0%';
  return '${(usedBytes / limitBytes * 100).toStringAsFixed(1)}%';
}

class _ChangelogPreview extends StatelessWidget {
  final List<ChangelogEntry> entries;

  const _ChangelogPreview({required this.entries});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 260),
      child: _scrollWithoutScrollbar(
        context,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        _ChangelogBody(body: entry.body),
                      ],
                    ),
                  );
                }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ChangelogBody extends StatelessWidget {
  final String body;

  const _ChangelogBody({required this.body});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final lines = ChangelogService.parseBody(body);

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines
            .map((line) {
              if (line.text.isEmpty) {
                return const SizedBox(height: 4);
              }

              switch (line.type) {
                case ChangelogLineType.heading:
                  return Padding(
                    padding: const EdgeInsets.only(top: 3, bottom: 2),
                    child: Text(
                      line.text,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  );
                case ChangelogLineType.listItem:
                  return Text(
                    '• ${line.text}',
                    style: TextStyle(fontSize: 12, color: color),
                  );
                case ChangelogLineType.text:
                  return Text(
                    line.text,
                    style: TextStyle(fontSize: 12, color: color),
                  );
              }
            })
            .toList(growable: false),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label:',
            maxLines: 1,
            style: const TextStyle(fontSize: 14, color: Colors.black),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: const TextStyle(fontSize: 14, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openUrl(String url) async {
  if (url.isEmpty) return;
  if (Platform.isWindows) {
    await Process.start('cmd', ['/c', 'start', '', url]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [url]);
  } else {
    await Process.start('xdg-open', [url]);
  }
}
