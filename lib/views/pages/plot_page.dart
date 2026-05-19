import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/parser_config.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../widgets/common_widgets.dart';

/// 绘图页面入口
///
/// 使用 [ChangeNotifierProvider] 创建 [PlotViewModel]，
/// 子组件通过 [Consumer] 或 [Provider.of] 访问 ViewModel。
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

/// 绘图页面内容主体
///
/// 页面布局（从上到下）：
/// - 工具栏：开始/停止、数据源设置、解析器、光标/测量、缩放、导出等
/// - 主区域：左侧通道面板 + 右侧绘图区域
/// - 状态栏：视口范围、数据点数、光标信息
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
  /// 构建顶部工具栏
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
          const Spacer(),
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
          // X-X 测量按钮（独立开关）
          Tooltip(
            message: 'X-X 测量',
            child: TextButton.icon(
              onPressed: () => vm.toggleXMeasurement(),
              icon: Icon(
                Icons.vertical_align_center,
                size: 16,
                color: vm.xMeasurementEnabled ? Colors.blue : null,
              ),
              label: Text(
                'X-X',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.xMeasurementEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.xMeasurementEnabled
                    ? Colors.blue.withValues(alpha: 0.15)
                    : null,
              ),
            ),
          ),
          // Y-Y 测量按钮（独立开关）
          Tooltip(
            message: 'Y-Y 测量',
            child: TextButton.icon(
              onPressed: () => vm.toggleYMeasurement(),
              icon: Icon(
                Icons.horizontal_rule,
                size: 16,
                color: vm.yMeasurementEnabled ? Colors.blue : null,
              ),
              label: Text(
                'Y-Y',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.yMeasurementEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.yMeasurementEnabled
                    ? Colors.blue.withValues(alpha: 0.15)
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 统计测量按钮
          Tooltip(
            message: '统计测量（Max/Min/Avg）',
            child: TextButton.icon(
              onPressed: () => vm.toggleStats(),
              icon: Icon(
                Icons.analytics,
                size: 16,
                color: vm.statsEnabled ? Colors.blue : null,
              ),
              label: Text(
                '统计',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.statsEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.statsEnabled
                    ? Colors.blue.withValues(alpha: 0.15)
                    : null,
              ),
            ),
          ),
          // 统计范围按钮（仅在统计开启时可用）
          Tooltip(
            message: '统计范围',
            child: TextButton.icon(
              onPressed: vm.statsEnabled ? () => vm.toggleStatsRange() : null,
              icon: Icon(
                Icons.straighten,
                size: 16,
                color: vm.statsRangeEnabled ? Colors.blue : null,
              ),
              label: Text(
                '范围',
                style: TextStyle(
                  fontSize: 11,
                  color: vm.statsRangeEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor: vm.statsRangeEnabled
                    ? Colors.blue.withValues(alpha: 0.15)
                    : null,
              ),
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
          // Y轴自适应
          Tooltip(
            message: 'Y轴自适应',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitYAxis(),
              icon: const Icon(Icons.vertical_align_center, size: 18),
              tooltip: 'Y轴自适应',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          // X轴自适应
          Tooltip(
            message: 'X轴自适应',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitXAxis(),
              icon: const Icon(Icons.horizontal_rule, size: 18),
              tooltip: 'X轴自适应',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
          // 全自适应
          Tooltip(
            message: '全自适应',
            child: IconButton(
              onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitAll(),
              icon: const Icon(Icons.fit_screen, size: 18),
              tooltip: '全自适应',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
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
          const SizedBox(width: 8),
          // 高级设置
          Tooltip(
            message: '高级设置',
            child: IconButton(
              onPressed: () => _showAdvancedSettingsDialog(context, vm),
              icon: const Icon(Icons.tune, size: 18),
              tooltip: '高级设置',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ),
        ],
      ),
    );
  }

  // ========== 通道面板 ==========
  /// 构建左侧通道设置面板
  ///
  /// 只显示实际有数据的通道（[activeChannelCount]），包含：
  /// - 通道颜色指示器
  /// - 通道名称
  /// - 可见性开关
  /// - 连线显示开关
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
  /// 构建右侧绘图区域
  ///
  /// 无数据时显示提示，有数据时显示：
  /// - [PlotGestureHandler]：处理手势交互
  /// - [PlotPainter]：绘制波形
  /// - 测量/统计信息框（可拖动）
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

    return Stack(
      children: [
        PlotGestureHandler(
          viewport: vm.viewport,
          vCursorEnabled: vm.vCursorEnabled,
          boxZoomEnabled: vm.boxZoomEnabled,
          refreshFps: vm.refreshFps,
          onViewportChanged: (viewport, {fromDrag = false}) => vm.updateViewport(viewport, fromDrag: fromDrag),
          onCursorChanged: (cursor) {
            if (cursor != null) {
              vm.updateFollowCursor(cursor.x, cursor.y ?? 0,
                cursor.screenPosition ?? Offset.zero);
            } else {
              vm.updateCursor(null);
            }
          },
          // 测量线位置
          xCursor1: vm.xCursor1,
          xCursor2: vm.xCursor2,
          yCursor1: vm.yCursor1,
          yCursor2: vm.yCursor2,
          // 测量线拖动回调
          onXCursor1Drag: vm.xMeasurementEnabled ? (x) => vm.setXCursor1(x) : null,
          onXCursor2Drag: vm.xMeasurementEnabled ? (x) => vm.setXCursor2(x) : null,
          onYCursor1Drag: vm.yMeasurementEnabled ? (y) => vm.setYCursor1(y) : null,
          onYCursor2Drag: vm.yMeasurementEnabled ? (y) => vm.setYCursor2(y) : null,
          // 统计范围位置
          statsX1: vm.statsRangeEnabled ? vm.statsX1 : null,
          statsX2: vm.statsRangeEnabled ? vm.statsX2 : null,
          // 统计范围拖动回调
          onStatsX1Drag: vm.statsRangeEnabled ? (x) => vm.setStatsX1(x) : null,
          onStatsX2Drag: vm.statsRangeEnabled ? (x) => vm.setStatsX2(x) : null,
          child: CustomPaint(
            painter: PlotPainter(
              viewport: vm.viewport,
              data: vm.dataPoints,
              channels: vm.channels,
              showGrid: vm.showGrid,
              gridDensity: _parseGridDensity(vm.gridDensity),
              cursor: vm.cursor,
              xCursor1: vm.xCursor1,
              xCursor2: vm.xCursor2,
              yCursor1: vm.yCursor1,
              yCursor2: vm.yCursor2,
              statsEnabled: vm.statsEnabled,
              statsRangeEnabled: vm.statsRangeEnabled,
              statsX1: vm.statsX1,
              statsX2: vm.statsX2,
              antiAliasEnabled: vm.antiAliasEnabled,
            ),
            size: Size.infinite,
          ),
        ),
        // 测量信息框（X-X / Y-Y 测量值显示 + 统计信息）
        if (vm.measurementText != null || vm.statsText != null)
          _buildCombinedInfoBox(context, vm),
      ],
    );
  }

  // ========== 状态栏 ==========
  /// 构建底部状态栏
  ///
  /// 显示视口范围、数据点数、接收速率、运行状态及光标信息。
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
          const SizedBox(width: 8),
          // 垂直光标信息（显示当前X位置的所有通道Y值）
          if (vm.cursor != null && vm.vCursorEnabled)
            _buildCursorInfo(vm),
        ],
      ),
    );
  }

  /// 构建光标信息文本（状态栏右侧）
  ///
  /// 显示当前 X 位置及最近数据点各通道的 Y 值。
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
  /// 显示解析器配置对话框
  void _showParserConfigDialog(BuildContext context, PlotViewModel vm) {
    showDialog(
      context: context,
      builder: (context) => _ParserConfigDialog(vm: vm),
    );
  }

  /// 显示随机源频率设置对话框
  void _showRandomFreqDialog(BuildContext context, PlotViewModel vm) {
    final controller = TextEditingController(
      text: vm.randomFrequency.toStringAsFixed(1),
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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

  /// 导出数据到 CSV 文件
  ///
  /// 弹出文件保存对话框，导出完成后显示 SnackBar 提示。
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

  /// 将字符串网格密度转换为 [GridDensity] 枚举
  GridDensity _parseGridDensity(String density) {
    return switch (density) {
      'sparse' => GridDensity.sparse,
      'dense' => GridDensity.dense,
      _ => GridDensity.normal,
    };
  }

  /// 构建网格密度选择按钮
  Widget _buildDensityButton(String label, String density, PlotViewModel vm, StateSetter setState) {
    final isSelected = vm.gridDensity == density;
    return Expanded(
      child: TextButton(
        onPressed: () {
          vm.setGridDensity(density);
          setState(() {});
        },
        style: TextButton.styleFrom(
          backgroundColor: isSelected ? Colors.blue.withValues(alpha: 0.2) : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 32),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isSelected ? Colors.blue : null,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 构建合并的信息框（X-X/Y-Y + 统计信息在同一框内，从左到右排列）
  Widget _buildCombinedInfoBox(BuildContext context, PlotViewModel vm) {
    final children = <Widget>[];

    // 第一列：X-X / Y-Y 测量值
    if (vm.measurementText != null) {
      children.add(
        Text(
          vm.measurementText!,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      );
    }

    // 分隔线
    if (vm.measurementText != null && vm.statsText != null) {
      children.add(
        Container(
          width: 1,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF8888AA).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(0.5),
          ),
        ),
      );
    }

    // 第二列及以后：统计信息（多列）
    if (vm.statsText != null) {
      children.add(_buildStatsContent(vm.statsText!));
    }

    return _DraggableInfoBox(
      initialRight: 16,
      initialTop: 16,
      borderColor: vm.statsText != null
          ? Colors.green.withValues(alpha: 0.5)
          : const Color(0xFF8888AA),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 构建统计信息内容，支持多列布局
  ///
  /// 当通道数超过 4 个时，自动分为多列显示以避免信息框过高。
  Widget _buildStatsContent(String text) {
    final lines = text.split('\n');
    final channelBlocks = <List<String>>[];
    List<String> currentBlock = [];

    // 按 --- 分割成各通道块
    for (final line in lines) {
      if (line == '---') {
        if (currentBlock.isNotEmpty) {
          channelBlocks.add(List.from(currentBlock));
          currentBlock.clear();
        }
      } else {
        currentBlock.add(line);
      }
    }
    if (currentBlock.isNotEmpty) {
      channelBlocks.add(currentBlock);
    }

    // 计算列数：每列最多 4 个通道（避免过高）
    const maxChannelsPerColumn = 4;
    final columnCount = (channelBlocks.length / maxChannelsPerColumn).ceil().clamp(1, 4);

    if (columnCount == 1) {
      return Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.5,
        ),
      );
    }

    // 多列布局
    final columns = <Widget>[];
    final itemsPerColumn = (channelBlocks.length / columnCount).ceil();

    for (int col = 0; col < columnCount; col++) {
      final start = col * itemsPerColumn;
      final end = (start + itemsPerColumn).clamp(0, channelBlocks.length);
      if (start >= end) break;

      final colBlocks = channelBlocks.sublist(start, end);
      final colText = StringBuffer();
      for (int i = 0; i < colBlocks.length; i++) {
        if (i > 0) colText.writeln('---');
        for (final line in colBlocks[i]) {
          colText.writeln(line);
        }
      }

      columns.add(
        Text(
          colText.toString().trim(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      );

      if (col < columnCount - 1) {
        columns.add(const SizedBox(width: 16));
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: columns,
    );
  }

  /// 显示高级设置对话框
  ///
  /// 包含：网格开关、网格密度、刷新帧率、抗锯齿开关。
  void _showAdvancedSettingsDialog(BuildContext context, PlotViewModel vm) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('高级设置'),
        content: SizedBox(
          width: 300,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 网格开关
                  Row(
                    children: [
                      const Text('显示网格', style: TextStyle(fontSize: 14)),
                      const Spacer(),
                      Switch(
                        value: vm.showGrid,
                        onChanged: (value) {
                          vm.setShowGrid(value);
                          setState(() {}); // 刷新对话框内部状态
                        },
                      ),
                    ],
                  ),
                  // 网格密度
                  if (vm.showGrid) ...[
                    const SizedBox(height: 8),
                    const Text('网格密度', style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _buildDensityButton('稀疏', 'sparse', vm, setState),
                        const SizedBox(width: 8),
                        _buildDensityButton('普通', 'normal', vm, setState),
                        const SizedBox(width: 8),
                        _buildDensityButton('密集', 'dense', vm, setState),
                      ],
                    ),
                  ],
                  const Divider(),
                  // 刷新帧率
                  const Text('绘图刷新帧率', style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('${vm.refreshFps} fps', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('${(1000 / vm.refreshFps).round()}ms', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                  Slider(
                    value: vm.refreshFps.toDouble(),
                    min: 10,
                    max: 60,
                    divisions: 50,
                    label: '${vm.refreshFps} fps',
                    onChanged: (value) {
                      vm.setRefreshFps(value.round());
                      setState(() {}); // 刷新对话框内部状态
                    },
                  ),
                  const Text(
                    '范围: 10~60 fps，默认 30 fps\n值越高绘图越流畅，但可能降低数据接收速率',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const Divider(),
                  // 抗锯齿开关
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('抗锯齿', style: TextStyle(fontSize: 14)),
                            Text(
                              '默认开启，通道>8时自动关闭',
                              style: TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: vm.antiAliasEnabled,
                        onChanged: (value) {
                          vm.setAntiAlias(value);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 通道列表项
///
/// 显示单个通道的颜色、名称、可见性开关和连线开关。
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
///
/// 根据当前解析器类型显示 FireWater 或固定帧的配置界面。
class _ParserConfigDialog extends StatefulWidget {
  final PlotViewModel vm;

  const _ParserConfigDialog({required this.vm});

  @override
  State<_ParserConfigDialog> createState() => _ParserConfigDialogState();
}

/// [_ParserConfigDialog] 的状态类
class _ParserConfigDialogState extends State<_ParserConfigDialog> {
  /// 解析器配置的本地副本（确定后才同步到 ViewModel）
  late ParserConfig _config;
  /// FireWater 通道数输入控制器
  late final TextEditingController _fireWaterController;
  /// 固定帧通道数输入控制器
  late final TextEditingController _fixedFrameController;

  @override
  void initState() {
    super.initState();
    _config = widget.vm.parserConfig.copyWith();
    _fireWaterController = TextEditingController(text: _config.fireWaterChannelCount.toString());
    _fixedFrameController = TextEditingController(text: _config.channelCount.toString());
  }

  @override
  void dispose() {
    _fireWaterController.dispose();
    _fixedFrameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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

  /// 构建 FireWater 解析器配置界面
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
              width: 80,
              child: TextField(
                controller: _fireWaterController,
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

  /// 构建固定帧解析器配置界面
  ///
  /// 包含帧头长度、帧头值、数据类型、通道数设置。
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
                width: 80,
                child: TextField(
                  controller: _fixedFrameController,
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

/// 可拖动的信息框组件
///
/// 支持用户拖动改变位置，位置保存在 State 中。
/// 用于显示测量信息和统计信息。
class _DraggableInfoBox extends StatefulWidget {
  final double initialRight;
  final double initialTop;
  final Color borderColor;
  final Widget child;

  const _DraggableInfoBox({
    required this.initialRight,
    required this.initialTop,
    required this.borderColor,
    required this.child,
  });

  @override
  State<_DraggableInfoBox> createState() => _DraggableInfoBoxState();
}

/// [_DraggableInfoBox] 的状态类
class _DraggableInfoBoxState extends State<_DraggableInfoBox> {
  /// 当前右边距（null 时使用初始值）
  double? _right;
  /// 当前上边距（null 时使用初始值）
  double? _top;
  /// 是否正在拖动
  bool _isDragging = false;
  /// 拖动起始指针位置
  Offset? _dragStart;
  /// 拖动起始右边距
  double? _dragStartRight;
  /// 拖动起始上边距
  double? _dragStartTop;

  @override
  Widget build(BuildContext context) {
    final right = _right ?? widget.initialRight;
    final top = _top ?? widget.initialTop;

    return Positioned(
      right: right,
      top: top,
      child: GestureDetector(
        onPanStart: (details) {
          _isDragging = true;
          _dragStart = details.globalPosition;
          _dragStartRight = right;
          _dragStartTop = top;
        },
        onPanUpdate: (details) {
          if (!_isDragging || _dragStart == null) return;
          final dx = _dragStart!.dx - details.globalPosition.dx;
          final dy = details.globalPosition.dy - _dragStart!.dy;
          setState(() {
            _right = (_dragStartRight! + dx).clamp(0.0, double.infinity);
            _top = (_dragStartTop! + dy).clamp(0.0, double.infinity);
          });
        },
        onPanEnd: (_) => _isDragging = false,
        onPanCancel: () => _isDragging = false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xDD1A1A2E),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: widget.borderColor),
          ),
          child: IntrinsicHeight(
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
