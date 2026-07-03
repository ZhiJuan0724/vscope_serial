import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/localization/app_strings.dart';
import '../../services/app_info.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/changelog_service.dart';
import '../../services/update_checker.dart';
import '../../services/update_service.dart';
import '../widgets/common_widgets.dart';

Future<void> showAppInfoDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const AppInfoDialog(),
  );
}

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

Widget _scrollWithoutScrollbar(BuildContext context, {required Widget child}) {
  return ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}

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
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await _service.launchInstaller(prepared, channel: _channel);
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

  static String _formatBytes(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${bytes.toStringAsFixed(0)} B';
  }
}

class AppInfoDialog extends StatefulWidget {
  const AppInfoDialog({super.key});

  @override
  State<AppInfoDialog> createState() => _AppInfoDialogState();
}

class _AppInfoDialogState extends State<AppInfoDialog> {
  final _checker = UpdateChecker();
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
    _loadRollbackUpdates();
  }

  @override
  Widget build(BuildContext context) {
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
        width: 360,
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
                  _InfoRow(
                    label: AppStrings.appInfo.appName,
                    value: AppInfo.name,
                  ),
                  _InfoRow(
                    label: AppStrings.appInfo.version,
                    value: _version ?? AppStrings.appInfo.loading,
                  ),
                  _InfoRow(
                    label: AppStrings.appInfo.buildTime,
                    value: _formatBuildTime(_buildTime),
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
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(AppStrings.appInfo.autoCheckUpdates),
                    subtitle: Text(AppStrings.appInfo.autoCheckUpdatesHelp),
                    value: _autoUpdateCheckEnabled,
                    onChanged: (value) {
                      setState(() => _autoUpdateCheckEnabled = value);
                      final settings =
                          AppSettings()..autoUpdateCheckEnabled = value;
                      settings.save();
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(AppStrings.appInfo.updateChannelTitle),
                    subtitle: Text(
                      _updateChannel == UpdateChannel.beta
                          ? AppStrings.appInfo.betaChannelHelp
                          : AppStrings.appInfo.stableChannelHelp,
                    ),
                    trailing: SizedBox(
                      width: 116,
                      child: NoAnimDropdown<UpdateChannel>(
                        value: _updateChannel,
                        hint: AppStrings.appInfo.updateChannelTitle,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
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
                          final settings =
                              AppSettings()..updateChannel = value.value;
                          settings.save();
                        },
                      ),
                    ),
                  ),
                  _buildUpdateSourceTile(),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _checking ? null : _checkForUpdate,
                        icon:
                            _checking
                                ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.update, size: 16),
                        label: Text(
                          _checking
                              ? AppStrings.appInfo.checking
                              : AppStrings.appInfo.manualCheckUpdates,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
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
                      OutlinedButton.icon(
                        onPressed: _showAdvancedSettings,
                        icon: const Icon(Icons.tune, size: 16),
                        label: Text(AppStrings.common.advancedSettings),
                      ),
                    ],
                  ),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.close),
        ),
      ],
    );
  }

  Widget _buildUpdateSourceTile() {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(AppStrings.appInfo.updateSourceTitle),
      subtitle: Text(
        _updateSourcePreference == UpdateSourcePreference.auto
            ? AppStrings.appInfo.updateSourceAutoHelp
            : AppStrings.appInfo.updateSourceLockedHelp(
              _updateSourcePreference.label,
            ),
      ),
      trailing: SizedBox(
        width: 116,
        child: NoAnimDropdown<UpdateSourcePreference>(
          value: _updateSourcePreference,
          hint: AppStrings.appInfo.updateSourceTitle,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          items: UpdateSourcePreference.values
              .map(
                (source) =>
                    DropdownMenuItem(value: source, child: Text(source.label)),
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

  Future<void> _showAdvancedSettings() async {
    var disableNotifications = _disableNotifications;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: Text(AppStrings.common.advancedSettings),
                  content: SizedBox(
                    width: 360,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: _dialogContentMaxHeight(context),
                      ),
                      child: _scrollWithoutScrollbar(
                        context,
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(
                                  AppStrings.appInfo.disableNotifications,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  AppStrings.appInfo.disableNotificationsHelp,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.copyWith(
                                    color:
                                        Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                value: disableNotifications,
                                onChanged: (value) {
                                  setDialogState(
                                    () => disableNotifications = value,
                                  );
                                  setState(() => _disableNotifications = value);
                                  final settings =
                                      AppSettings()
                                        ..disableNotifications = value;
                                  settings.save();
                                },
                              ),
                              const Divider(height: 16),
                              _buildRollbackSection(context),
                              const Divider(height: 16),
                              _buildResetSettingsSection(
                                context,
                                onReset: () async {
                                  final didReset =
                                      await _confirmResetSettings();
                                  if (didReset) {
                                    setDialogState(() {
                                      disableNotifications =
                                          AppSettings().disableNotifications;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(AppStrings.common.close),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<bool> _confirmResetSettings() async {
    final confirmText = AppStrings.appInfo.resetSettings;
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
                    Text(AppStrings.appInfo.enterConfirmText(confirmText)),
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
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
                        input == confirmText
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
      await UpdateService().launchRollbackInstaller(update);
      if (mounted) Navigator.of(context).pop();
      await windowManager.close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastResult = UpdateCheckResult.failed(error.toString());
      });
    }
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

class _ChangelogPreview extends StatelessWidget {
  final List<ChangelogEntry> entries;

  const _ChangelogPreview({required this.entries});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
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

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '$label:',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
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
