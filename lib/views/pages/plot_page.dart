import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/parser_config.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_viewport.dart';
import '../widgets/common_widgets.dart';

/// 绘图页面
class PlotPage extends StatelessWidget {
  const PlotPage({super.key});

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SerialService>(context, listen: false);
    return ChangeNotifierProvider(
      create: (_) => PlotViewModel(service),
      child: const _PlotPageContent(),
    );
  }
}

class _PlotPageContent extends StatelessWidget {
  const _PlotPageContent();

  @override
  Widget build(BuildContext context) {
    return Consumer<PlotViewModel>(
      builder: (context, vm, child) {
        return Column(
          children: [
            // 工具栏
            _buildToolbar(context, vm),
            // 主区域
            Expanded(
              child: Row(
                children: [
                  // 通道设置面板
                  _buildChannelPanel(context, vm),
                  // 绘图区域
                  Expanded(
                    child: _buildPlotArea(context, vm),
                  ),
                ],
              ),
            ),
            // 状态栏
            _buildStatusBar(context, vm),
          ],
        );
      },
    );
  }

  // ========== 工具栏 ==========
  Widget _buildToolbar(BuildContext context, PlotViewModel vm) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          // 开始/停止按钮
          ElevatedButton.icon(
            onPressed: () {
              if (vm.isPlotting) {
                vm.stopPlotting();
              } else {
                vm.startPlotting();
              }
            },
            icon: Icon(
              vm.isPlotting ? Icons.stop : Icons.play_arrow,
              size: 16,
            ),
            label: Text(vm.isPlotting ? '停止' : '开始'),
            style: ElevatedButton.styleFrom(
              backgroundColor: vm.isPlotting ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
          ),
          const SizedBox(width: 12),
          // 随机数据源 + 频率设置
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: vm.useRandomSource,
                onChanged: (value) => vm.setUseRandomSource(value!),
              ),
              const Text('随机源', style: TextStyle(fontSize: 12)),
              // 频率设置齿轮按钮
              Tooltip(
                message: '设置随机源频率: ${vm.randomFrequency.toStringAsFixed(1)} Hz',
                child: InkWell(
                  onTap: () => _showRandomFreqDialog(context, vm),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.settings,
                      size: 16,
                      color: vm.useRandomSource
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // 解析器选择
          SizedBox(
            width: 120,
            child: NoAnimDropdown<ParserType>(
              value: vm.parserType,
              hint: '解析器',
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                border: OutlineInputBorder(),
              ),
              items: ParserType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type.label, style: const TextStyle(fontSize: 12)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) vm.setParserType(value);
              },
            ),
          ),
          const SizedBox(width: 8),
          // 解析器配置按钮
          IconButton(
            onPressed: () => _showParserConfigDialog(context, vm),
            icon: const Icon(Icons.settings, size: 18),
            tooltip: '解析器配置',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 12),
          // 网格开关
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: vm.showGrid,
                onChanged: (value) => vm.setShowGrid(value!),
              ),
              const Text('网格', style: TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(width: 8),
          // 单垂直光标开关
          Tooltip(
            message: '单垂直光标',
            child: TextButton.icon(
              onPressed: () => vm.setVCursorEnabled(!vm.vCursorEnabled),
              icon: Icon(
                Icons.vertical_align_center,
                size: 16,
                color: vm.vCursorEnabled ? Colors.orange : null,
              ),
              label: Text(
                '光标',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.vCursorEnabled ? Colors.orange : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.vCursorEnabled
                    ? Colors.orange.withValues(alpha: 0.1)
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // X-X / Y-Y 光标模式
          SizedBox(
            width: 80,
            child: NoAnimDropdown<CursorMode>(
              value: vm.cursorMode,
              hint: '测量',
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                  value: CursorMode.none,
                  child: Text('关闭', style: TextStyle(fontSize: 12)),
                ),
                const DropdownMenuItem(
                  value: CursorMode.xCursor,
                  child: Text('X-X', style: TextStyle(fontSize: 12)),
                ),
                const DropdownMenuItem(
                  value: CursorMode.yCursor,
                  child: Text('Y-Y', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  vm.setCursorMode(value);
                  if (value == CursorMode.none) {
                    vm.clearCursors();
                  }
                }
              },
            ),
          ),
          const SizedBox(width: 12),
          // 最新点跟随（3/4宽度处）
          Tooltip(
            message: '最新点跟随在 3/4 宽度处',
            child: TextButton.icon(
              onPressed: () => vm.setFollowEnabled(!vm.followEnabled),
              icon: Icon(
                Icons.trending_flat,
                size: 16,
                color: vm.followEnabled ? Colors.blue : null,
              ),
              label: Text(
                '跟随',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.followEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.followEnabled
                    ? Colors.blue.withValues(alpha: 0.1)
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 框选放大开关
          Tooltip(
            message: '框选放大',
            child: IconButton(
              onPressed: () => vm.setBoxZoomEnabled(!vm.boxZoomEnabled),
              icon: Icon(
                Icons.crop_free,
                size: 18,
                color: vm.boxZoomEnabled ? Colors.blue : null,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          const SizedBox(width: 4),
          // 撤回缩放
          Tooltip(
            message: '撤回缩放',
            child: IconButton(
              onPressed: vm.canUndoZoom ? () => vm.undoZoom() : null,
              icon: const Icon(Icons.undo, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          const SizedBox(width: 4),
          // X 轴缩小
          Tooltip(
            message: 'X 轴缩小',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomXOut(),
              icon: const Icon(Icons.zoom_out, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          // X 轴放大
          Tooltip(
            message: 'X 轴放大',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomXIn(),
              icon: const Icon(Icons.zoom_in, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          // Y 轴缩小
          Tooltip(
            message: 'Y 轴缩小',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomYOut(),
              icon: const Icon(Icons.vertical_align_bottom, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          // Y 轴放大
          Tooltip(
            message: 'Y 轴放大',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomYIn(),
              icon: const Icon(Icons.vertical_align_top, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          const SizedBox(width: 8),
          // 导出 CSV
          IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => _exportCsv(context, vm),
            icon: const Icon(Icons.save, size: 18),
            tooltip: '导出 CSV',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 8),
          // 清空数据
          IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.clearData(),
            icon: const Icon(Icons.clear, size: 18),
            tooltip: '清空数据',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  // ========== 通道面板 ==========
  Widget _buildChannelPanel(BuildContext context, PlotViewModel vm) {
    // 只显示实际有数据的通道
    final activeCount = vm.activeChannelCount > 0 ? vm.activeChannelCount : vm.channels.length;
    
    return Container(
      width: 200,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: const Row(
              children: [
                Text('通道', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                Spacer(),
                Tooltip(
                  message: '显示通道',
                  child: Text('显示', style: TextStyle(fontSize: 10)),
                ),
                SizedBox(width: 4),
                Tooltip(
                  message: '连线显示',
                  child: Text('连线', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: activeCount,
              itemBuilder: (context, index) {
                final ch = vm.channels[index];
                return _ChannelItem(key: ValueKey('ch_${ch.index}'), vm: vm, ch: ch);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ========== 绘图区域 ==========
  Widget _buildPlotArea(BuildContext context, PlotViewModel vm) {
    if (vm.dataPoints.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text('暂无数据', style: TextStyle(color: Colors.grey)),
            Text('点击"开始"按钮开始绘图', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    return GestureDetector(
      onTapUp: (details) {
        // x-x / y-y 光标点击放置
        if (vm.cursorMode == CursorMode.xCursor) {
          final size = context.size ?? Size.zero;
          if (size.isEmpty) return;
          final x = vm.viewport.screenToDataX(
            details.localPosition.dx.clamp(
              PlotViewport().marginLeft,
              size.width - PlotViewport().marginRight,
            ),
            size.width,
          );
          // X吸附到整数
          vm.setXCursor(x.round().toDouble());
        } else if (vm.cursorMode == CursorMode.yCursor) {
          final size = context.size ?? Size.zero;
          if (size.isEmpty) return;
          final y = vm.viewport.screenToDataY(
            details.localPosition.dy.clamp(
              PlotViewport().marginTop,
              size.height - PlotViewport().marginBottom,
            ),
            size.height,
          );
          // Y吸附到整数
          vm.setYCursor(y.round().toDouble());
        }
      },
      child: PlotGestureHandler(
        viewport: vm.viewport,
        cursorMode: vm.cursorMode,
        vCursorEnabled: vm.vCursorEnabled,
        boxZoomEnabled: vm.boxZoomEnabled,
        onViewportChanged: (viewport) => vm.updateViewport(viewport),
        onCursorChanged: (cursor) {
          // 如果是单垂直光标模式，使用增强版光标更新
          if (cursor != null && cursor.mode == CursorMode.follow) {
            vm.updateFollowCursor(cursor.x, cursor.y ?? 0, 
              cursor.screenPosition ?? Offset.zero);
          } else {
            vm.updateCursor(cursor);
          }
        },
        child: CustomPaint(
          painter: PlotPainter(
            viewport: vm.viewport,
            data: vm.dataPoints,
            channels: vm.channels,
            showGrid: vm.showGrid,
            cursor: vm.cursor,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  // ========== 状态栏 ==========
  Widget _buildStatusBar(BuildContext context, PlotViewModel vm) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Text(
            vm.statusText,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const Spacer(),
          // 光标 delta 显示
          if (vm.cursorDeltaText != null)
            Text(
              vm.cursorDeltaText!,
              style: const TextStyle(fontSize: 11, color: Colors.yellow),
            ),
          const SizedBox(width: 8),
          // 垂直光标信息（显示当前X位置的所有通道Y值）
          if (vm.cursor != null && vm.cursorMode == CursorMode.follow)
            _buildCursorInfo(vm),
        ],
      ),
    );
  }

  Widget _buildCursorInfo(PlotViewModel vm) {
    final cursor = vm.cursor!;
    final buffer = StringBuffer();
    buffer.write('X: ${cursor.x.toInt()} ');

    // 查找最近的数据点
    if (vm.dataPoints.isNotEmpty) {
      final nearest = vm.dataPoints.reduce((a, b) {
        return (a.index - cursor.x).abs() < (b.index - cursor.x).abs() ? a : b;
      });

      for (int i = 0; i < nearest.channelCount && i < vm.channels.length; i++) {
        if (!vm.channels[i].visible) continue;
        final value = nearest.values[i];
        buffer.write('Ch$i: ${value.toStringAsFixed(2)} ');
      }
    }

    return Text(
      buffer.toString(),
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    );
  }

  // ========== 对话框 ==========
  void _showParserConfigDialog(BuildContext context, PlotViewModel vm) {
    showDialog(
      context: context,
      builder: (context) => _ParserConfigDialog(vm: vm),
    );
  }

  void _showRandomFreqDialog(BuildContext context, PlotViewModel vm) {
    final controller = TextEditingController(
      text: vm.randomFrequency.toStringAsFixed(1),
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('随机源频率'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '频率 (Hz)',
                hintText: '1 ~ 10000',
                suffixText: 'Hz',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text(
              '当前: ${vm.randomFrequency.toStringAsFixed(1)} Hz',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final hz = double.tryParse(controller.text);
              if (hz != null) {
                vm.setRandomFrequency(hz);
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _exportCsv(BuildContext context, PlotViewModel vm) async {
    // 选择保存路径
    final result = await FilePicker.saveFile(
      dialogTitle: '保存 CSV 文件',
      fileName: 'vscope_plot_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null) return; // 用户取消

    final path = await vm.exportToCsv(result);
    if (path != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出: $path')),
      );
    }
  }
}

/// 通道项目（有状态，支持offset实时更新）
class _ChannelItem extends StatelessWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelItem({super.key, required this.vm, required this.ch});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          // 颜色指示器
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: ch.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          // 通道名
          SizedBox(
            width: 40,
            child: Text(
              'Ch${ch.index}',
              style: const TextStyle(fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          // 可见开关 + 文字提示
          Tooltip(
            message: ch.visible ? '点击隐藏通道' : '点击显示通道',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  child: Checkbox(
                    value: ch.visible,
                    onChanged: (value) => vm.setChannelVisible(ch.index, value!),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const Text('显示', style: TextStyle(fontSize: 9)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 连线开关 + 文字提示
          Tooltip(
            message: ch.showLine ? '点击关闭连线' : '点击开启连线',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  child: Checkbox(
                    value: ch.showLine,
                    onChanged: (value) => vm.setChannelShowLine(ch.index, value!),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const Text('连线', style: TextStyle(fontSize: 9)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 解析器配置对话框
class _ParserConfigDialog extends StatefulWidget {
  final PlotViewModel vm;

  const _ParserConfigDialog({required this.vm});

  @override
  State<_ParserConfigDialog> createState() => _ParserConfigDialogState();
}

class _ParserConfigDialogState extends State<_ParserConfigDialog> {
  late ParserConfig _config;

  @override
  void initState() {
    super.initState();
    _config = widget.vm.parserConfig.copyWith();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('解析器配置'),
      content: SizedBox(
        width: 300,
        child: widget.vm.parserType == ParserType.fireWater
            ? _buildFireWaterConfig()
            : _buildFixedFrameConfig(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.vm.updateParserConfig(_config);
            Navigator.of(context).pop();
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildFireWaterConfig() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FireWater 格式:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('以 "," 分割数据'),
        const Text('所有数据默认 double 类型'),
        const Text('以 "\\n" 结尾'),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('通道数:'),
            const SizedBox(width: 8),
            SizedBox(
              width: 60,
              child: TextField(
                controller: TextEditingController(text: _config.fireWaterChannelCount.toString()),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null && count >= 0 && count <= 16) {
                    setState(() => _config.fireWaterChannelCount = count);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            const Text('(0=自动识别)', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ],
    );
  }

  Widget _buildFixedFrameConfig() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('帧头设置', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('长度:'),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: TextEditingController(text: _config.frameHeaderLength.toString()),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  onChanged: (value) {
                    final len = int.tryParse(value);
                    if (len != null && len >= 1 && len <= 4) {
                      setState(() {
                        _config.frameHeaderLength = len;
                        while (_config.frameHeader.length < len) {
                          _config.frameHeader.add(0);
                        }
                        _config.frameHeader.length = len;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('帧头值:'),
              const SizedBox(width: 8),
              ...List.generate(_config.frameHeaderLength, (i) {
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 40,
                    child: TextField(
                      controller: TextEditingController(
                        text: '0x${_config.frameHeader[i].toRadixString(16).toUpperCase().padLeft(2, '0')}',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      ),
                      style: const TextStyle(fontSize: 11),
                      onChanged: (value) {
                        final hex = value.replaceAll('0x', '').replaceAll('0X', '');
                        final byte = int.tryParse(hex, radix: 16);
                        if (byte != null && byte >= 0 && byte <= 255) {
                          setState(() {
                            _config.frameHeader[i] = byte;
                          });
                        }
                      },
                    ),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 16),
          const Text('数据设置', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('数据类型:'),
              const SizedBox(width: 8),
              Expanded(
                child: NoAnimDropdown<DataType>(
                  value: _config.dataType,
                  hint: '类型',
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  items: DataType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.label, style: const TextStyle(fontSize: 12)),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _config.dataType = value);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('通道数:'),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: TextEditingController(text: _config.channelCount.toString()),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  onChanged: (value) {
                    final count = int.tryParse(value);
                    if (count != null && count >= 1 && count <= 16) {
                      setState(() => _config.channelCount = count);
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
