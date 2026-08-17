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
import '../../core/utils/byte_size_formatter.dart';
import '../../data/models/modbus_models.dart';
import '../../data/models/ssh_connection_config.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../../viewmodels/shell_viewmodel.dart';
import '../widgets/common_widgets.dart';
import 'app_info_actions.dart';
import 'app_info_actions_factory.dart';

/// 打开应用信息、更新和版本说明窗口。
Future<void> showAppInfoDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder:
        (context) => AppInfoDialog(actions: buildAppInfoDialogActions(context)),
  );
}

/// 直接打开全局高级设置页，跳过版本说明内容。
Future<void> showAppAdvancedSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder:
        (context) => AppInfoDialog(
          showAdvancedSettingsOnly: true,
          actions: buildAppInfoDialogActions(context),
        ),
  );
}

/// 发现新版本后展示不可点击遮罩关闭的下载与安装流程。
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseInfo release, {
  UpdateSourcePreference sourcePreference = UpdateSourcePreference.auto,
  AppInfoDialogActions? actions,
}) async {
  final resolved = actions ?? buildAppInfoDialogActions(context);
  final currentVersion = await resolved.appInfo.displayVersion();
  if (!context.mounted) return;
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder:
        (context) => _UpdateAvailableDialog(
          release: release,
          currentVersion: currentVersion,
          sourcePreference: sourcePreference,
          updateActions: resolved.update,
          parseChangelogBody: resolved.appInfo.parseChangelogBody,
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
/// 取消下载由 [UpdateActions] 背后的 generation 处理，界面只反映当前这一次操作状态。
class _UpdateAvailableDialog extends StatefulWidget {
  final ReleaseInfo release;
  final String currentVersion;
  final UpdateSourcePreference sourcePreference;
  final UpdateActions updateActions;
  final List<ChangelogLine> Function(String body) parseChangelogBody;

  const _UpdateAvailableDialog({
    required this.release,
    required this.currentVersion,
    required this.sourcePreference,
    required this.updateActions,
    required this.parseChangelogBody,
  });

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  static const _canInstall = bool.fromEnvironment('dart.vm.product');
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
    widget.updateActions.findPreparedUpdate(widget.release).then((value) {
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
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: _scrollWithoutScrollbar(
                        context,
                        child: SingleChildScrollView(
                          child: _ChangelogBody(
                            body: widget.release.body,
                            parseBody: widget.parseChangelogBody,
                          ),
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
                          : '${formatByteSize(_progress!.received)} / '
                              '${formatByteSize(_progress!.total)}  '
                              '${formatByteSize(_progress!.bytesPerSecond.round())}/s',
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
              widget.updateActions.cancelDownload();
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
      final prepared = await widget.updateActions.downloadAndPrepare(
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
    final canProceed = await _confirmAndCloseOtherInstances(
      widget.updateActions,
    );
    if (!canProceed) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await widget.updateActions.launchInstaller(prepared);
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

  Future<bool> _confirmAndCloseOtherInstances(UpdateActions actions) async {
    final otherInstances = await actions.findOtherRunningInstanceProcessIds();
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
    await actions.requestCloseOtherRunningInstances(otherInstances);
    final closed = await actions.waitForOtherRunningInstancesToExit(
      const Duration(seconds: 10),
    );
    if (!closed && mounted) {
      setState(() {
        _error = AppStrings.appInfo.multipleInstancesCloseTimeout;
      });
    }
    return closed;
  }
}

/// 应用信息和全局高级设置的统一窗口。
///
/// 两个入口复用同一状态加载逻辑，`showAdvancedSettingsOnly` 仅改变初始可见内容。
class AppInfoDialog extends StatefulWidget {
  const AppInfoDialog({
    super.key,
    this.showAdvancedSettingsOnly = false,
    required this.actions,
  });

  final bool showAdvancedSettingsOnly;
  final AppInfoDialogActions actions;

  @override
  State<AppInfoDialog> createState() => _AppInfoDialogState();
}

class _AppInfoDialogState extends State<AppInfoDialog> {
  final _advancedSettingsScrollController = ScrollController();
  late final TextEditingController _plotHistoryLimitController;
  late final TextEditingController _rttJlinkPathController;
  late final TextEditingController _rttOpenocdPathController;
  late final TextEditingController _rttPyocdPythonPathController;
  Future<Map<String, ProbeBackendAvailability>>? _rttBackendAvailability;
  late bool _autoUpdateCheckEnabled;
  late bool _disableNotifications;
  late UpdateChannel _updateChannel;
  late UpdateSourcePreference _updateSourcePreference;
  bool _checking = false;
  bool _loadingRollback = false;
  String? _version;
  DateTime? _buildTime;
  List<ChangelogEntry> _changelogEntries = const [];
  UpdateCheckResult? _lastResult;
  List<RollbackUpdate> _rollbackUpdates = const [];

  SettingsActions get _settings => widget.actions.settings;

  @override
  void initState() {
    super.initState();
    final settings = _settings;
    _plotHistoryLimitController = TextEditingController(
      text: settings.plotHistoryMemoryLimitGiB.toString(),
    );
    _rttJlinkPathController = TextEditingController(
      text: settings.rttJlinkExecutablePath,
    );
    _rttOpenocdPathController = TextEditingController(
      text: settings.rttOpenocdExecutablePath,
    );
    _rttPyocdPythonPathController = TextEditingController(
      text: settings.rttPyocdPythonPath,
    );
    _autoUpdateCheckEnabled = settings.autoUpdateCheckEnabled;
    _disableNotifications = settings.disableNotifications;
    _updateChannel = UpdateChannel.fromString(settings.updateChannel);
    _updateSourcePreference = UpdateSourcePreference.fromString(
      settings.updateSource,
    );
    if (widget.showAdvancedSettingsOnly) {
      _loadRollbackUpdates();
      return;
    }
    widget.actions.appInfo
        .displayVersion()
        .then((value) {
          if (mounted) setState(() => _version = value);
          return widget.actions.appInfo.loadChangelog(value);
        })
        .then((entries) {
          if (mounted) setState(() => _changelogEntries = entries);
        });
    widget.actions.appInfo.buildTime().then((value) {
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
                          value: widget.actions.appInfo.appName,
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
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    _ChangelogPreview(
                      entries: _changelogEntries,
                      parseBody: widget.actions.appInfo.parseChangelogBody,
                    ),
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
                          _settings.autoUpdateCheckEnabled = value;
                          unawaited(_settings.save());
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
                    actions: widget.actions,
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
                  _settings.updateChannel = value.value;
                  unawaited(_settings.save());
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
                  _settings.updateSource = value.value;
                  unawaited(_settings.save());
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
                ),
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
          limitBytes: widget.actions.memoryLimits.rawRetentionLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.rawTextCacheMemoryLimit,
          subtitle: AppStrings.appInfo.rawTextCacheMemoryLimitSummary,
          usedBytes: rawTextCacheUsedBytes,
          limitBytes: widget.actions.memoryLimits.rawTextCacheLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.shellQueueMemoryLimit,
          subtitle: AppStrings.appInfo.shellQueueMemoryLimitSummary,
          usedBytes: shellQueueUsedBytes,
          limitBytes: widget.actions.memoryLimits.shellQueueLimitBytes,
        ),
        _MemoryLimitRow(
          title: AppStrings.appInfo.ymodemQueueMemoryLimit,
          subtitle: AppStrings.appInfo.ymodemQueueMemoryLimitSummary,
          usedBytes: ymodemQueueUsedBytes,
          limitBytes: widget.actions.memoryLimits.ymodemQueueLimitBytes,
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
    final settings = _settings;
    _rttBackendAvailability ??= widget.actions.probeDetection
        .checkBackendAvailability(prepareBundledOpenOcd: false);

    void refreshAvailability({bool prepareBundledOpenOcd = false}) {
      setDialogState(() {
        _rttBackendAvailability = widget.actions.probeDetection
            .checkBackendAvailability(
              prepareBundledOpenOcd: prepareBundledOpenOcd,
            );
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDialogTextField(
          controller: _rttJlinkPathController,
          labelText: AppStrings.appInfo.jlinkExecutablePath,
          helperText: AppStrings.appInfo.jlinkExecutablePathHelp,
          onChanged: (value) {
            settings.rttJlinkExecutablePath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        AppDialogTextField(
          controller: _rttOpenocdPathController,
          labelText: AppStrings.appInfo.externalOpenOcdPath,
          helperText: AppStrings.appInfo.externalOpenOcdPathHelp,
          onChanged: (value) {
            settings.rttOpenocdExecutablePath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        AppDialogTextField(
          controller: _rttPyocdPythonPathController,
          labelText: AppStrings.appInfo.externalPyOcdPythonPath,
          helperText: AppStrings.appInfo.externalPyOcdPythonPathHelp,
          onChanged: (value) {
            settings.rttPyocdPythonPath = value.trim();
            unawaited(settings.save());
          },
          onSubmitted: (_) => refreshAvailability(),
        ),
        const SizedBox(height: 12),
        FutureBuilder<Map<String, ProbeBackendAvailability>>(
          future: _rttBackendAvailability,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return Text(AppStrings.appInfo.detectingProbeBackends);
            }

            String state(String id) {
              final status = snapshot.data![id];
              if (status == null || !status.available) {
                return AppStrings.appInfo.backendNotDetected;
              }
              final version = status.version?.trim();
              return version == null || version.isEmpty
                  ? AppStrings.appInfo.backendDetectedUnknownVersion
                  : version;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.appInfo.probeBackendState(
                    'J-Link',
                    state('external-jlink'),
                  ),
                ),
                Text(
                  AppStrings.appInfo.probeBackendState(
                    '内置 OpenOCD',
                    state('bundled-openocd'),
                  ),
                ),
                Text(
                  AppStrings.appInfo.probeBackendState(
                    '外置 OpenOCD',
                    state('external-openocd'),
                  ),
                ),
                Text(
                  AppStrings.appInfo.probeBackendState(
                    '外置 pyOCD',
                    state('external-pyocd'),
                  ),
                ),
              ],
            );
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => refreshAvailability(prepareBundledOpenOcd: true),
            icon: const Icon(Icons.refresh),
            label: Text(AppStrings.appInfo.redetect),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedSettingsDialog(BuildContext dialogContext) {
    final settings = _settings;
    var disableNotifications = _disableNotifications;
    var diagnosticLoggingEnabled = settings.diagnosticLoggingEnabled;
    var crashDumpEnabled = settings.crashDumpEnabled;
    var connectionShortcutsEnabled = settings.connectionShortcutsEnabled;
    var networkConnectionsEnabled = settings.networkConnectionsEnabled;
    var separateSerialProfiles = settings.separateSerialProfiles;
    final sshStatus = widget.actions.sshStatus;
    // 探针后端属于连接能力设置，即使当前未显示探针页面也允许预先配置。
    const rttEnabled = true;
    final notificationSectionKey = GlobalKey();
    final diagnosticsSectionKey = GlobalKey();
    final shortcutsSectionKey = GlobalKey();
    final pageSectionKey = GlobalKey();
    final probeBackendSectionKey = GlobalKey();
    final memorySectionKey = GlobalKey();
    final rollbackSectionKey = GlobalKey();
    final resetSectionKey = GlobalKey();
    return StatefulBuilder(
      builder:
          (context, setDialogState) => AppSettingsDialog(
            title: Text(AppStrings.common.advancedSettings),
            size: AppDialogSize.navigation,
            changeListenables: [_plotHistoryLimitController],
            hasUnsavedChanges:
                () =>
                    disableNotifications != settings.disableNotifications ||
                    diagnosticLoggingEnabled !=
                        settings.diagnosticLoggingEnabled ||
                    crashDumpEnabled != settings.crashDumpEnabled ||
                    connectionShortcutsEnabled !=
                        settings.connectionShortcutsEnabled ||
                    networkConnectionsEnabled !=
                        settings.networkConnectionsEnabled ||
                    separateSerialProfiles != settings.separateSerialProfiles ||
                    _plotHistoryLimitController.text !=
                        '${settings.plotHistoryMemoryLimitGiB}',
            onSave: () async {
              final plotLimit = int.tryParse(
                _plotHistoryLimitController.text.trim(),
              );
              if (plotLimit == null ||
                  plotLimit < PlotConfiguration.minHistoryMemoryLimitGiB ||
                  plotLimit > PlotConfiguration.maxHistoryMemoryLimitGiB) {
                throw FormatException(
                  AppStrings.appInfo.invalidPlotHistoryLimit,
                );
              }
              final dataConnection = widget.actions.dataConnection;
              if (dataConnection.isConnectionBusy() &&
                  (networkConnectionsEnabled !=
                          settings.networkConnectionsEnabled ||
                      separateSerialProfiles !=
                          settings.separateSerialProfiles)) {
                throw StateError(
                  AppStrings.appInfo.connectionBusySettingsError,
                );
              }
              final plotViewModel = dialogContext.read<PlotViewModel>();
              final modbusActions = widget.actions.modbus;
              final shellViewModel = dialogContext.read<ShellViewModel?>();
              final oldDisableNotifications = settings.disableNotifications;
              final oldDiagnosticLogging = settings.diagnosticLoggingEnabled;
              final oldCrashDump = settings.crashDumpEnabled;
              final oldConnectionShortcuts =
                  settings.connectionShortcutsEnabled;
              final oldNetworkConnections = settings.networkConnectionsEnabled;
              final oldSeparateProfiles = settings.separateSerialProfiles;
              final oldSerialProfiles = {
                for (final entry in settings.serialPageProfiles.entries)
                  entry.key: entry.value.copyWith(),
              };
              final oldPlotLimit = settings.plotHistoryMemoryLimitGiB;
              try {
                if (crashDumpEnabled != oldCrashDump) {
                  await widget.actions.crashDump.setEnabled(crashDumpEnabled);
                }
                settings
                  ..disableNotifications = disableNotifications
                  ..diagnosticLoggingEnabled = diagnosticLoggingEnabled
                  ..crashDumpEnabled = crashDumpEnabled
                  ..connectionShortcutsEnabled = connectionShortcutsEnabled
                  ..networkConnectionsEnabled = networkConnectionsEnabled
                  ..setSeparateSerialProfiles(separateSerialProfiles)
                  ..plotHistoryMemoryLimitGiB = plotLimit;
                await settings.save();
              } catch (_) {
                settings
                  ..disableNotifications = oldDisableNotifications
                  ..diagnosticLoggingEnabled = oldDiagnosticLogging
                  ..crashDumpEnabled = oldCrashDump
                  ..connectionShortcutsEnabled = oldConnectionShortcuts
                  ..networkConnectionsEnabled = oldNetworkConnections
                  ..separateSerialProfiles = oldSeparateProfiles
                  ..serialPageProfiles = oldSerialProfiles
                  ..plotHistoryMemoryLimitGiB = oldPlotLimit;
                if (crashDumpEnabled != oldCrashDump) {
                  try {
                    await widget.actions.crashDump.setEnabled(oldCrashDump);
                  } catch (_) {
                    // 保留原始保存错误；下次启动会根据已恢复的设置重新同步原生状态。
                  }
                }
                rethrow;
              }
              setState(() => _disableNotifications = disableNotifications);
              AppLogger().setDiagnosticEnabled(diagnosticLoggingEnabled);
              dataConnection.setNetworkConnectionsEnabled(
                networkConnectionsEnabled,
              );
              dataConnection.selectSerialProfile('rawData', forceReload: true);
              plotViewModel.syncPlotRetentionLimitFromSettings(plotLimit);
              if (!networkConnectionsEnabled) {
                if (modbusActions?.mode() == ModbusMode.tcp) {
                  await modbusActions!.setMode(ModbusMode.rtu);
                }
                if (shellViewModel?.connectionMode == ShellConnectionMode.ssh) {
                  await shellViewModel!.setConnectionMode(
                    ShellConnectionMode.normal,
                  );
                }
              }
            },
            child: SettingsNavigationView(
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
                  AppSwitchRow(
                    key: notificationSectionKey,
                    title: Text(AppStrings.appInfo.disableNotifications),
                    subtitle: Text(AppStrings.appInfo.disableNotificationsHelp),
                    value: disableNotifications,
                    onChanged: (value) {
                      setDialogState(() => disableNotifications = value);
                    },
                  ),
                  const Divider(height: 16),
                  AppSwitchRow(
                    key: diagnosticsSectionKey,
                    title: Text(AppStrings.appInfo.diagnosticLogging),
                    subtitle: Text(AppStrings.appInfo.diagnosticLoggingHelp),
                    value: diagnosticLoggingEnabled,
                    onChanged: (value) {
                      setDialogState(() => diagnosticLoggingEnabled = value);
                    },
                  ),
                  AppSwitchRow(
                    title: Text(AppStrings.appInfo.crashDump),
                    subtitle: Text(AppStrings.appInfo.crashDumpHelp),
                    value: crashDumpEnabled,
                    onChanged:
                        (value) =>
                            setDialogState(() => crashDumpEnabled = value),
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
                  AppSwitchRow(
                    key: shortcutsSectionKey,
                    title: Text(AppStrings.appInfo.enableConnectionShortcuts),
                    subtitle: Text(
                      AppStrings.appInfo.enableConnectionShortcutsHelp,
                    ),
                    value: connectionShortcutsEnabled,
                    onChanged: (value) {
                      setDialogState(() => connectionShortcutsEnabled = value);
                    },
                  ),
                  const Divider(height: 16),
                  AppSwitchRow(
                    key: pageSectionKey,
                    title: Text(AppStrings.appInfo.enableNetworkConnections),
                    subtitle: Text(
                      AppStrings.appInfo.enableNetworkConnectionsHelp,
                    ),
                    value: networkConnectionsEnabled,
                    onChanged:
                        (widget.actions.dataConnection.isNetworkConnection() &&
                                    widget.actions.dataConnection
                                        .isConnectionBusy()) ||
                                (sshStatus?.isConnected() ?? false) ||
                                (sshStatus?.isConnecting() ?? false)
                            ? null
                            : (value) {
                              setDialogState(
                                () => networkConnectionsEnabled = value,
                              );
                            },
                  ),
                  AppSwitchRow(
                    title: Text(AppStrings.appInfo.separateSerialProfiles),
                    subtitle: Text(
                      AppStrings.appInfo.separateSerialProfilesHelp,
                    ),
                    value: separateSerialProfiles,
                    onChanged:
                        widget.actions.dataConnection.isConnectionBusy()
                            ? null
                            : (value) {
                              setDialogState(
                                () => separateSerialProfiles = value,
                              );
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
                  KeyedSubtree(
                    key: memorySectionKey,
                    child: StreamBuilder<int>(
                      stream: Stream<int>.periodic(
                        const Duration(milliseconds: 500),
                        (tick) => tick,
                      ),
                      builder: (context, _) {
                        final plotViewModel = context.read<PlotViewModel>();
                        final rttViewModel = context.read<RttViewModel?>();
                        final plotUsage = plotViewModel.plotRetentionUsage;
                        return _buildMemoryLimitsSection(
                          context,
                          plotHistoryLimitGiB:
                              plotViewModel.plotRetentionLimitGiB,
                          plotHistoryUsedBytes: plotUsage.usedBytes,
                          processRssBytes: ProcessInfo.currentRss,
                          rawRetentionUsedBytes:
                              widget.actions.dataConnection
                                  .rawRetentionUsedBytes(),
                          rawTextCacheUsedBytes:
                              widget.actions.dataConnection
                                  .rawTextCacheUsedBytes(),
                          shellQueueUsedBytes:
                              widget.actions.dataConnection
                                  .shellQueueUsedBytes(),
                          ymodemQueueUsedBytes:
                              widget.actions.dataConnection
                                  .ymodemQueueUsedBytes(),
                          rttQueueUsedBytes:
                              widget.actions.probeDetection.queuedBytes(),
                          rttRawHistoryUsedBytes:
                              rttViewModel?.rawHistoryBytes ?? 0,
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
                              settings.plotHistoryMemoryLimitGiB;
                          context
                              .read<PlotViewModel>()
                              .setPlotRetentionLimitGiB(resetPlotLimit);
                          setDialogState(() {
                            disableNotifications =
                                settings.disableNotifications;
                            diagnosticLoggingEnabled =
                                settings.diagnosticLoggingEnabled;
                            crashDumpEnabled = settings.crashDumpEnabled;
                            connectionShortcutsEnabled =
                                settings.connectionShortcutsEnabled;
                            networkConnectionsEnabled =
                                settings.networkConnectionsEnabled;
                            separateSerialProfiles =
                                settings.separateSerialProfiles;
                            _plotHistoryLimitController.text =
                                resetPlotLimit.toString();
                          });
                          try {
                            await widget.actions.crashDump.setEnabled(
                              settings.crashDumpEnabled,
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
      await _settings.flushPendingSave();
      AppLogger().fatal('用户从 Debug 高级设置主动触发原生崩溃测试', category: 'APP');
      await AppLogger().flush();
      widget.actions.crashDump.triggerTestCrash();
    } catch (error, stackTrace) {
      AppLogger().error(
        '触发原生崩溃测试失败: $error',
        category: 'APP',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        widget.actions.showNotification('触发原生崩溃测试失败：$error');
      }
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
                      style: const TextStyle(fontWeight: FontWeight.w600),
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

    await _settings.resetToDefaults();
    if (!mounted) return true;
    final settings = _settings;
    setState(() {
      _autoUpdateCheckEnabled = settings.autoUpdateCheckEnabled;
      _disableNotifications = settings.disableNotifications;
      _updateChannel = UpdateChannel.fromString(settings.updateChannel);
      _updateSourcePreference = UpdateSourcePreference.fromString(
        settings.updateSource,
      );
      _lastResult = null;
    });
    widget.actions.showNotification(
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
    final result = await widget.actions.update.checkForUpdate(
      _updateChannel,
      _updateSourcePreference,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastResult = result;
    });
  }

  Future<void> _loadRollbackUpdates() async {
    setState(() => _loadingRollback = true);
    final updates = await widget.actions.update.findRollbackUpdates();
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
      final updateActions = widget.actions.update;
      final canProceed = await _confirmAndCloseOtherInstances(updateActions);
      if (!canProceed) return;
      await updateActions.launchRollbackInstaller(update);
      if (mounted) Navigator.of(context).pop();
      await windowManager.close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastResult = UpdateCheckResult.failed(error.toString());
      });
    }
  }

  Future<bool> _confirmAndCloseOtherInstances(UpdateActions actions) async {
    final otherInstances = await actions.findOtherRunningInstanceProcessIds();
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
    await actions.requestCloseOtherRunningInstances(otherInstances);
    final closed = await actions.waitForOtherRunningInstancesToExit(
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
  final List<ChangelogLine> Function(String body) parseBody;

  const _ChangelogPreview({required this.entries, required this.parseBody});

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
                        _ChangelogBody(body: entry.body, parseBody: parseBody),
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
  final List<ChangelogLine> Function(String body) parseBody;

  const _ChangelogBody({required this.body, required this.parseBody});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final lines = parseBody(body);

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
