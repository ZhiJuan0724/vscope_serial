import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/crc.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/raw_data_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 数据收发页面
class RawDataPage extends StatefulWidget {
  const RawDataPage({super.key});

  @override
  State<RawDataPage> createState() => _RawDataPageState();
}

class _RawDataPageState extends State<RawDataPage> {
  final TextEditingController _sendController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  double _splitRatio = 0.65;

  @override
  void dispose() {
    _sendController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom(RawDataViewModel vm) {
    if (vm.autoScroll && _scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  int _getHexByteCount(String text) {
    final hexString = text.replaceAll(' ', '');
    if (hexString.isEmpty) return 0;
    return (hexString.length / 2).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SerialService>(context, listen: false);
    return ChangeNotifierProvider(
      create: (_) => RawDataViewModel(service),
      child: Consumer<RawDataViewModel>(
        builder: (context, vm, child) {
          _scrollToBottom(vm);
          return Column(
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * _splitRatio,
                child: _buildReceiveArea(vm),
              ),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  setState(() {
                    final delta =
                        details.delta.dy / MediaQuery.of(context).size.height;
                    _splitRatio = (_splitRatio + delta).clamp(0.2, 0.8);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: Container(
                    height: 8,
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.5),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildSendArea(vm)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReceiveArea(RawDataViewModel vm) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 使用固定断点决定折叠策略，避免宽度跳动：
              // - ≥ 820px: 全部展开
              // - 560px ~ 820px: 操作组（清空/保存/设置）折叠进菜单
              // - < 560px: 选项组（时间戳/HEX/滚动）和操作组都折叠
              final width = constraints.maxWidth;
              final showOptions = width >= 560;
              final showActions = width >= 820;
              final hasCollapsed = !showOptions || !showActions;

              return SizedBox(
                height: 40,
                child: ClipRect(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        '数据收发',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      // 开始/停止接收按钮
                      ElevatedButton.icon(
                        onPressed:
                            vm.isConnected && !vm.isRawReceiving
                                ? () => vm.startReceiving()
                                : null,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('开始接收'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 32),
                        ),
                      ),
                      const SizedBox(width: 4),
                      ElevatedButton.icon(
                        onPressed:
                            vm.isRawReceiving ? () => vm.stopReceiving() : null,
                        icon: const Icon(Icons.stop, size: 16),
                        label: const Text('停止接收'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 32),
                        ),
                      ),
                      const Spacer(),
                      // 选项组（时间戳/HEX/自动滚动）
                      if (showOptions) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.showTimestamp,
                                onChanged:
                                    (value) => vm.setShowTimestamp(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('时间戳'),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.receiveHex,
                                onChanged: (value) => vm.setReceiveHex(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('HEX显示'),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.autoScroll,
                                onChanged: (value) => vm.setAutoScroll(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('自动滚动'),
                          ],
                        ),
                      ],
                      // 操作组（清空/保存/高级设置）
                      if (showActions) ...[
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () => vm.clearData(),
                          icon: const Icon(Icons.clear, size: 18),
                          label: const Text('清空'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            minimumSize: const Size(0, 32),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _showExportDialog(context, vm),
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('保存'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            minimumSize: const Size(0, 32),
                          ),
                        ),
                        TextButton.icon(
                          onPressed:
                              () => _showAdvancedSettingsDialog(context, vm),
                          icon: const Icon(Icons.settings, size: 18),
                          label: const Text('高级设置'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            minimumSize: const Size(0, 32),
                          ),
                        ),
                      ],
                      // 有折叠的组时显示下拉菜单
                      if (hasCollapsed)
                        _buildRawCollapsedMenu(
                          context,
                          vm,
                          showOptions: showOptions,
                          showActions: showActions,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(4.0),
            ),
            child: Stack(
              children: [
                // 数据列表或提示文字
                vm.receivedLines.isNotEmpty
                    ? SingleChildScrollView(
                      controller: _scrollController,
                      child: SizedBox(
                        width: double.infinity,
                        child: SelectableText.rich(
                          TextSpan(
                            children:
                                vm.receivedLines.asMap().entries.map((entry) {
                                  final index = entry.key;
                                  final line = entry.value;
                                  final bgColor =
                                      index.isEven
                                          ? Theme.of(context)
                                              .colorScheme
                                              .surface
                                              .withValues(alpha: 0.5)
                                          : Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest
                                              .withValues(alpha: 0.3);
                                  return TextSpan(
                                    text: '$line\n',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                      backgroundColor: bgColor,
                                    ),
                                  );
                                }).toList(),
                          ),
                        ),
                      ),
                    )
                    : const Center(
                      child: Text(
                        '发送的数据将显示在这里\n点击"开始接收"可同时显示接收数据',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ),
                // 右下角统计信息
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      vm.receiveHex
                          ? '接收: ${vm.dataStats['原始字节']} | 行数: ${vm.dataStats['文本行数']} | 缓存: ${vm.dataStats['文本缓存']}'
                          : '行数: ${vm.dataStats['文本行数']} | 缓存: ${vm.dataStats['文本缓存']}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendArea(RawDataViewModel vm) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // 工具栏：发送HEX + CRC 放同一行
          Row(
            children: [
              const Text('发送数据', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.sendHex,
                    onChanged: (value) => vm.setSendHex(value!),
                  ),
                  const Text('HEX发送'),
                ],
              ),
              if (vm.sendHex) ...[
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: vm.enableCrc,
                      onChanged: (value) => vm.setEnableCrc(value!),
                    ),
                    const Text('CRC'),
                  ],
                ),
                if (vm.enableCrc) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 90,
                    child: NoAnimDropdown<CrcType>(
                      value: vm.crcType,
                      hint: '类型',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: CrcType.crc8,
                          child: Text('CRC-8'),
                        ),
                        DropdownMenuItem(
                          value: CrcType.crc16,
                          child: Text('CRC-16'),
                        ),
                        DropdownMenuItem(
                          value: CrcType.crc32,
                          child: Text('CRC-32'),
                        ),
                      ],
                      onChanged: (value) => vm.setCrcType(value!),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 140,
                    child: NoAnimDropdown<String>(
                      value: vm.crcPolyName,
                      hint: '多项式',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        isDense: true,
                      ),
                      items:
                          getPolysByType(vm.crcType).keys.map((name) {
                            return DropdownMenuItem(
                              value: name,
                              child: Tooltip(
                                message: name,
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }).toList(),
                      onChanged: (value) => vm.setCrcPolyName(value!),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: vm.crcReverseBytes,
                        onChanged: (value) => vm.setCrcReverseBytes(value!),
                      ),
                      const Text('高低位反转'),
                    ],
                  ),
                ],
              ],
            ],
          ),
          const SizedBox(height: 4),
          // 输入区域
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      TextField(
                        controller: _sendController,
                        decoration: InputDecoration(
                          hintText:
                              vm.sendHex ? '输入十六进制 (如: 01 02 03)' : '输入要发送的数据',
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        maxLines: null,
                        expands: true,
                        enabled: true,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        inputFormatters:
                            vm.sendHex ? [_HexInputFormatter()] : null,
                        onChanged: (value) {
                          if (vm.sendHex) {
                            _formatHexInput(value);
                          }
                          setState(() {});
                        },
                      ),
                      // 右下角长度显示
                      Positioned(
                        right: 8,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            vm.sendHex
                                ? '${_getHexByteCount(_sendController.text)} bytes'
                                : '${_sendController.text.length} chars',
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed:
                      vm.isConnected
                          ? () {
                            final data = vm.prepareSendData(
                              _sendController.text,
                            );
                            if (data != null) {
                              try {
                                vm.send(data);
                                _sendController.clear();
                                setState(() {});
                              } catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(e.toString())),
                                );
                              }
                            }
                          }
                          : null,
                  icon: const Icon(Icons.send),
                  label: const Text('发送'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, RawDataViewModel vm) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: const Text('保存数据'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择保存格式：'),
                const SizedBox(height: 8),
                ...vm.dataStats.entries.map(
                  (e) => Text(
                    '${e.key}: ${e.value}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final path = await vm.exportAsText();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  if (path != null) {
                    _showSnackBar(context, '已保存为文本: $path');
                  }
                },
                icon: const Icon(Icons.text_snippet),
                label: const Text('文本 (.txt)'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final path = await vm.exportAsRawBytes();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  if (path != null) {
                    _showSnackBar(context, '已保存为原始字节: $path');
                  }
                },
                icon: const Icon(Icons.memory),
                label: const Text('原始字节 (.bin)'),
              ),
            ],
          ),
    );
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _formatHexInput(String value) {
    // Remove all spaces first
    final hexOnly = value.replaceAll(' ', '');
    // Re-insert spaces every 2 chars
    final formatted = <String>[];
    for (var i = 0; i < hexOnly.length; i += 2) {
      if (i + 2 <= hexOnly.length) {
        formatted.add(hexOnly.substring(i, i + 2));
      } else {
        formatted.add(hexOnly.substring(i));
      }
    }
    final newText = formatted.join(' ');
    if (newText != value) {
      _sendController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _showAdvancedSettingsDialog(BuildContext context, RawDataViewModel vm) {
    final controller = TextEditingController(text: vm.timeWindowUs.toString());
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: const Text('高级设置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('HEX分包时间 (μs):'),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '10 ~ 10000',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                Text(
                  '仅在 HEX显示 + 时间戳 开启时生效。当前: ${vm.timeWindowUs}μs (${vm.timeWindowUs < 1000 ? "显示微秒级时间戳" : "显示毫秒级时间戳"})',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () {
                  final us = int.tryParse(controller.text);
                  if (us != null && us >= 10 && us <= 10000) {
                    vm.setTimeWindowUs(us);
                    Navigator.of(context).pop();
                    _showSnackBar(context, '分包时间已设置为 $us μs');
                  } else {
                    _showSnackBar(context, '请输入 10 ~ 10000 之间的数值');
                  }
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  /// 折叠菜单：显示未平铺的组
  Widget _buildRawCollapsedMenu(
    BuildContext context,
    RawDataViewModel vm, {
    required bool showOptions,
    required bool showActions,
  }) {
    return PopupMenuButton<String>(
      tooltip: '更多选项',
      icon: const Icon(Icons.more_vert, size: 20),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];

        // 选项组（如果未平铺）
        if (!showOptions) {
          items.add(_buildMenuHeader('显示选项'));
          items.add(
            PopupMenuItem(
              value: 'timestamp',
              child: _buildMenuItem(
                icon:
                    vm.showTimestamp
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: '时间戳',
              ),
              onTap: () => vm.setShowTimestamp(!vm.showTimestamp),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'hex',
              child: _buildMenuItem(
                icon:
                    vm.receiveHex
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: 'HEX显示',
              ),
              onTap: () => vm.setReceiveHex(!vm.receiveHex),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'autoscroll',
              child: _buildMenuItem(
                icon:
                    vm.autoScroll
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: '自动滚动',
              ),
              onTap: () => vm.setAutoScroll(!vm.autoScroll),
            ),
          );
        }

        // 操作组（如果未平铺）
        if (!showActions) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('操作'));
          items.add(
            PopupMenuItem(
              value: 'clear',
              child: _buildMenuItem(icon: Icons.clear, label: '清空'),
              onTap: () => vm.clearData(),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'export',
              child: _buildMenuItem(icon: Icons.save, label: '保存'),
              onTap: () => _showExportDialog(context, vm),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'advanced',
              child: _buildMenuItem(icon: Icons.settings, label: '高级设置'),
              onTap: () => _showAdvancedSettingsDialog(context, vm),
            ),
          );
        }

        return items;
      },
    );
  }

  /// 构建菜单分组标题
  PopupMenuItem<String> _buildMenuHeader(String label) {
    return PopupMenuItem(
      value: 'header_$label',
      enabled: false,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: Colors.grey.shade600,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 构建下拉菜单项
  Widget _buildMenuItem({required IconData icon, required String label}) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// HEX input formatter: only allows 0-9, A-F, a-f, and spaces
class _HexInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Allow only hex chars and spaces
    final filtered = newValue.text.replaceAll(RegExp(r'[^0-9A-Fa-f ]'), '');
    if (filtered != newValue.text) {
      return TextEditingValue(
        text: filtered,
        selection: TextSelection.collapsed(offset: filtered.length),
      );
    }
    return newValue;
  }
}
