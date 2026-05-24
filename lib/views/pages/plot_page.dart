import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/zobow_config_profile.dart';
import '../../data/models/parser_config.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../dialogs/zobow_profile_dialog.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../widgets/common_widgets.dart';
import '../widgets/plot_status_bar.dart';

/// 绘图页面入口
///
/// PlotViewModel 已提升为全局 Provider（在 main.dart 中注册），
/// 此处直接消费全局实例，确保页面切换后数据不丢失。
class PlotPage extends StatelessWidget {
  const PlotPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _PlotPageContent();
  }
}

/// 绘图页面内容主体
///
/// 页面布局（从上到下）：
/// - 工具栏：开始/停止、数据源设置、解析器、光标/测量、缩放、导出等
/// - 主区域：左侧通道面板 + 右侧绘图区域
/// - 状态栏：视口范围、数据点数、光标信息
class _PlotPageContent extends StatefulWidget {
  const _PlotPageContent();

  @override
  State<_PlotPageContent> createState() => _PlotPageContentState();
}

/// 通道面板尺寸常量
const double kMinChannelPanelWidth = 240;
const double kMaxChannelPanelWidth = 400;
const double kDefaultChannelPanelWidth = 240;
const double kCollapsedPanelWidth = 26;

class _PlotPageContentState extends State<_PlotPageContent> {
  /// 面板是否折叠
  bool _isPanelCollapsed = false;

  /// 面板宽度（展开时）
  double _panelWidth = kDefaultChannelPanelWidth;

  /// 是否正在拖动调整宽度
  bool _isResizing = false;

  /// 是否显示悬浮图例
  bool _legendVisible = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<PlotViewModel>(
      builder: (context, vm, child) {
        return Column(
          children: [
            // 第一栏工具栏
            _buildPrimaryToolbar(context, vm),
            // 第二栏工具栏（光标+缩放）
            _buildSecondaryToolbar(context, vm),
            // 主区域
            Expanded(
              child: Row(
                children: [
                  // 通道设置面板（可折叠/可拉伸）
                  _buildChannelPanelArea(context, vm),
                  // 绘图区域
                  Expanded(child: _buildPlotArea(context, vm)),
                ],
              ),
            ),
            // 状态栏
            const PlotStatusBar(),
          ],
        );
      },
    );
  }

  /// 构建通道面板区域（折叠状态或展开状态）
  Widget _buildChannelPanelArea(BuildContext context, PlotViewModel vm) {
    if (_isPanelCollapsed) {
      return _buildCollapsedPanel(context);
    }
    return _buildExpandedPanel(context, vm);
  }

  /// 折叠后的窄条（32px）
  Widget _buildCollapsedPanel(BuildContext context) {
    return Container(
      width: kCollapsedPanelWidth,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          // 展开按钮（使用 InkWell 替代 IconButton，避免大圆阴影）
          Tooltip(
            message: '展开通道面板',
            child: InkWell(
              onTap: () => setState(() => _isPanelCollapsed = false),
              child: const SizedBox(
                width: 32,
                height: 32,
                child: Icon(Icons.chevron_right, size: 18),
              ),
            ),
          ),
          // 垂直文字 "通道"
          Expanded(
            child: Center(
              child: RotatedBox(
                quarterTurns: 1,
                child: Text(
                  '通道',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开后的可拉伸面板
  Widget _buildExpandedPanel(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 通道面板内容
        SizedBox(
          width: _panelWidth.clamp(
            kMinChannelPanelWidth,
            kMaxChannelPanelWidth,
          ),
          child: _buildChannelPanelContent(context, vm),
        ),
        // 右边缘拖动条
        MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            onHorizontalDragStart: (_) => setState(() => _isResizing = true),
            onHorizontalDragEnd: (_) => setState(() => _isResizing = false),
            onHorizontalDragCancel: () => setState(() => _isResizing = false),
            onHorizontalDragUpdate: (details) {
              setState(() {
                _panelWidth += details.delta.dx;
                _panelWidth = _panelWidth.clamp(
                  kMinChannelPanelWidth,
                  kMaxChannelPanelWidth,
                );
              });
            },
            child: Container(
              width: 4,
              color:
                  _isResizing
                      ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.5)
                      : Theme.of(context).dividerColor.withValues(alpha: 0.3),
              child: Center(
                child: Container(
                  width: 2,
                  height: 24,
                  decoration: BoxDecoration(
                    color:
                        _isResizing
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ========== 工具栏 ==========
  /// 构建顶部工具栏
  ///
  /// 使用 [LayoutBuilder] 实现响应式布局：根据可用宽度动态决定哪些工具组平铺显示、
  /// 哪些折叠到下拉菜单。折叠顺序从右到左，即最右边的组最先被折叠。
  ///
  /// 显示顺序：光标 | 缩放 | 自适应 | 文件 | 清空+设置
  /// 折叠顺序：清空+设置 → 文件 → 自适应 → 缩放 → 光标
  // ========== 工具栏 ==========
  /// 构建第一栏工具栏
  ///
  /// 包含：开始/停止、数据源设置、解析器、自适应、文件、清空+设置
  Widget _buildPrimaryToolbar(BuildContext context, PlotViewModel vm) {
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
          _buildStartStopButton(context, vm),
          const SizedBox(width: 12),
          if (vm.parserType == ParserType.fireWater) ...[
            _buildRandomSourceToggle(context, vm),
            const SizedBox(width: 12),
          ],
          // 解析器选择
          _buildParserSelector(context, vm),
          const Spacer(),
          // 自适应工具组
          _buildFitTools(context, vm),
          const SizedBox(width: 8),
          // 文件工具组
          _buildFileTools(context, vm),
          const SizedBox(width: 8),
          // 清空 + 高级设置
          _buildClearAndSettings(context, vm),
        ],
      ),
    );
  }

  /// 构建第二栏工具栏（光标+缩放）
  Widget _buildSecondaryToolbar(BuildContext context, PlotViewModel vm) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          // 光标和测量工具组
          _buildCursorTools(context, vm),
          const Spacer(),
          // 缩放和框选工具组
          _buildZoomTools(context, vm),
        ],
      ),
    );
  }

  Widget _buildStartStopButton(BuildContext context, PlotViewModel vm) {
    return ElevatedButton.icon(
      onPressed:
          vm.isStopping
              ? null
              : () {
                if (vm.isPlotting) {
                  vm.stopPlotting();
                } else {
                  vm.startPlotting();
                }
              },
      icon: Icon(
        vm.isStopping
            ? Icons.hourglass_empty
            : vm.isPlotting
            ? Icons.stop
            : Icons.play_arrow,
        size: 16,
      ),
      label: Text(
        vm.isStopping
            ? '停止中'
            : vm.isPlotting
            ? '停止'
            : '开始',
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor:
            vm.isStopping
                ? Colors.grey
                : vm.isPlotting
                ? Colors.red
                : Colors.green,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: const Size(0, 28),
      ),
    );
  }

  /// 随机数据源 + 频率设置
  Widget _buildRandomSourceToggle(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: vm.useRandomSource,
          onChanged: (value) => vm.setUseRandomSource(value!),
        ),
        const Text('随机源', style: TextStyle(fontSize: 12)),
        Tooltip(
          message: '设置随机源频率: ${vm.randomFrequency.toStringAsFixed(1)} Hz',
          child: InkWell(
            onTap: () => _showRandomFreqDialog(context, vm),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.settings,
                size: 16,
                color:
                    vm.useRandomSource
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 解析器选择 + 配置按钮 + Zobow配置文件选择
  Widget _buildParserSelector(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
            items:
                ParserType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(
                      type.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                  );
                }).toList(),
            onChanged: (value) {
              if (value != null) vm.setParserType(value);
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () => _showParserConfigDialog(context, vm),
          icon: const Icon(Icons.settings, size: 18),
          tooltip: '解析器配置',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        // Zobow模式下显示配置文件下拉框
        if (vm.parserType == ParserType.zobow) ...[
          const SizedBox(width: 8),
          _buildZobowProfileSelector(context, vm),
          // 新建配置按钮
          Tooltip(
            message: '新建配置',
            child: InkWell(
              onTap: () => _showCreateZobowProfileDialog(context, vm),
              child: const SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.add, size: 16),
              ),
            ),
          ),
          // 编辑配置按钮
          Tooltip(
            message: '编辑配置',
            child: InkWell(
              onTap: () => _showEditZobowProfileDialog(context, vm),
              child: const SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.edit, size: 16),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Zobow配置文件选择器
  Widget _buildZobowProfileSelector(BuildContext context, PlotViewModel vm) {
    return SizedBox(
      width: 140,
      child: NoAnimDropdown<String?>(
        value:
            vm.selectedZobowProfileId.isEmpty
                ? null
                : vm.selectedZobowProfileId,
        hint: '不使用配置',
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          border: OutlineInputBorder(),
        ),
        items: [
          // "不使用"选项
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('不使用配置', style: TextStyle(fontSize: 12)),
          ),
          // 所有配置文件
          ...vm.zobowProfiles.map((profile) {
            return DropdownMenuItem(
              value: profile.id,
              child: Text(profile.name, style: const TextStyle(fontSize: 12)),
            );
          }),
        ],
        onChanged: (value) {
          if (value == null) {
            vm.selectZobowProfile(null);
          } else {
            vm.selectZobowProfile(value);
          }
        },
      ),
    );
  }

  /// 光标和测量工具组
  ///
  /// 顺序：垂直光标 | X-X | Y-Y | 统计 | 范围 | 跟随
  Widget _buildCursorTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 垂直光标开关
        Tooltip(
          message: '垂直光标',
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
              backgroundColor:
                  vm.vCursorEnabled
                      ? Colors.orange.withValues(alpha: 0.1)
                      : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: '添加观察',
          child: TextButton.icon(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.addObservation(),
            icon: const Icon(Icons.add_location_alt, size: 16),
            label: const Text('观察', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // X-X 测量
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
              backgroundColor:
                  vm.xMeasurementEnabled
                      ? Colors.blue.withValues(alpha: 0.15)
                      : null,
            ),
          ),
        ),
        // Y-Y 测量
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
              backgroundColor:
                  vm.yMeasurementEnabled
                      ? Colors.blue.withValues(alpha: 0.15)
                      : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 统计测量
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
              backgroundColor:
                  vm.statsEnabled ? Colors.blue.withValues(alpha: 0.15) : null,
            ),
          ),
        ),
        // 统计范围
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
              backgroundColor:
                  vm.statsRangeEnabled
                      ? Colors.blue.withValues(alpha: 0.15)
                      : null,
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 最新点跟随
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
              backgroundColor:
                  vm.followEnabled ? Colors.blue.withValues(alpha: 0.1) : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: '图例',
          child: IconButton(
            onPressed: () => setState(() => _legendVisible = !_legendVisible),
            icon: Icon(
              Icons.list_alt,
              size: 18,
              color: _legendVisible ? Colors.teal : null,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            style: IconButton.styleFrom(
              backgroundColor:
                  _legendVisible ? Colors.teal.withValues(alpha: 0.12) : null,
            ),
          ),
        ),
      ],
    );
  }

  /// 缩放和框选工具组
  ///
  /// 顺序：撤回缩放 | 框选 | X缩 | X放 | Y缩 | Y放
  Widget _buildZoomTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        // 框选放大
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
      ],
    );
  }

  /// 文件工具组
  ///
  /// 顺序：导入 CSV | 导出 CSV
  Widget _buildFileTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 导入 CSV
        Tooltip(
          message: '导入 CSV（最大16通道）',
          child: IconButton(
            onPressed: () => _importCsv(context, vm),
            icon: const Icon(Icons.file_upload, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        // 导出 CSV
        Tooltip(
          message: '导出 CSV',
          child: IconButton(
            onPressed:
                vm.dataPoints.isEmpty ? null : () => _exportCsv(context, vm),
            icon: const Icon(Icons.save, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
      ],
    );
  }

  /// 自适应工具组
  ///
  /// 顺序：Y自适应 | X自适应 | 全自适应
  Widget _buildFitTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
      ],
    );
  }

  /// 清空 + 高级设置
  Widget _buildClearAndSettings(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: vm.dataPoints.isEmpty ? null : () => vm.clearData(),
          icon: const Icon(Icons.clear, size: 18),
          tooltip: '清空数据',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        const SizedBox(width: 8),
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
    );
  }

  /// 通道面板内容（展开状态）
  Widget _buildChannelPanelContent(BuildContext context, PlotViewModel vm) {
    // 只显示实际有数据的通道
    final activeCount =
        vm.activeChannelCount > 0 ? vm.activeChannelCount : vm.channels.length;
    final displayCount =
        vm.parserType == ParserType.zobow
            ? vm.parserConfig.zobowChannelCount
            : activeCount;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Tooltip(
                  message: '收起通道面板',
                  child: InkWell(
                    onTap: () => setState(() => _isPanelCollapsed = true),
                    child: const SizedBox(
                      width: 24,
                      height: 24,
                      child: Icon(Icons.chevron_left, size: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  '通道',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const Spacer(),
                Tooltip(
                  message: '偏置功能开关',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      SizedBox(width: 20),
                      Text('偏置', style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                // 全选/全不选勾选框
                Tooltip(
                  message:
                      vm.channels.every((ch) => ch.visible)
                          ? '点击隐藏全部'
                          : '点击显示全部',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        child: Checkbox(
                          value: vm.channels.every((ch) => ch.visible),
                          tristate: true,
                          onChanged: (_) {
                            // 点击时切换：如果当前全显则全隐，否则全显
                            final allVisible = vm.channels.every(
                              (ch) => ch.visible,
                            );
                            vm.setAllChannelsVisible(!allVisible);
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const Text('绘图', style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: displayCount,
              itemBuilder: (context, index) {
                final ch = vm.channels[index];
                return _ChannelItem(
                  key: ValueKey('ch_${ch.index}'),
                  vm: vm,
                  ch: ch,
                );
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
            Text(
              '点击"开始"按钮开始绘图',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    // 计算可见的偏移通道数量，同步到视口以动态调整右边距
    final offsetChannelCount =
        vm.channels.where((c) => c.visible && c.offsetEnabled).length;
    vm.viewport.setOffsetChannelCount(offsetChannelCount);

    return Stack(
      children: [
        PlotGestureHandler(
          viewport: vm.viewport,
          vCursorEnabled: vm.vCursorEnabled,
          boxZoomEnabled: vm.boxZoomEnabled,
          refreshFps: vm.refreshFps,
          plotFontSizeDelta: vm.plotFontSizeDelta,
          channels: vm.channels,
          observations: vm.observations,
          onObservationDrag: (index, x) => vm.updateObservation(index, x),
          onObservationDelete: (index) => vm.removeObservation(index),
          onViewportChanged:
              (viewport, {fromDrag = false}) =>
                  vm.updateViewport(viewport, fromDrag: fromDrag),
          onCursorChanged: (cursor) {
            if (cursor != null) {
              vm.updateFollowCursor(
                cursor.x,
                cursor.y ?? 0,
                cursor.screenPosition ?? Offset.zero,
              );
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
          onXCursor1Drag:
              vm.xMeasurementEnabled ? (x) => vm.setXCursor1(x) : null,
          onXCursor2Drag:
              vm.xMeasurementEnabled ? (x) => vm.setXCursor2(x) : null,
          onYCursor1Drag:
              vm.yMeasurementEnabled ? (y) => vm.setYCursor1(y) : null,
          onYCursor2Drag:
              vm.yMeasurementEnabled ? (y) => vm.setYCursor2(y) : null,
          // 统计范围位置
          statsX1: vm.statsRangeEnabled ? vm.statsX1 : null,
          statsX2: vm.statsRangeEnabled ? vm.statsX2 : null,
          // 统计范围拖动回调
          onStatsX1Drag: vm.statsRangeEnabled ? (x) => vm.setStatsX1(x) : null,
          onStatsX2Drag: vm.statsRangeEnabled ? (x) => vm.setStatsX2(x) : null,
          // 通道偏移拖动回调
          onChannelOffsetDrag:
              (index, yOffset) => vm.setChannelYOffset(index, yOffset),
          // 通道 Y 轴缩放回调（Shift+滚轮在偏置Y轴列上）
          onChannelYScaleZoom:
              (index, scaleDelta) => vm.zoomChannelYScale(index, scaleDelta),
          child: CustomPaint(
            painter: PlotPainter(
              viewport: vm.viewport,
              data: vm.dataPoints,
              dataRevision: vm.dataRevision,
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
              plotFontSizeDelta: vm.plotFontSizeDelta,
            ),
            size: Size.infinite,
          ),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                children: _buildObservationWidgets(
                  context,
                  vm,
                  Size(constraints.maxWidth, constraints.maxHeight),
                ),
              );
            },
          ),
        ),
        // 测量信息框（X-X / Y-Y 测量值显示 + 统计信息）
        if (vm.measurementText != null || vm.statsText != null)
          _buildCombinedInfoBox(context, vm),
        if (_legendVisible) _buildLegendBox(vm),
      ],
    );
  }

  double _plotFontSize(PlotViewModel vm, double base) {
    return (base + vm.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  List<Widget> _buildObservationWidgets(
    BuildContext context,
    PlotViewModel vm,
    Size size,
  ) {
    final widgets = <Widget>[];
    final viewport = vm.viewport;
    final plotTop = viewport.marginTop;
    final plotBottom = size.height - viewport.marginBottom;
    final plotLeft = viewport.marginLeft;
    final plotRight = size.width - viewport.marginRight;

    for (int i = 0; i < vm.observations.length; i++) {
      final observation = vm.observations[i];
      final sx = viewport.dataToScreenX(observation.x, size.width);
      if (sx < plotLeft || sx > plotRight) continue;

      widgets.add(
        Positioned(
          left: sx - 5,
          top: plotTop,
          bottom: viewport.marginBottom,
          child: IgnorePointer(
            child: SizedBox(
              width: 10,
              child: Center(
                child: Container(
                  width: 1,
                  color: Colors.amber.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ),
      );
      widgets.add(
        Positioned(
          left: (sx - 22).clamp(plotLeft, plotRight - 44).toDouble(),
          top: plotTop - 24,
          child: IgnorePointer(
            child: Container(
              width: 44,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: Colors.black54, width: 0.5),
              ),
              child: Text(
                'O${i + 1}',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: _plotFontSize(vm, 10),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
      widgets.add(
        Positioned(
          left: (sx + 10).clamp(plotLeft, plotRight - 180).toDouble(),
          top: (plotTop + 8 + i * 8).clamp(plotTop, plotBottom - 80).toDouble(),
          child: IgnorePointer(
            child: _buildObservationTooltip(observation, vm),
          ),
        ),
      );
    }

    return widgets;
  }

  Widget _buildObservationTooltip(CursorState observation, PlotViewModel vm) {
    final values = observation.channelValues;
    final rows = <Widget>[
      Text(
        'X: ${observation.x.toInt()}',
        style: TextStyle(
          color: Colors.white,
          fontSize: _plotFontSize(vm, 12),
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    ];
    if (observation.hasData && values != null) {
      for (int i = 0; i < values.length && i < vm.channels.length; i++) {
        final channel = vm.channels[i];
        if (!channel.visible) continue;
        final name = channel.alias.isNotEmpty ? channel.alias : 'Ch$i';
        rows.add(
          Text(
            '$name: ${_formatExactNumber(values[i])}',
            style: TextStyle(
              color: channel.color,
              fontSize: _plotFontSize(vm, 12),
              fontFamily: 'monospace',
            ),
          ),
        );
      }
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xEE1A1A2E),
        border: Border.all(color: const Color(0xFF8888AA), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  String _formatExactNumber(double value) {
    if (!value.isFinite) return value.toString();
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  Widget _buildLegendBox(PlotViewModel vm) {
    final displayCount = _activeDisplayChannelCount(vm);
    final visibleChannels =
        vm.channels
            .take(displayCount)
            .where((channel) => channel.visible)
            .toList();
    if (visibleChannels.isEmpty) return const SizedBox.shrink();

    return _DraggableInfoBox(
      initialRight: 16,
      initialTop: 96,
      borderColor: Colors.teal.withValues(alpha: 0.55),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220, maxHeight: 320),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '图例',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: _plotFontSize(vm, 12),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              ...visibleChannels.map((channel) {
                final name =
                    channel.alias.isNotEmpty
                        ? 'Ch${channel.index}  ${channel.alias}'
                        : 'Ch${channel.index}';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: channel.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _plotFontSize(vm, 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  int _activeDisplayChannelCount(PlotViewModel vm) {
    if (vm.activeChannelCount > 0) {
      return vm.activeChannelCount.clamp(0, vm.channels.length).toInt();
    }

    switch (vm.parserType) {
      case ParserType.zobow:
        return vm.parserConfig.zobowChannelCount
            .clamp(0, vm.channels.length)
            .toInt();
      case ParserType.fireWater:
        final configured = vm.parserConfig.fireWaterChannelCount;
        return (configured > 0 ? configured : vm.channels.length)
            .clamp(0, vm.channels.length)
            .toInt();
      case ParserType.fixedFrame:
        return vm.parserConfig.channelCount
            .clamp(0, vm.channels.length)
            .toInt();
    }
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
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
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
    ).whenComplete(controller.dispose);
  }

  /// 导出数据到 CSV 文件
  ///
  /// 弹出文件保存对话框，导出完成后在底部状态栏显示提示。
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
      vm.showStatusMessage('已导出: $path');
    }
  }

  /// 从 CSV 文件导入数据
  ///
  /// 支持格式：表头 x,y1,y2,...，最大16通道。
  /// 导入成功后会清空现有数据并替换。
  void _importCsv(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择 CSV 文件',
      type: FileType.custom,
      allowedExtensions: ['csv'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final error = await vm.importFromCsv(filePath);
    if (context.mounted) {
      if (error == null) {
        vm.showStatusMessage('CSV 导入成功');
      } else {
        vm.showStatusMessage('导入失败: $error');
      }
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
  Widget _buildDensityButton(
    String label,
    String density,
    PlotViewModel vm,
    StateSetter setState,
  ) {
    final isSelected = vm.gridDensity == density;
    return Expanded(
      child: TextButton(
        onPressed: () {
          vm.setGridDensity(density);
          setState(() {});
        },
        style: TextButton.styleFrom(
          backgroundColor:
              isSelected ? Colors.blue.withValues(alpha: 0.2) : null,
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
          style: TextStyle(
            color: Colors.white,
            fontSize: _plotFontSize(vm, 12),
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
      children.add(_buildStatsContent(vm.statsText!, vm));
    }

    return _DraggableInfoBox(
      initialRight: 16,
      initialTop: 16,
      borderColor:
          vm.statsText != null
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
  Widget _buildStatsContent(String text, PlotViewModel vm) {
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
    final columnCount = (channelBlocks.length / maxChannelsPerColumn)
        .ceil()
        .clamp(1, 4);

    if (columnCount == 1) {
      return Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: _plotFontSize(vm, 11),
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
          style: TextStyle(
            color: Colors.white,
            fontSize: _plotFontSize(vm, 11),
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
    final maxVisibleController = TextEditingController(
      text: vm.maxVisiblePoints.toString(),
    );
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: const Text('高级设置'),
            content: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return SingleChildScrollView(
                    child: Column(
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
                            Text(
                              '${vm.refreshFps} fps',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${(1000 / vm.refreshFps).round()}ms',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
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
                        const Text('绘图字体大小', style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              vm.plotFontSizeDelta == 0
                                  ? '默认'
                                  : vm.plotFontSizeDelta > 0
                                  ? '+${vm.plotFontSizeDelta}'
                                  : '${vm.plotFontSizeDelta}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '基于默认字号',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: vm.plotFontSizeDelta.toDouble(),
                          min: -3,
                          max: 6,
                          divisions: 9,
                          label:
                              vm.plotFontSizeDelta == 0
                                  ? '默认'
                                  : vm.plotFontSizeDelta > 0
                                  ? '+${vm.plotFontSizeDelta}'
                                  : '${vm.plotFontSizeDelta}',
                          onChanged: (value) {
                            vm.setPlotFontSizeDelta(value.round());
                            setState(() {});
                          },
                        ),
                        const Text(
                          '范围: -3~+6，影响绘图区坐标轴、光标、观察、测量和统计文本',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const Divider(),
                        // 窗口点数上限
                        const Text('绘图窗口上限', style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: maxVisibleController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  suffixText: '包',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onSubmitted: (value) {
                                  final points = int.tryParse(value);
                                  if (points != null) {
                                    vm.setMaxVisiblePoints(points);
                                    maxVisibleController.text =
                                        vm.maxVisiblePoints.toString();
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () {
                                final points = int.tryParse(
                                  maxVisibleController.text,
                                );
                                if (points != null) {
                                  vm.setMaxVisiblePoints(points);
                                  maxVisibleController.text =
                                      vm.maxVisiblePoints.toString();
                                  setState(() {});
                                }
                              },
                              child: const Text('应用'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '范围: ${PlotViewModel.minVisiblePoints}~${PlotViewModel.maxVisiblePointsLimit} 包，默认 ${PlotViewModel.defaultVisiblePoints} 包。当前窗口: ${vm.visiblePointCount} 包',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
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
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),
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
                    ),
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
    ).whenComplete(maxVisibleController.dispose);
  }

  /// 显示新建Zobow配置文件对话框
  void _showCreateZobowProfileDialog(BuildContext context, PlotViewModel vm) {
    showDialog(
      context: context,
      builder: (context) => ZobowProfileDialog(vm: vm),
    );
  }

  /// 显示编辑Zobow配置文件对话框
  void _showEditZobowProfileDialog(BuildContext context, PlotViewModel vm) {
    final profile = vm.selectedZobowProfile;
    if (profile == null) {
      vm.showStatusMessage('请先选择一个配置文件');
      return;
    }
    showDialog(
      context: context,
      builder: (context) => ZobowProfileDialog(vm: vm, profile: profile),
    );
  }
}

/// 通道列表项
///
/// 显示单个通道的颜色、名称/别名、绘图开关和编辑按钮。
/// 支持双击通道名直接编辑别名，众邦电控模式下支持直接编辑ID。
class _ChannelItem extends StatefulWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelItem({super.key, required this.vm, required this.ch});

  @override
  State<_ChannelItem> createState() => _ChannelItemState();
}

class _ChannelItemState extends State<_ChannelItem> {
  bool _isEditingName = false;
  late final TextEditingController _nameController;
  late final TextEditingController _idController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _idController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  /// 获取显示名称（别名优先，空则回退到 ChN）
  String get _displayName =>
      widget.ch.alias.isNotEmpty ? widget.ch.alias : 'Ch${widget.ch.index}';

  void _saveAlias() {
    final text = _nameController.text.trim();
    // 空输入则恢复默认名称（清空别名）
    widget.vm.setChannelAlias(widget.ch.index, text);
    setState(() => _isEditingName = false);
  }

  void _saveZobowId() {
    final text = _idController.text.trim();
    final hex = text.replaceAll('0x', '').replaceAll('0X', '');
    final id = int.tryParse(hex, radix: 16);
    if (id != null && id >= 0 && id <= 0xFFFFFFFF) {
      widget.vm.setZobowChannelId(widget.ch.index, id);
    }
  }

  void _onZobowIdFocusChange(bool hasFocus) {
    if (!hasFocus) {
      // 失去焦点时取消文本选择
      _idController.selection = TextSelection.collapsed(
        offset: _idController.text.length,
      );
      _saveZobowId();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZobowMode =
        widget.vm.parserType == ParserType.zobow &&
        widget.ch.index < widget.vm.parserConfig.zobowChannelCount;

    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // 颜色指示器（点击打开编辑弹窗）
          InkWell(
            onTap: () => _showChannelEditDialog(context),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: widget.ch.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 通道名/别名（双击编辑）+ 众邦电控ID（直接编辑）并排显示
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 通道名称：双击进入编辑模式
                Flexible(
                  child:
                      _isEditingName
                          ? SizedBox(
                            height: 24,
                            child: TextField(
                              controller: _nameController..text = _displayName,
                              autofocus: true,
                              maxLength: 8,
                              style: const TextStyle(fontSize: 14),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 0,
                                ),
                                border: UnderlineInputBorder(),
                                counterText: '',
                              ),
                              onSubmitted: (_) => _saveAlias(),
                              onEditingComplete: _saveAlias,
                              onTapOutside: (_) => _saveAlias(),
                            ),
                          )
                          : GestureDetector(
                            onDoubleTap: () {
                              setState(() {
                                _isEditingName = true;
                                _nameController.text = _displayName;
                              });
                            },
                            child: Text(
                              _displayName,
                              style: TextStyle(
                                fontSize: 14,
                                color: widget.ch.visible ? null : Colors.grey,
                                decoration:
                                    widget.ch.visible
                                        ? null
                                        : TextDecoration.lineThrough,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                ),
                // 众邦电控模式下显示地址，常驻可编辑 TextField
                if (isZobowMode) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 86,
                    height: 20,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Focus(
                      onFocusChange: _onZobowIdFocusChange,
                      child: TextField(
                        controller:
                            _idController
                              ..text =
                                  '0x${widget.vm.parserConfig.zobowChannelIds[widget.ch.index].toRadixString(16).toUpperCase().padLeft(8, '0')}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.0,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 0,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Colors.grey.shade400,
                              width: 1,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Colors.grey.shade400,
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _saveZobowId(),
                        onEditingComplete: _saveZobowId,
                      ),
                    ),
                  ),
                  // 预设选择按钮
                  _buildPresetButton(context),
                ],
              ],
            ),
          ),
          Tooltip(
            message: widget.ch.offsetEnabled ? '关闭偏置' : '开启偏置',
            child: SizedBox(
              width: 20,
              height: 24,
              child: Checkbox(
                value: widget.ch.offsetEnabled,
                onChanged:
                    (value) => widget.vm.setChannelOffsetEnabled(
                      widget.ch.index,
                      value!,
                    ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 5),
          // 绘图开关
          Tooltip(
            message: widget.ch.visible ? '点击隐藏通道' : '点击显示通道',
            child: SizedBox(
              width: 20,
              height: 24,
              child: Checkbox(
                value: widget.ch.visible,
                onChanged:
                    (value) =>
                        widget.vm.setChannelVisible(widget.ch.index, value!),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          // 编辑按钮
          Tooltip(
            message: '编辑通道',
            child: InkWell(
              onTap: () => _showChannelEditDialog(context),
              child: const SizedBox(
                width: 20,
                height: 24,
                child: Icon(Icons.settings, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示通道编辑弹窗
  void _showChannelEditDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _ChannelEditDialog(vm: widget.vm, ch: widget.ch),
    );
  }

  /// 构建预设选择按钮（仅在Zobow模式下且有选中配置文件时显示）
  Widget _buildPresetButton(BuildContext context) {
    final profile = widget.vm.selectedZobowProfile;
    if (profile == null || profile.presets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: '选择地址',
      child: InkWell(
        onTap: () => _showPresetSelectorDialog(context, profile),
        child: Container(
          width: 20,
          height: 20,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Icon(
            Icons.chevron_right,
            size: 14,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  /// 显示预设选择弹窗
  void _showPresetSelectorDialog(
    BuildContext context,
    ZobowConfigProfile profile,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return _PresetSelectorDialog(
          profile: profile,
          onSelect: (preset) {
            widget.vm.applyPresetToChannel(widget.ch.index, preset);
          },
        );
      },
    );
  }
}

/// 通道编辑对话框
///
/// 可修改通道颜色、别名、连线开关。
class _ChannelEditDialog extends StatefulWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelEditDialog({required this.vm, required this.ch});

  @override
  State<_ChannelEditDialog> createState() => _ChannelEditDialogState();
}

class _ChannelEditDialogState extends State<_ChannelEditDialog> {
  late Color _selectedColor;
  late String _alias;
  late bool _showLine;
  late double _pointSize;
  late double _lineWidth;
  late bool _offsetEnabled;
  late DataType _zobowDataType;
  late final TextEditingController _aliasController;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.ch.color;
    _alias = widget.ch.alias;
    _showLine = widget.ch.showLine;
    _pointSize = widget.ch.pointSize;
    _lineWidth = widget.ch.lineWidth;
    _offsetEnabled = widget.ch.offsetEnabled;
    // 众邦电控模式下，使用通道配置的数据类型
    _zobowDataType =
        widget.ch.dataType == DataType.int16 ? DataType.int16 : DataType.uint16;
    _aliasController = TextEditingController(text: _alias);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contentMaxHeight =
        (MediaQuery.sizeOf(context).height - 220)
            .clamp(240.0, 540.0)
            .toDouble();

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text('编辑 Ch${widget.ch.index}'),
      content: SizedBox(
        width: 280,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: contentMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 颜色选择
                const Text(
                  '颜色',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildColorPicker(),
                const SizedBox(height: 14),
                // 别名输入
                const Text(
                  '别名',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _aliasController,
                  maxLength: 16,
                  decoration: const InputDecoration(
                    hintText: '输入通道别名',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    counterText: '',
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                // 连线开关
                Row(
                  children: [
                    const Text(
                      '连线显示',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _showLine,
                      onChanged: (value) => setState(() => _showLine = value),
                    ),
                  ],
                ),
                if (_showLine) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Text('线宽', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: _lineWidth,
                          min: 0.5,
                          max: 8.0,
                          divisions: 15,
                          label: _lineWidth.toStringAsFixed(1),
                          onChanged:
                              (value) => setState(() => _lineWidth = value),
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          _lineWidth.toStringAsFixed(1),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Text('点半径', style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _pointSize,
                        min: 0.5,
                        max: 12.0,
                        divisions: 23,
                        label: _pointSize.toStringAsFixed(1),
                        onChanged:
                            (value) => setState(() => _pointSize = value),
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text(
                        _pointSize.toStringAsFixed(1),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                // 偏移开关
                Row(
                  children: [
                    const Text(
                      '偏移显示',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _offsetEnabled,
                      onChanged:
                          (value) => setState(() => _offsetEnabled = value),
                    ),
                  ],
                ),
                if (_offsetEnabled) ...[
                  const SizedBox(height: 2),
                  Text(
                    '提示：开启后可在绘图区拖动通道标签调整偏移位置',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
                // 众邦电控模式下显示数据类型选择
                if (widget.vm.parserType == ParserType.zobow &&
                    widget.ch.index < 4) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '数据类型',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '仅在众邦电控协议生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: NoAnimDropdown<DataType>(
                          value: _zobowDataType,
                          hint: '类型',
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                          ),
                          items:
                              [DataType.uint16, DataType.int16].map((type) {
                                return DropdownMenuItem(
                                  value: type,
                                  child: Text(
                                    type.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                );
                              }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _zobowDataType = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.vm.setChannelColor(widget.ch.index, _selectedColor);
            widget.vm.setChannelAlias(
              widget.ch.index,
              _aliasController.text.trim(),
            );
            widget.vm.setChannelShowLine(widget.ch.index, _showLine);
            widget.vm.setChannelLineWidth(widget.ch.index, _lineWidth);
            widget.vm.setChannelPointSize(widget.ch.index, _pointSize);
            widget.vm.setChannelOffsetEnabled(widget.ch.index, _offsetEnabled);
            // 众邦电控模式下同步数据类型
            if (widget.vm.parserType == ParserType.zobow &&
                widget.ch.index < 4) {
              widget.vm.setZobowChannelType(widget.ch.index, _zobowDataType);
            }
            Navigator.pop(context);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 构建颜色选择器（16色 4×4 网格）
  Widget _buildColorPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children:
          ChannelConfig.defaultColors.map((color) {
            final isSelected = color.toARGB32() == _selectedColor.toARGB32();
            return InkWell(
              onTap: () => setState(() => _selectedColor = color),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                  border:
                      isSelected
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                  boxShadow:
                      isSelected
                          ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                            ),
                          ]
                          : null,
                ),
                child:
                    isSelected
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
              ),
            );
          }).toList(),
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
    _fireWaterController = TextEditingController(
      text: _config.fireWaterChannelCount.toString(),
    );
    _fixedFrameController = TextEditingController(
      text: _config.channelCount.toString(),
    );
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
      content: SizedBox(width: 300, child: _buildConfigContent()),
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
        const Text(
          'FireWater 格式:',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
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
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
            const Text(
              '(0=自动识别)',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ],
    );
  }

  /// 根据当前解析器类型构建对应的配置界面
  Widget _buildConfigContent() {
    switch (widget.vm.parserType) {
      case ParserType.fireWater:
        return _buildFireWaterConfig();
      case ParserType.fixedFrame:
        return _buildFixedFrameConfig();
      case ParserType.zobow:
        return _buildZobowConfig();
    }
  }

  /// 构建 众邦电控解析器配置界面
  ///
  /// 包含4个通道的通道号（4字节16进制）和数据类型（uint16/int16）设置。
  Widget _buildZobowConfig() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('众邦电控配置', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('通道数:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: NoAnimDropdown<int>(
                  value: _config.zobowChannelCount,
                  hint: '通道数',
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                  items:
                      const [4, 8].map((count) {
                        return DropdownMenuItem(
                          value: count,
                          child: Text('$count 通道'),
                        );
                      }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _config.channelCount = value);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_config.zobowChannelCount * 2}字节数据 + 2字节CRC16(MODBUS)',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          ...List.generate(_config.zobowChannelCount, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text('Ch$i:', style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 6),
                  // 通道号输入（4字节16进制）
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: TextEditingController(
                        text:
                            '0x${_config.zobowChannelIds[i].toRadixString(16).toUpperCase().padLeft(8, '0')}',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '通道号',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                      ),
                      style: const TextStyle(fontSize: 11),
                      onChanged: (value) {
                        final hex = value
                            .replaceAll('0x', '')
                            .replaceAll('0X', '');
                        final id = int.tryParse(hex, radix: 16);
                        if (id != null && id >= 0 && id <= 0xFFFFFFFF) {
                          setState(() => _config.zobowChannelIds[i] = id);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 数据类型选择
                  SizedBox(
                    width: 90,
                    child: NoAnimDropdown<DataType>(
                      value: _config.zobowChannelTypes[i],
                      hint: '类型',
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                      ),
                      items:
                          [DataType.uint16, DataType.int16].map((type) {
                            return DropdownMenuItem(
                              value: type,
                              child: Text(
                                type.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _config.zobowChannelTypes[i] = value);
                        }
                      },
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          // 众邦电控协议固定发送配置，无需开关
        ],
      ),
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
                  controller: TextEditingController(
                    text: _config.frameHeaderLength.toString(),
                  ),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
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
                        text:
                            '0x${_config.frameHeader[i].toRadixString(16).toUpperCase().padLeft(2, '0')}',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                      ),
                      style: const TextStyle(fontSize: 11),
                      onChanged: (value) {
                        final hex = value
                            .replaceAll('0x', '')
                            .replaceAll('0X', '');
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                  items:
                      DataType.values.map((type) {
                        return DropdownMenuItem(
                          value: type,
                          child: Text(
                            type.label,
                            style: const TextStyle(fontSize: 12),
                          ),
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
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

/// 工具栏分组枚举
///
/// 用于动态折叠计算，按优先级排序。
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
          child: IntrinsicHeight(child: widget.child),
        ),
      ),
    );
  }
}

/// 预设选择弹窗（支持单列/平铺切换）
class _PresetSelectorDialog extends StatefulWidget {
  final ZobowConfigProfile profile;
  final ValueChanged<ZobowChannelPreset> onSelect;

  const _PresetSelectorDialog({required this.profile, required this.onSelect});

  @override
  State<_PresetSelectorDialog> createState() => _PresetSelectorDialogState();
}

enum _PresetViewMode { list, grid }

class _PresetSelectorDialogState extends State<_PresetSelectorDialog> {
  _PresetViewMode _viewMode = _PresetViewMode.grid;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFFF0F0F5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              '选择地址 - ${widget.profile.name}',
              style: const TextStyle(color: Color(0xFF333344), fontSize: 15),
            ),
          ),
          // 视图切换按钮
          Tooltip(
            message: _viewMode == _PresetViewMode.list ? '切换为平铺' : '切换为列表',
            child: InkWell(
              onTap:
                  () => setState(() {
                    _viewMode =
                        _viewMode == _PresetViewMode.list
                            ? _PresetViewMode.grid
                            : _PresetViewMode.list;
                  }),
              child: Icon(
                _viewMode == _PresetViewMode.list
                    ? Icons.grid_view
                    : Icons.list,
                size: 20,
                color: const Color(0xFF666688),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: _viewMode == _PresetViewMode.list ? 320 : 540,
        height: 360,
        child:
            _viewMode == _PresetViewMode.list
                ? _buildListView()
                : _buildGridView(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Color(0xFF666688))),
        ),
      ],
    );
  }

  /// 单列列表视图（每行较细）
  Widget _buildListView() {
    return ListView.builder(
      itemCount: widget.profile.presets.length,
      itemBuilder: (context, index) {
        final preset = widget.profile.presets[index];
        final hexAddr =
            '0x${preset.address.toRadixString(16).toUpperCase().padLeft(8, '0')}';
        return InkWell(
          onTap: () {
            widget.onSelect(preset);
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFFD0D0E0).withValues(alpha: 0.5),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    preset.name,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF333344),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  hexAddr,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8888AA),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 5列平铺视图
  Widget _buildGridView() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        childAspectRatio: 1.8,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: widget.profile.presets.length,
      itemBuilder: (context, index) {
        final preset = widget.profile.presets[index];
        final hexAddr =
            '0x${preset.address.toRadixString(16).toUpperCase().padLeft(8, '0')}';
        return InkWell(
          onTap: () {
            widget.onSelect(preset);
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFD0D0E0), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  preset.name,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF333344),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                const SizedBox(height: 2),
                Text(
                  hexAddr,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF8888AA),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
