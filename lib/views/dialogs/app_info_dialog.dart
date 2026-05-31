import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/app_info.dart';
import '../../services/app_settings.dart';
import '../../services/update_checker.dart';

Future<void> showAppInfoDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const AppInfoDialog(),
  );
}

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseInfo release,
) async {
  final currentVersion = await AppInfo.displayVersion();
  if (!context.mounted) return;
  return showDialog(
    context: context,
    builder:
        (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('发现新版本'),
          content: Text(
            '当前版本: $currentVersion\n'
            '最新版本: ${release.tagName}\n'
            '来源: ${release.source}\n\n'
            '当前版本仅提示更新。Windows 程序运行时不能可靠覆盖自身，'
            '后续如需自动安装，需要外置更新程序在主程序退出后解压并替换文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后'),
            ),
            ElevatedButton(
              onPressed: () {
                _openUrl(release.htmlUrl);
                Navigator.of(context).pop();
              },
              child: const Text('打开发布页'),
            ),
          ],
        ),
  );
}

class AppInfoDialog extends StatefulWidget {
  const AppInfoDialog({super.key});

  @override
  State<AppInfoDialog> createState() => _AppInfoDialogState();
}

class _AppInfoDialogState extends State<AppInfoDialog> {
  final _checker = UpdateChecker();
  bool _autoUpdateCheckEnabled = AppSettings().autoUpdateCheckEnabled;
  bool _checking = false;
  String? _version;
  DateTime? _buildTime;
  UpdateCheckResult? _lastResult;

  @override
  void initState() {
    super.initState();
    AppInfo.displayVersion().then((value) {
      if (mounted) setState(() => _version = value);
    });
    AppInfo.buildTime().then((value) {
      if (mounted) setState(() => _buildTime = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final release = _lastResult?.latestRelease;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: const Row(
        children: [Icon(Icons.info_outline), SizedBox(width: 8), Text('应用信息')],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: '应用名称', value: AppInfo.name),
            _InfoRow(label: '版本', value: _version ?? '读取中...'),
            _InfoRow(label: '构建时间', value: _formatBuildTime(_buildTime)),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启动时自动检查更新'),
              subtitle: const Text('默认关闭；开启后每次打开应用会访问 GitHub，失败后尝试 Gitee'),
              value: _autoUpdateCheckEnabled,
              onChanged: (value) {
                setState(() => _autoUpdateCheckEnabled = value);
                final settings = AppSettings()..autoUpdateCheckEnabled = value;
                settings.save();
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _checking ? null : _checkForUpdate,
                  icon:
                      _checking
                          ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.update, size: 16),
                  label: Text(_checking ? '检查中...' : '手动检查更新'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('自动安装预留'),
                ),
              ],
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              Text(
                _resultText(_lastResult!, _version ?? '未知'),
                style: TextStyle(
                  fontSize: 12,
                  color:
                      _lastResult!.error != null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_lastResult!.hasUpdate && release != null) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _openUrl(release.htmlUrl),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text('打开 ${release.source} 发布页'),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() {
      _checking = true;
      _lastResult = null;
    });
    final result = await _checker.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastResult = result;
    });
  }

  static String _formatBuildTime(DateTime? time) {
    if (time == null) return '未知';
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
    if (release == null) return '未获取到版本信息';
    if (result.hasUpdate) {
      return '发现新版本 ${release.tagName}（${release.source}）';
    }
    return '未发现更新（当前版本: $currentVersion；'
        '最新发布版本: ${release.tagName}，${release.source}）';
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
