import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/constants/terminal_fonts.dart';
import '../../core/localization/app_strings.dart';
import '../../data/models/rtt_config.dart';
import '../../services/app_settings.dart';
import '../../services/rtt_backend.dart';
import '../../services/rtt_service.dart';
import '../../services/shell_stream_decoder.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../widgets/common_widgets.dart';

Future<void> showRttSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _RttSettingsDialog(),
  );
}

class _RttSettingsDialog extends StatefulWidget {
  const _RttSettingsDialog();

  @override
  State<_RttSettingsDialog> createState() => _RttSettingsDialogState();
}

class _RttSettingsDialogState extends State<_RttSettingsDialog> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _displayKey = GlobalKey();
  final GlobalKey _connectionKey = GlobalKey();
  final GlobalKey _backendKey = GlobalKey();
  late final TextEditingController _historyController;
  late final TextEditingController _jlinkPathController;
  late final TextEditingController _pyocdPathController;
  late final TextEditingController _helperPathController;
  late final TextEditingController _fontSizeController;
  late final TextEditingController _clockController;
  late final TextEditingController _addressController;
  late final TextEditingController _rangeStartController;
  late final TextEditingController _rangeEndController;
  late RttControlBlockMode _controlBlockMode;
  Future<Map<String, RttBackendAvailability>>? _availability;
  String? _fontSizeError;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _historyController = TextEditingController(
      text: '${settings.rttHistoryLineLimit}',
    );
    _jlinkPathController = TextEditingController(
      text: settings.rttJlinkExecutablePath,
    );
    _pyocdPathController = TextEditingController(
      text: settings.rttPyocdExecutablePath,
    );
    _helperPathController = TextEditingController(
      text: settings.rttBuiltinHelperPath,
    );
    _fontSizeController = TextEditingController(
      text: settings.rttFontSize.round().toString(),
    );
    _clockController = TextEditingController(text: '${settings.rttClockKhz}');
    _addressController = TextEditingController(
      text:
          settings.rttControlBlockAddress == null
              ? ''
              : '0x${settings.rttControlBlockAddress!.toRadixString(16)}',
    );
    _rangeStartController = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeStart),
    );
    _rangeEndController = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeEnd),
    );
    _controlBlockMode = RttControlBlockMode.fromString(
      settings.rttControlBlockMode,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _availability ??= context.read<RttService>().checkBackendAvailability();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _historyController.dispose();
    _jlinkPathController.dispose();
    _pyocdPathController.dispose();
    _helperPathController.dispose();
    _fontSizeController.dispose();
    _clockController.dispose();
    _addressController.dispose();
    _rangeStartController.dispose();
    _rangeEndController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RttViewModel>();
    final settings = AppSettings();
    return AlertDialog(
      shape: kAdvancedSettingsDialogShape,
      title: Text(AppStrings.rtt.settings),
      content: SettingsNavigationView(
        scrollController: _scrollController,
        items: [
          SettingsNavigationItem(label: '显示', anchorKey: _displayKey),
          SettingsNavigationItem(label: '连接', anchorKey: _connectionKey),
          SettingsNavigationItem(label: '后端', anchorKey: _backendKey),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              key: _displayKey,
              '文本编码',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: vm.encoding,
                  hint: '选择文本编码',
                  decoration: secondaryDialogFieldDecoration(),
                  items:
                      shellTextEncodings
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) vm.setEncoding(value);
                  },
                ),
              ),
            ),
            const Divider(height: 24),
            const Text('终端字体', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: vm.fontFamily,
                  hint: '选择终端字体',
                  decoration: secondaryDialogFieldDecoration(),
                  items:
                      terminalFontFamilies
                          .map(
                            (font) => DropdownMenuItem(
                              value: font,
                              child: Text(font),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) vm.setFontFamily(value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('字号', style: TextStyle(fontSize: 14)),
                const Spacer(),
                SizedBox(
                  width: kSecondaryDialogFieldWidth,
                  child: TextField(
                    key: const ValueKey('rtt-font-size-field'),
                    controller: _fontSizeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: secondaryDialogFieldDecoration(
                      suffixText: 'px',
                    ).copyWith(errorText: _fontSizeError),
                    onChanged: (text) {
                      final value = double.tryParse(text);
                      if (value == null || value < 10 || value > 24) {
                        setState(() {
                          _fontSizeError =
                              AppStrings.raw.terminalFontSizeInvalid;
                        });
                        return;
                      }
                      setState(() => _fontSizeError = null);
                      vm.setFontSize(value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('字体示例', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Container(
              key: const ValueKey('rtt-font-preview'),
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'SerialTools RTT  中文终端\nAa Bb 0123456789  > _',
                style: TextStyle(
                  fontFamily: vm.fontFamily,
                  fontSize: vm.fontSize,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _historyController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '历史行数',
                helperText:
                    '范围 1000~1000000 行，当前原始历史 '
                    '${(vm.rawHistoryBytes / 1024 / 1024).toStringAsFixed(1)} MiB',
                suffixIcon: IconButton(
                  tooltip: '应用',
                  onPressed: () {
                    final value = int.tryParse(_historyController.text);
                    if (value != null) vm.setHistoryLineLimit(value);
                    _historyController.text = '${vm.historyLineLimit}';
                  },
                  icon: const Icon(Icons.check),
                ),
              ),
            ),
            const Divider(height: 24),
            DropdownButtonFormField<RttWireProtocol>(
              key: _connectionKey,
              initialValue: RttWireProtocol.fromString(
                settings.rttWireProtocol,
              ),
              decoration: const InputDecoration(labelText: '默认调试接口'),
              items:
                  RttWireProtocol.values
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(item.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value == null) return;
                settings.rttWireProtocol = value.value;
                unawaited(settings.save());
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _clockController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '默认调试时钟',
                suffixText: 'kHz',
              ),
              onChanged: (value) {
                final clock = int.tryParse(value);
                if (clock == null) return;
                settings.rttClockKhz = clock.clamp(100, 50000);
                unawaited(settings.save());
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RttControlBlockMode>(
              initialValue: _controlBlockMode,
              decoration: const InputDecoration(labelText: '默认 RTT 控制块定位'),
              items:
                  RttControlBlockMode.values
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(item.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _controlBlockMode = value);
                settings.rttControlBlockMode = value.value;
                unawaited(settings.save());
              },
            ),
            const SizedBox(height: 6),
            Text(
              _controlBlockMode.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (_controlBlockMode == RttControlBlockMode.address) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: '默认 RTT 控制块地址',
                  helperText: '可输入十进制或 0x 开头的十六进制地址',
                ),
                onChanged: (value) {
                  settings.rttControlBlockAddress = _parseAddress(value.trim());
                  unawaited(settings.save());
                },
              ),
            ],
            if (_controlBlockMode == RttControlBlockMode.range) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rangeStartController,
                      decoration: const InputDecoration(labelText: '默认搜索起始地址'),
                      onChanged: (value) {
                        settings.rttControlBlockRangeStart = _parseAddress(
                          value.trim(),
                        );
                        unawaited(settings.save());
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rangeEndController,
                      decoration: const InputDecoration(labelText: '默认搜索结束地址'),
                      onChanged: (value) {
                        settings.rttControlBlockRangeEnd = _parseAddress(
                          value.trim(),
                        );
                        unawaited(settings.save());
                      },
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 24),
            DropdownButtonFormField<RttBackendMode>(
              key: _backendKey,
              initialValue: RttBackendMode.fromString(settings.rttBackendMode),
              decoration: const InputDecoration(labelText: '后端模式'),
              items:
                  RttBackendMode.values
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(item.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value == null) return;
                settings.rttBackendMode = value.value;
                unawaited(settings.save());
              },
            ),
            const SizedBox(height: 6),
            Text(
              '自动：优先使用对应探针的外部工具；仅在外部工具不可用时回退内置后端，连接失败时不会自动切换。\n'
              '外部：强制使用 JLinkGDBServerCL 或 pyOCD，工具不可用或连接失败时直接报错。\n'
              '内置：强制使用随应用发布的 probe_helper.exe（probe-rs），不启动外部工具。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _jlinkPathController,
              decoration: const InputDecoration(
                labelText: 'JLinkGDBServerCL.exe 路径',
                helperText: '留空时从 SEGGER 安装目录和 PATH 自动查找',
              ),
              onChanged: (value) {
                settings.rttJlinkExecutablePath = value.trim();
                unawaited(settings.save());
              },
              onSubmitted: (_) => _refreshAvailability(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pyocdPathController,
              decoration: const InputDecoration(
                labelText: 'pyocd.exe 路径',
                helperText: '留空时从 PATH 自动查找',
              ),
              onChanged: (value) {
                settings.rttPyocdExecutablePath = value.trim();
                unawaited(settings.save());
              },
              onSubmitted: (_) => _refreshAvailability(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _helperPathController,
              decoration: const InputDecoration(
                labelText: '内置探针辅助进程路径',
                helperText: '留空时使用随应用发布的 probe_helper.exe',
              ),
              onChanged: (value) {
                settings.rttBuiltinHelperPath = value.trim();
                unawaited(settings.save());
              },
              onSubmitted: (_) => _refreshAvailability(),
            ),
            const SizedBox(height: 12),
            FutureBuilder<Map<String, RttBackendAvailability>>(
              future: _availability,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Text('正在检测 RTT 后端...');
                }
                String state(String id) {
                  final status = snapshot.data![id];
                  if (status == null || !status.available) return '未检测到';
                  final version = status.version?.trim();
                  return version == null || version.isEmpty
                      ? '已检测到（版本未知）'
                      : version;
                }

                return Text(
                  'J-Link: ${state('external-jlink')}    '
                  'pyOCD: ${state('external-pyocd')}    '
                  '内置: ${state('builtin-probe-rs')}',
                );
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _refreshAvailability,
                icon: const Icon(Icons.refresh),
                label: const Text('重新检测'),
              ),
            ),
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

  int? _parseAddress(String value) {
    final hex = value.startsWith('0x') || value.startsWith('0X');
    return int.tryParse(hex ? value.substring(2) : value, radix: hex ? 16 : 10);
  }

  void _refreshAvailability() {
    setState(() {
      _availability = context.read<RttService>().checkBackendAvailability();
    });
  }
}

String _formatAddress(int? value) =>
    value == null ? '' : '0x${value.toRadixString(16)}';
