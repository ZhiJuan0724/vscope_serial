import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/crc.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/raw_data_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 原始数据页面
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
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
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
                    final delta = details.delta.dy / MediaQuery.of(context).size.height;
                    _splitRatio = (_splitRatio + delta).clamp(0.2, 0.8);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: Container(
                    height: 8,
                    color: Theme.of(context).dividerColor.withOpacity(0.5),
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
              Expanded(
                child: _buildSendArea(vm),
              ),
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
          child: Row(
            children: [
              const Text('接收数据',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.showTimestamp,
                    onChanged: (value) => vm.setShowTimestamp(value!),
                  ),
                  const Text('时间戳'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.receiveHex,
                    onChanged: (value) => vm.setReceiveHex(value!),
                  ),
                  const Text('HEX接收'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.autoScroll,
                    onChanged: (value) => vm.setAutoScroll(value!),
                  ),
                  const Text('自动滚动'),
                ],
              ),
              TextButton.icon(
                onPressed: () => vm.clearData(),
                icon: const Icon(Icons.clear, size: 18),
                label: const Text('清空'),
              ),
              TextButton.icon(
                onPressed: () => _showExportDialog(context, vm),
                icon: const Icon(Icons.save, size: 18),
                label: const Text('保存'),
              ),
            ],
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
            child: ListView.builder(
              controller: _scrollController,
              itemCount: vm.receivedLines.length,
              itemBuilder: (context, index) {
                return SelectableText(
                  vm.receivedLines[index],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                );
              },
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
              const Text('发送数据',
                  style: TextStyle(fontWeight: FontWeight.bold)),
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
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                            value: CrcType.crc8, child: Text('CRC-8')),
                        DropdownMenuItem(
                            value: CrcType.crc16, child: Text('CRC-16')),
                        DropdownMenuItem(
                            value: CrcType.crc32, child: Text('CRC-32')),
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
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        isDense: true,
                      ),
                      items: getPolysByType(vm.crcType).keys.map((name) {
                        return DropdownMenuItem(
                          value: name,
                          child: Tooltip(
                            message: name,
                            child: Text(name, overflow: TextOverflow.ellipsis),
                          ),
                        );
                      }).toList(),
                      onChanged: (value) => vm.setCrcPolyName(value!),
                    ),
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
                          hintText: vm.sendHex
                              ? '输入十六进制 (如: 01 02 03)'
                              : '输入要发送的数据',
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                        ),
                        maxLines: null,
                        expands: true,
                        enabled: true,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        onChanged: (_) => setState(() {}),
                      ),
                      // 右下角长度显示
                      Positioned(
                        right: 8,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            vm.sendHex
                                ? '${_getHexByteCount(_sendController.text)} bytes'
                                : '${_sendController.text.length} chars',
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: vm.isConnected
                      ? () {
                          final data = vm.prepareSendData(_sendController.text);
                          if (data != null) {
                            vm.send(data);
                            _sendController.clear();
                            setState(() {});
                          }
                        }
                      : null,
                  icon: const Icon(Icons.send),
                  label: const Text('发送'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 20),
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
      builder: (context) => AlertDialog(
        title: const Text('保存数据'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择保存格式：'),
            const SizedBox(height: 8),
            ...vm.dataStats.entries.map((e) => Text(
              '${e.key}: ${e.value}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            )),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
