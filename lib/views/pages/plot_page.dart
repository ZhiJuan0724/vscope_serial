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
  ///
  /// 使用 [LayoutBuilder] 实现响应式布局：根据可用宽度动态决定哪些工具组平铺显示、
  /// 哪些折叠到下拉菜单。折叠顺序从右到左，即最右边的组最先被折叠。
  ///
  /// 显示顺序：光标 | 缩放 | 自适应 | 文件 | 清空+设置
  /// 折叠顺序：清空+设置 → 文件 → 自适应 → 缩放 → 光标
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          const groupSpacing = 8.0;
          const menuButtonWidth = 40.0;

          // 左侧固定区域估算宽度
          const leftWidth = 360.0;

          // 各右侧组的估算宽度（留 10% 余量防止溢出）
          const groupWidths = {
            _ToolbarGroup.cursor: 396.0,
            _ToolbarGroup.zoom: 255.0,
            _ToolbarGroup.fit: 119.0,
            _ToolbarGroup.file: 80.0,
            _ToolbarGroup.clearSettings: 88.0,
          };

          // 右侧所有组的总宽度（含间距）
          final totalRightWidth = groupWidths.values.reduce((a, b) => a + b) + groupSpacing * 5;

          // 可用宽度（扣除左侧和菜单按钮）
          final availableWidth = constraints.maxWidth - leftWidth - menuButtonWidth;

          // 计算需要折叠多少组：从右边开始，空间不够就折叠
          // 所有组默认显示（按显示顺序排列）
          final groups = <_ToolbarGroup>[
            _ToolbarGroup.cursor,
            _ToolbarGroup.zoom,
            _ToolbarGroup.fit,
            _ToolbarGroup.file,
            _ToolbarGroup.clearSettings,
          ];

          // 如果总宽度超过可用宽度，从右边开始逐个折叠
          var currentWidth = totalRightWidth;
          while (currentWidth > availableWidth && groups.isNotEmpty) {
            // 移除最右边的组
            final removed = groups.removeLast();
            currentWidth -= (groupWidths[removed] ?? 0) + groupSpacing;
          }

          final hasCollapsed = groups.length < 5;

          return Row(
            children: [
              // ===== 左侧：开始/停止、数据源、解析器（始终显示） =====
              _buildStartStopButton(context, vm),
              const SizedBox(width: 12),
              _buildRandomSourceToggle(context, vm),
              const SizedBox(width: 12),
              _buildParserSelector(context, vm),
              const Spacer(),

              // ===== 右侧工具组（动态决定哪些平铺、哪些折叠） =====
              if (groups.contains(_ToolbarGroup.cursor)) ...[
                _buildCursorTools(context, vm),
                const SizedBox(width: groupSpacing),
              ],
              if (groups.contains(_ToolbarGroup.zoom)) ...[
                _buildZoomTools(context, vm),
                const SizedBox(width: groupSpacing),
              ],
              if (groups.contains(_ToolbarGroup.fit)) ...[
                _buildFitTools(context, vm),
                const SizedBox(width: groupSpacing),
              ],
              if (groups.contains(_ToolbarGroup.file)) ...[
                _buildFileTools(context, vm),
                const SizedBox(width: groupSpacing),
              ],
              if (groups.contains(_ToolbarGroup.clearSettings)) ...[
                _buildClearAndSettings(context, vm),
                const SizedBox(width: groupSpacing),
              ],
              // 有折叠的组时显示下拉菜单
              if (hasCollapsed)
                _buildCollapsedMenu(context, vm, visibleGroups: groups),
            ],
          );
        },
      ),
    );
  }

  /// 开始/停止按钮
  Widget _buildStartStopButton(BuildContext context, PlotViewModel vm) {
    return ElevatedButton.icon(
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
                color: vm.useRandomSource
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 解析器选择 + 配置按钮
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
        IconButton(
          onPressed: () => _showParserConfigDialog(context, vm),
          icon: const Icon(Icons.settings, size: 18),
          tooltip: '解析器配置',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
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
              backgroundColor: vm.vCursorEnabled
                  ? Colors.orange.withValues(alpha: 0.1)
                  : null,
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
              backgroundColor: vm.xMeasurementEnabled
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
              backgroundColor: vm.yMeasurementEnabled
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
              backgroundColor: vm.statsEnabled
                  ? Colors.blue.withValues(alpha: 0.15)
                  : null,
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
              backgroundColor: vm.statsRangeEnabled
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
              backgroundColor: vm.followEnabled
                  ? Colors.blue.withValues(alpha: 0.1)
                  : null,
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
            onPressed: vm.dataPoints.isEmpty ? null : () => _exportCsv(context, vm),
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

  /// 折叠菜单：只显示未平铺的组
  Widget _buildCollapsedMenu(
    BuildContext context,
    PlotViewModel vm, {
    required List<_ToolbarGroup> visibleGroups,
  }) {
    return PopupMenuButton<String>(
      tooltip: '更多工具',
      icon: const Icon(Icons.more_vert, size: 20),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];

        // 光标组（如果未平铺）
        if (!visibleGroups.contains(_ToolbarGroup.cursor)) {
          items.add(_buildMenuHeader('光标与测量'));
          items.add(PopupMenuItem(
            value: 'vCursor',
            child: _buildMenuItem(
              icon: Icons.vertical_align_center,
              label: '垂直光标',
              active: vm.vCursorEnabled,
              activeColor: Colors.orange,
            ),
            onTap: () => vm.setVCursorEnabled(!vm.vCursorEnabled),
          ));
          items.add(PopupMenuItem(
            value: 'xMeasurement',
            child: _buildMenuItem(
              icon: Icons.vertical_align_center,
              label: 'X-X 测量',
              active: vm.xMeasurementEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.toggleXMeasurement(),
          ));
          items.add(PopupMenuItem(
            value: 'yMeasurement',
            child: _buildMenuItem(
              icon: Icons.horizontal_rule,
              label: 'Y-Y 测量',
              active: vm.yMeasurementEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.toggleYMeasurement(),
          ));
          items.add(PopupMenuItem(
            value: 'stats',
            child: _buildMenuItem(
              icon: Icons.analytics,
              label: '统计测量',
              active: vm.statsEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.toggleStats(),
          ));
          items.add(PopupMenuItem(
            value: 'statsRange',
            enabled: vm.statsEnabled,
            child: _buildMenuItem(
              icon: Icons.straighten,
              label: '统计范围',
              active: vm.statsRangeEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.toggleStatsRange(),
          ));
          items.add(PopupMenuItem(
            value: 'follow',
            child: _buildMenuItem(
              icon: Icons.trending_flat,
              label: '最新点跟随',
              active: vm.followEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.setFollowEnabled(!vm.followEnabled),
          ));
        }

        // 缩放组（如果未平铺）
        if (!visibleGroups.contains(_ToolbarGroup.zoom)) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('缩放'));
          items.add(PopupMenuItem(
            value: 'undoZoom',
            enabled: vm.canUndoZoom,
            child: _buildMenuItem(icon: Icons.undo, label: '撤回缩放'),
            onTap: () => vm.undoZoom(),
          ));
          items.add(PopupMenuItem(
            value: 'boxZoom',
            child: _buildMenuItem(
              icon: Icons.crop_free,
              label: '框选放大',
              active: vm.boxZoomEnabled,
              activeColor: Colors.blue,
            ),
            onTap: () => vm.setBoxZoomEnabled(!vm.boxZoomEnabled),
          ));
          items.add(PopupMenuItem(
            value: 'zoomXOut',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.zoom_out, label: 'X 轴缩小'),
            onTap: () => vm.zoomXOut(),
          ));
          items.add(PopupMenuItem(
            value: 'zoomXIn',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.zoom_in, label: 'X 轴放大'),
            onTap: () => vm.zoomXIn(),
          ));
          items.add(PopupMenuItem(
            value: 'zoomYOut',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.vertical_align_bottom, label: 'Y 轴缩小'),
            onTap: () => vm.zoomYOut(),
          ));
          items.add(PopupMenuItem(
            value: 'zoomYIn',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.vertical_align_top, label: 'Y 轴放大'),
            onTap: () => vm.zoomYIn(),
          ));
        }

        // 文件组（如果未平铺）
        if (!visibleGroups.contains(_ToolbarGroup.file)) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('文件'));
          items.add(PopupMenuItem(
            value: 'importCsv',
            child: _buildMenuItem(icon: Icons.file_upload, label: '导入 CSV'),
            onTap: () => _importCsv(context, vm),
          ));
          items.add(PopupMenuItem(
            value: 'exportCsv',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.save, label: '导出 CSV'),
            onTap: () => _exportCsv(context, vm),
          ));
        }

        // 自适应组（如果未平铺）
        if (!visibleGroups.contains(_ToolbarGroup.fit)) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('自适应'));
          items.add(PopupMenuItem(
            value: 'fitY',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.vertical_align_center, label: 'Y轴自适应'),
            onTap: () => vm.fitYAxis(),
          ));
          items.add(PopupMenuItem(
            value: 'fitX',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.horizontal_rule, label: 'X轴自适应'),
            onTap: () => vm.fitXAxis(),
          ));
          items.add(PopupMenuItem(
            value: 'fitAll',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.fit_screen, label: '全自适应'),
            onTap: () => vm.fitAll(),
          ));
        }

        // 清空+设置组（如果未平铺）
        if (!visibleGroups.contains(_ToolbarGroup.clearSettings)) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('操作'));
          items.add(PopupMenuItem(
            value: 'clear',
            enabled: vm.dataPoints.isNotEmpty,
            child: _buildMenuItem(icon: Icons.clear, label: '清空数据'),
            onTap: () => vm.clearData(),
          ));
          items.add(PopupMenuItem(
            value: 'settings',
            child: _buildMenuItem(icon: Icons.tune, label: '高级设置'),
            onTap: () => _showAdvancedSettingsDialog(context, vm),
          ));
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

  /// 构建下拉菜单项（带图标和文字）
  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    bool active = false,
    Color? activeColor,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: active ? activeColor : null,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: active ? activeColor : null,
          ),
        ),
      ],
    );
  }

  // ========== 通道面板 ==========
  /// 构建左侧通道设置面板
  ///
  /// 只显示实际有数据的通道（[activeChannelCount]），包含：
  /// - 通道颜色指示器
  /// - 通道名称/别名
  /// - 绘图开关
  /// - 编辑按钮（修改颜色/别名/连线）
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
            child: Row(
              children: [
                const Text('通道', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const Spacer(),
                // 全选/全不选勾选框
                Tooltip(
                  message: vm.channels.every((ch) => ch.visible) ? '点击隐藏全部' : '点击显示全部',
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
                            final allVisible = vm.channels.every((ch) => ch.visible);
                            vm.setAllChannelsVisible(!allVisible);
                          },
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

    // 计算可见的偏移通道数量，同步到视口以动态调整右边距
    final offsetChannelCount = vm.channels.where((c) => c.visible && c.offsetEnabled).length;
    vm.viewport.setOffsetChannelCount(offsetChannelCount);

    return Stack(
      children: [
        PlotGestureHandler(
          viewport: vm.viewport,
          vCursorEnabled: vm.vCursorEnabled,
          boxZoomEnabled: vm.boxZoomEnabled,
          refreshFps: vm.refreshFps,
          channels: vm.channels,
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
          // 通道偏移拖动回调
          onChannelOffsetDrag: (index, yOffset) => vm.setChannelYOffset(index, yOffset),
          // 通道 Y 轴缩放回调（Shift+滚轮在偏置Y轴列上）
          onChannelYScaleZoom: (index, scaleDelta) => vm.zoomChannelYScale(index, scaleDelta),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV 导入成功')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $error')),
        );
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
/// 显示单个通道的颜色、名称/别名、绘图开关和编辑按钮。
class _ChannelItem extends StatelessWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelItem({super.key, required this.vm, required this.ch});

  /// 获取显示名称（别名优先，空则回退到 ChN）
  String get _displayName => ch.alias.isNotEmpty ? ch.alias : 'Ch${ch.index}';

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
          // 颜色指示器（点击打开编辑弹窗）
          InkWell(
            onTap: () => _showChannelEditDialog(context, vm, ch),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: ch.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 通道名/别名
          Expanded(
            child: Text(
              _displayName,
              style: TextStyle(
                fontSize: 10,
                color: ch.visible ? null : Colors.grey,
                decoration: ch.visible ? null : TextDecoration.lineThrough,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 绘图开关
          Tooltip(
            message: ch.visible ? '点击隐藏通道' : '点击显示通道',
            child: SizedBox(
              width: 22,
              child: Checkbox(
                value: ch.visible,
                onChanged: (value) => vm.setChannelVisible(ch.index, value!),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          // 编辑按钮
          Tooltip(
            message: '编辑通道',
            child: InkWell(
              onTap: () => _showChannelEditDialog(context, vm, ch),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.edit, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示通道编辑弹窗
  void _showChannelEditDialog(BuildContext context, PlotViewModel vm, ChannelConfig ch) {
    showDialog(
      context: context,
      builder: (context) => _ChannelEditDialog(vm: vm, ch: ch),
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
  late bool _offsetEnabled;
  late final TextEditingController _aliasController;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.ch.color;
    _alias = widget.ch.alias;
    _showLine = widget.ch.showLine;
    _offsetEnabled = widget.ch.offsetEnabled;
    _aliasController = TextEditingController(text: _alias);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text('编辑 Ch${widget.ch.index}'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 颜色选择
            const Text('颜色', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildColorPicker(),
            const SizedBox(height: 16),
            // 别名输入
            const Text('别名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _aliasController,
              maxLength: 16,
              decoration: const InputDecoration(
                hintText: '输入通道别名',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                counterText: '',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 连线开关
            Row(
              children: [
                const Text('连线显示', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const Spacer(),
                Switch(
                  value: _showLine,
                  onChanged: (value) => setState(() => _showLine = value),
                ),
              ],
            ),
            // 偏移开关
            Row(
              children: [
                const Text('偏移显示', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const Spacer(),
                Switch(
                  value: _offsetEnabled,
                  onChanged: (value) => setState(() => _offsetEnabled = value),
                ),
              ],
            ),
            if (_offsetEnabled) ...[
              const SizedBox(height: 4),
              Text(
                '提示：开启后可在绘图区拖动通道标签调整偏移位置',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ],
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
            widget.vm.setChannelAlias(widget.ch.index, _aliasController.text.trim());
            widget.vm.setChannelShowLine(widget.ch.index, _showLine);
            widget.vm.setChannelOffsetEnabled(widget.ch.index, _offsetEnabled);
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
      children: ChannelConfig.defaultColors.map((color) {
        final isSelected = color.value == _selectedColor.value;
        return InkWell(
          onTap: () => setState(() => _selectedColor = color),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: isSelected
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              boxShadow: isSelected
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)]
                  : null,
            ),
            child: isSelected
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

/// 工具栏分组枚举
///
/// 用于动态折叠计算，按优先级排序。
enum _ToolbarGroup {
  cursor,       // 光标与测量
  zoom,         // 缩放与框选
  file,         // 文件导入导出
  fit,          // 自适应
  clearSettings,// 清空与设置
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
