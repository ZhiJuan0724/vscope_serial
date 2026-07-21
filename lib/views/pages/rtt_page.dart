import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/rtt_config.dart';
import '../../core/localization/app_strings.dart';
import '../../services/app_notifications.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../dialogs/rtt_settings_dialog.dart';
import '../widgets/common_widgets.dart';

/// RTT Up 0 只读查看页面。
class RttPage extends StatefulWidget {
  const RttPage({super.key});

  @override
  State<RttPage> createState() => _RttPageState();
}

class _RttPageState extends State<RttPage> {
  final ScrollController _scrollController = ScrollController();
  int _lastOutputRevision = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
        return Column(
          children: [
            UnifiedToolbar(
              leadingItems: [
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarToggleIconButton(
                    icon: Icon(vm.paused ? Icons.play_arrow : Icons.pause),
                    tooltip: vm.paused ? '继续显示' : '暂停显示',
                    selected: vm.paused,
                    onPressed: service.isConnected ? vm.togglePaused : null,
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: Icon(vm.paused ? Icons.play_arrow : Icons.pause),
                      label: vm.paused ? '继续显示' : '暂停显示',
                      selected: vm.paused,
                      onPressed: service.isConnected ? vm.togglePaused : null,
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarToggleIconButton(
                    icon: const Icon(Icons.schedule),
                    tooltip: '时间戳',
                    selected: vm.timestampEnabled,
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
                  extent: kToolbarControlExtent,
                  child: ToolbarToggleIconButton(
                    icon: const Icon(Icons.tag),
                    tooltip: 'HEX显示',
                    selected: vm.displayMode == RttDisplayMode.hex,
                    onPressed:
                        () => vm.setDisplayMode(
                          vm.displayMode == RttDisplayMode.hex
                              ? RttDisplayMode.text
                              : RttDisplayMode.hex,
                        ),
                  ),
                  overflowActions: [
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.tag),
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
                  extent: kToolbarControlExtent,
                  child: ToolbarToggleIconButton(
                    icon: const Icon(Icons.vertical_align_bottom),
                    tooltip: '自动滚动',
                    selected: vm.autoScroll,
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
                    tooltip: '导出',
                    icon: const Icon(Icons.file_upload_outlined),
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
                      onPressed: () => unawaited(_export(vm, binary: false)),
                    ),
                    ToolbarOverflowAction(
                      icon: const Icon(Icons.data_object),
                      label: '导出原始 BIN',
                      onPressed: () => unawaited(_export(vm, binary: true)),
                    ),
                  ],
                ),
                ToolbarLayoutItem(
                  extent: kToolbarControlExtent,
                  child: ToolbarAdvancedSettingsButton(
                    tooltip: 'RTT设置',
                    onPressed: () => showRttSettingsDialog(context),
                  ),
                ),
              ],
            ),
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
                                ? AppStrings.rtt.waitingData
                                : service.lastError ??
                                    AppStrings.rtt.connectHint,
                            style: TextStyle(
                              color:
                                  service.lastError == null ||
                                          service.isConnected
                                      ? Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant
                                      : Theme.of(context).colorScheme.error,
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
                            itemBuilder:
                                (context, index) => Text(
                                  index < lines.length
                                      ? lines[index]
                                      : partialLine,
                                  softWrap: true,
                                  style: TextStyle(
                                    fontFamily: vm.fontFamily,
                                    fontSize: vm.fontSize,
                                    height: 1.2,
                                  ),
                                ),
                          ),
                        ),
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
                  service.isConnected ? '运行中' : '已停止',
                  vm.encoding,
                  'Up 0',
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

String _ensureExtension(String path, String extension) {
  final suffix = '.$extension';
  return path.toLowerCase().endsWith(suffix) ? path : '$path$suffix';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}
