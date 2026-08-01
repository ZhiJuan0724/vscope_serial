import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/rtt_configuration.dart';
import '../../data/models/probe_connection_config.dart';
import '../../core/localization/app_strings.dart';
import '../../services/app_notifications.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../dialogs/rtt_settings_dialog.dart';
import '../dialogs/rtt_control_block_dialog.dart';
import '../widgets/common_widgets.dart';

/// RTT Viewer 多虚拟终端查看与 Down 0 输入页面。
class RttPage extends StatefulWidget {
  const RttPage({super.key});

  @override
  State<RttPage> createState() => _RttPageState();
}

class _RttPageState extends State<RttPage> {
  static const Color _viewerOptionActiveColor = Colors.orange;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  int _lastOutputRevision = 0;
  bool _terminalPanelCollapsed = false;
  bool _activityChanging = false;
  bool _activityStopping = false;
  String _lineEnding = '\r\n';

  @override
  void dispose() {
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _toggleActivity(RttViewModel vm) async {
    if (_activityChanging) return;
    final stopping = vm.service.activityOwner == ProbeActivityOwner.rttViewer;
    setState(() {
      _activityChanging = true;
      _activityStopping = stopping;
    });
    try {
      if (stopping) {
        await vm.service.stopActivity();
      } else {
        await vm.service.startRttViewer();
      }
    } catch (error) {
      AppNotifications.show('RTT Viewer 操作失败: $error');
    } finally {
      if (mounted) {
        setState(() {
          _activityChanging = false;
          _activityStopping = false;
        });
      }
    }
  }

  Future<void> _send(RttViewModel vm) async {
    final value = _inputController.text;
    if (value.isEmpty) return;
    try {
      if (vm.displayMode == RttDisplayMode.hex) {
        await vm.sendHex(value);
      } else {
        await vm.sendText(value, lineEnding: _lineEnding);
      }
      _inputController.clear();
    } catch (error) {
      AppNotifications.show('RTT 发送失败: $error');
    }
  }

  void _followOutput(RttViewModel vm) {
    if (!vm.autoScroll || vm.outputRevision == _lastOutputRevision) return;
    _lastOutputRevision = vm.outputRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || !vm.autoScroll) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _export(RttViewModel vm, {required bool binary}) async {
    final path = await FilePicker.saveFile(
      dialogTitle: binary ? '导出 RTT 原始数据' : '导出 RTT 文本',
      fileName: binary ? 'rtt-channel0.bin' : 'rtt-channel0.txt',
      type: FileType.custom,
      allowedExtensions: binary ? const ['bin'] : const ['txt'],
    );
    if (path == null) return;
    final outputPath = _ensureExtension(path, binary ? 'bin' : 'txt');
    try {
      if (binary) {
        await vm.exportBinary(outputPath);
      } else {
        await vm.exportText(outputPath);
      }
      AppNotifications.show('RTT 数据已导出');
    } catch (error) {
      AppNotifications.show('RTT 导出失败: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RttViewModel>(
      builder: (context, vm, _) {
        _followOutput(vm);
        final service = vm.service;
        final lines = vm.lines;
        final partialLine = vm.partialLine.replaceAll('\r', '');
        final visibleItemCount = lines.length + (partialLine.isEmpty ? 0 : 1);
        final hasExportData = vm.rawHistoryBytes > 0;
        return Column(
          children: [
            UnifiedToolbar(
              leadingItems: [
                ToolbarLayoutItem(
                  extent: 76,
                  child: ToolbarStartStopButton(
                    running:
                        service.activityOwner == ProbeActivityOwner.rttViewer,
                    tooltip:
                        _activityChanging
                            ? _activityStopping
                                ? '正在停止并重新连接'
                                : '正在启动 RTT Viewer'
                            : service.activityOwner ==
                                ProbeActivityOwner.rttViewer
                            ? '停止 RTT Viewer'
                            : '开始 RTT Viewer',
                    label:
                        _activityChanging
                            ? _activityStopping
                                ? '停止中'
                                : '启动中'
                            : service.activityOwner ==
                                ProbeActivityOwner.rttViewer
                            ? '停止'
                            : '开始',
                    onPressed:
                        service.isConnected && !_activityChanging
                            ? () => unawaited(_toggleActivity(vm))
                            : null,
                  ),
                ),
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarIconButton(
                    key: const ValueKey('rtt-activity-settings-button'),
                    icon: const Icon(Icons.settings),
                    tooltip: 'RTT 接收配置',
                    onPressed:
                        service.activityOwner == ProbeActivityOwner.none
                            ? () => showRttControlBlockDialog(
                              context,
                              service: service,
                              title: 'RTT Viewer 接收配置',
                            )
                            : null,
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.settings),
                      label: 'RTT 接收配置',
                      onPressed:
                          service.activityOwner == ProbeActivityOwner.none
                              ? () => showRttControlBlockDialog(
                                context,
                                service: service,
                                title: 'RTT Viewer 接收配置',
                              )
                              : null,
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: 76,
                  child: ToolbarToggleTextButton(
                    icon: Icon(vm.paused ? Icons.play_arrow : Icons.pause),
                    label: vm.paused ? '继续' : '暂停',
                    tooltip: vm.paused ? '继续显示' : '暂停显示',
                    selected: vm.paused,
                    activeColor: _viewerOptionActiveColor,
                    onPressed:
                        service.activityOwner == ProbeActivityOwner.rttViewer
                            ? vm.togglePaused
                            : null,
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: Icon(vm.paused ? Icons.play_arrow : Icons.pause),
                      label: vm.paused ? '继续显示' : '暂停显示',
                      selected: vm.paused,
                      onPressed:
                          service.activityOwner == ProbeActivityOwner.rttViewer
                              ? vm.togglePaused
                              : null,
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: 76,
                  child: ToolbarToggleTextButton(
                    icon: const Icon(Icons.schedule),
                    label: '时间戳',
                    tooltip: '时间戳',
                    selected: vm.timestampEnabled,
                    activeColor: _viewerOptionActiveColor,
                    onPressed:
                        () => vm.setTimestampEnabled(!vm.timestampEnabled),
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.schedule),
                      label: '时间戳',
                      selected: vm.timestampEnabled,
                      onPressed:
                          () => vm.setTimestampEnabled(!vm.timestampEnabled),
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: 82,
                  child: ToolbarToggleTextButton(
                    icon: const Icon(Icons.numbers),
                    label: 'HEX显示',
                    tooltip: 'HEX显示',
                    selected: vm.displayMode == RttDisplayMode.hex,
                    activeColor: _viewerOptionActiveColor,
                    onPressed:
                        () => vm.setDisplayMode(
                          vm.displayMode == RttDisplayMode.hex
                              ? RttDisplayMode.text
                              : RttDisplayMode.hex,
                        ),
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.numbers),
                      label: 'HEX显示',
                      selected: vm.displayMode == RttDisplayMode.hex,
                      onPressed:
                          () => vm.setDisplayMode(
                            vm.displayMode == RttDisplayMode.hex
                                ? RttDisplayMode.text
                                : RttDisplayMode.hex,
                          ),
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: 88,
                  child: ToolbarToggleTextButton(
                    icon: const Icon(Icons.vertical_align_bottom),
                    label: '自动滚动',
                    tooltip: '自动滚动',
                    selected: vm.autoScroll,
                    activeColor: _viewerOptionActiveColor,
                    onPressed: () => vm.setAutoScroll(!vm.autoScroll),
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.vertical_align_bottom),
                      label: '自动滚动',
                      selected: vm.autoScroll,
                      onPressed: () => vm.setAutoScroll(!vm.autoScroll),
                    ),
                  ],
                ),
              ],
              trailingItems: [
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarIconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '清空',
                    onPressed: visibleItemCount == 0 ? null : vm.clear,
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.close),
                      label: '清空',
                      onPressed: visibleItemCount == 0 ? null : vm.clear,
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: PopupMenuButton<bool>(
                    key: const ValueKey('rtt-export-button'),
                    tooltip: '导出',
                    icon: const Icon(Icons.file_upload_outlined),
                    enabled: hasExportData,
                    onSelected:
                        (binary) => unawaited(_export(vm, binary: binary)),
                    itemBuilder:
                        (_) => const [
                          PopupMenuItem(value: false, child: Text('导出文本')),
                          PopupMenuItem(value: true, child: Text('导出原始 BIN')),
                        ],
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.file_upload_outlined),
                      label: '导出文本',
                      onPressed:
                          hasExportData
                              ? () => unawaited(_export(vm, binary: false))
                              : null,
                    ),
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.data_object),
                      label: '导出原始 BIN',
                      onPressed:
                          hasExportData
                              ? () => unawaited(_export(vm, binary: true))
                              : null,
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarAdvancedSettingsButton(
                    tooltip: 'RTT Viewer 设置',
                    onPressed: () => showRttSettingsDialog(context),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  _TerminalRail(
                    collapsed: _terminalPanelCollapsed,
                    selectedTerminal: vm.selectedTerminal,
                    terminalHasData: vm.terminalHasData,
                    terminalColorValue: vm.terminalColorValue,
                    terminalLabel: vm.terminalLabel,
                    onToggle:
                        () => setState(
                          () =>
                              _terminalPanelCollapsed =
                                  !_terminalPanelCollapsed,
                        ),
                    onSelected: vm.selectTerminal,
                    onAppearanceChanged:
                        (terminal, label, color) => vm.setTerminalAppearance(
                          terminal,
                          label,
                          color.toARGB32(),
                        ),
                  ),
                  VerticalDivider(
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child:
                                visibleItemCount == 0
                                    ? Center(
                                      child: Text(
                                        service.isConnected
                                            ? service.activityOwner ==
                                                    ProbeActivityOwner.none
                                                ? '点击“开始”读取 RTT 数据'
                                                : AppStrings.rtt.waitingData
                                            : service.lastError ??
                                                AppStrings.rtt.connectHint,
                                        style: TextStyle(
                                          color:
                                              service.lastError == null ||
                                                      service.isConnected
                                                  ? Theme.of(
                                                    context,
                                                  ).colorScheme.onSurfaceVariant
                                                  : Theme.of(
                                                    context,
                                                  ).colorScheme.error,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    )
                                    : SelectionArea(
                                      child: ListView.builder(
                                        controller: _scrollController,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        itemCount: visibleItemCount,
                                        itemBuilder: (context, index) {
                                          final line =
                                              index < lines.length
                                                  ? lines[index]
                                                  : partialLine;
                                          return _buildRttOutputLine(vm, line);
                                        },
                                      ),
                                    ),
                          ),
                        ),
                        if (!vm.allTerminalsSelected)
                          _RttInputBar(
                            controller: _inputController,
                            enabled: vm.canSend,
                            hex: vm.displayMode == RttDisplayMode.hex,
                            lineEnding: _lineEnding,
                            onLineEndingChanged:
                                (value) => setState(() => _lineEnding = value),
                            onSend: () => unawaited(_send(vm)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: kPageStatusBarHeight,
              padding: kPageStatusBarPadding,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Text(
                [
                  service.activityOwner == ProbeActivityOwner.rttViewer
                      ? '运行中'
                      : service.isConnected
                      ? '已连接'
                      : '已停止',
                  vm.encoding,
                  vm.allTerminalsSelected
                      ? 'All Terminals'
                      : 'Terminal ${vm.selectedTerminal}',
                  '接收 ${_formatBytes(service.receivedBytes)}',
                  if (service.droppedBytes > 0)
                    '丢弃 ${_formatBytes(service.droppedBytes)}',
                  if (vm.paused) '暂停新增 ${_formatBytes(vm.pausedBytes)}',
                  if (!service.isConnected && service.lastError != null)
                    service.lastError!,
                ].join('  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: kPageStatusBarTextStyle,
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _buildRttOutputLine(RttViewModel vm, String line) {
  final style = TextStyle(
    fontFamily: vm.fontFamily,
    fontSize: vm.fontSize,
    height: 1.2,
  );
  final match =
      vm.allTerminalsSelected
          ? RegExp(r'^\[Terminal ([0-9]|1[0-5])\] ').firstMatch(line)
          : null;
  if (match == null) return Text(line, softWrap: true, style: style);

  final terminal = int.parse(match.group(1)!);
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '[${vm.terminalLabel(terminal)}] ',
          style: TextStyle(
            color: Color(vm.terminalColorValue(terminal)),
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: line.substring(match.end)),
      ],
    ),
    softWrap: true,
    style: style,
  );
}

class _TerminalRail extends StatelessWidget {
  const _TerminalRail({
    required this.collapsed,
    required this.selectedTerminal,
    required this.terminalHasData,
    required this.terminalColorValue,
    required this.terminalLabel,
    required this.onToggle,
    required this.onSelected,
    required this.onAppearanceChanged,
  });

  final bool collapsed;
  final int selectedTerminal;
  final bool Function(int terminal) terminalHasData;
  final int Function(int terminal) terminalColorValue;
  final String Function(int terminal) terminalLabel;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelected;
  final void Function(int terminal, String label, Color color)
  onAppearanceChanged;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return SizedBox(
        width: 34,
        child: Align(
          alignment: Alignment.topCenter,
          child: _TerminalPanelToggleButton(
            key: const ValueKey('rtt-terminal-panel-expand-button'),
            tooltip: '展开终端',
            icon: Icons.chevron_right,
            onPressed: onToggle,
          ),
        ),
      );
    }
    return SizedBox(
      width: 150,
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Text(
                      '虚拟终端',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                _TerminalPanelToggleButton(
                  key: const ValueKey('rtt-terminal-panel-collapse-button'),
                  tooltip: '收起终端',
                  icon: Icons.chevron_left,
                  onPressed: onToggle,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 17,
              itemExtent: 34,
              itemBuilder: (context, index) {
                final terminal = index - 1;
                final selected = terminal == selectedTerminal;
                final active = terminal < 0 || terminalHasData(terminal);
                final terminalColor =
                    terminal < 0 ? null : Color(terminalColorValue(terminal));
                return Listener(
                  onPointerDown:
                      terminal < 0
                          ? null
                          : (event) {
                            if (event.buttons != kSecondaryMouseButton) return;
                            unawaited(
                              _showTerminalColorDialog(
                                context,
                                terminal,
                                terminalLabel(terminal),
                                terminalColor!,
                              ).then((appearance) {
                                if (appearance != null) {
                                  onAppearanceChanged(
                                    terminal,
                                    appearance.label,
                                    appearance.color,
                                  );
                                }
                              }),
                            );
                          },
                  child: ListTile(
                    key: ValueKey('rtt-terminal-row-$terminal'),
                    dense: true,
                    minTileHeight: 34,
                    selected: selected,
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.55),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(
                      terminal < 0 ? 'All Terminals' : terminalLabel(terminal),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            terminal < 0 ? FontWeight.normal : FontWeight.w600,
                        color:
                            terminalColor == null
                                ? null
                                : active
                                ? terminalColor
                                : terminalColor.withValues(alpha: 0.4),
                      ),
                    ),
                    onTap: () => onSelected(terminal),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalPanelToggleButton extends StatelessWidget {
  const _TerminalPanelToggleButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(width: 34, height: 36, child: Icon(icon, size: 18)),
      ),
    );
  }
}

Future<_TerminalAppearance?> _showTerminalColorDialog(
  BuildContext context,
  int terminal,
  String currentLabel,
  Color current,
) {
  return showDialog<_TerminalAppearance>(
    context: context,
    builder:
        (_) => _TerminalAppearanceDialog(
          terminal: terminal,
          initialLabel: currentLabel,
          initialColor: current,
        ),
  );
}

class _TerminalAppearance {
  const _TerminalAppearance(this.label, this.color);

  final String label;
  final Color color;
}

class _TerminalAppearanceDialog extends StatefulWidget {
  const _TerminalAppearanceDialog({
    required this.terminal,
    required this.initialLabel,
    required this.initialColor,
  });

  final int terminal;
  final String initialLabel;
  final Color initialColor;

  @override
  State<_TerminalAppearanceDialog> createState() =>
      _TerminalAppearanceDialogState();
}

class _TerminalAppearanceDialogState extends State<_TerminalAppearanceDialog> {
  late final TextEditingController _labelController;
  late Color _selectedColor;
  String? _errorText;

  static final List<Color> _colors = RttConfiguration.defaultTerminalColors
      .map((value) => Color(value))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.initialLabel);
    _selectedColor = widget.initialColor;
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  void _submit() {
    final label =
        _labelController.text.replaceAll(RegExp(r'[\[\]]'), '').trim();
    if (label.isEmpty) {
      setState(() => _errorText = '方括号内的标注不能为空');
      return;
    }
    if (label.length > 32) {
      setState(() => _errorText = '标注最多 32 个字符');
      return;
    }
    Navigator.of(context).pop(_TerminalAppearance(label, _selectedColor));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Terminal ${widget.terminal} 标注设置'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('rtt-terminal-label-field'),
              controller: _labelController,
              autofocus: true,
              decoration: secondaryDialogFieldDecoration(
                labelText: '方括号内文字',
                hintText: '例如 电机状态',
                suffixText: ']',
              ).copyWith(errorText: _errorText, prefixText: '['),
              onChanged: (_) {
                if (_errorText != null) setState(() => _errorText = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            const Text('标识颜色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var index = 0; index < _colors.length; index++)
                  Tooltip(
                    message: '颜色 ${index + 1}',
                    child: InkWell(
                      key: ValueKey('rtt-terminal-color-option-$index'),
                      onTap:
                          () => setState(() => _selectedColor = _colors[index]),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: _colors[index],
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color:
                                _colors[index].toARGB32() ==
                                        _selectedColor.toARGB32()
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child:
                            _colors[index].toARGB32() ==
                                    _selectedColor.toARGB32()
                                ? const Icon(
                                  Icons.check,
                                  size: 17,
                                  color: Colors.white,
                                )
                                : null,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

class _RttInputBar extends StatelessWidget {
  const _RttInputBar({
    required this.controller,
    required this.enabled,
    required this.hex,
    required this.lineEnding,
    required this.onLineEndingChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool hex;
  final String lineEnding;
  final ValueChanged<String> onLineEndingChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                isDense: true,
                hintText:
                    enabled
                        ? hex
                            ? '输入 HEX 字节'
                            : '输入发送到 Down 0 的文本'
                        : '当前后端没有可用的 Down 0',
              ),
              onSubmitted: enabled ? (_) => onSend() : null,
            ),
          ),
          if (!hex) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 104,
              child: DropdownButtonFormField<String>(
                initialValue: lineEnding,
                isDense: true,
                decoration: const InputDecoration(isDense: true),
                items: const [
                  DropdownMenuItem(value: '', child: Text('无')),
                  DropdownMenuItem(value: '\r', child: Text('CR')),
                  DropdownMenuItem(value: '\n', child: Text('LF')),
                  DropdownMenuItem(value: '\r\n', child: Text('CRLF')),
                ],
                onChanged:
                    enabled
                        ? (value) {
                          if (value != null) onLineEndingChanged(value);
                        }
                        : null,
              ),
            ),
          ],
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: '发送到 RTT Down 0',
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

String _ensureExtension(String path, String extension) {
  final suffix = '.$extension';
  return path.toLowerCase().endsWith(suffix) ? path : '$path$suffix';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}
