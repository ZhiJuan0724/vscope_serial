import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/constants/plot_configuration.dart';
import '../../core/utils/crc.dart';
import '../../core/utils/plot_value_formatter.dart';
import '../../core/utils/plot_performance_metrics.dart';
import '../../core/localization/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/channel_config.dart';
import '../../data/models/math_channel_config.dart';
import '../../data/models/plot_lod_index.dart';
import '../../data/models/plot_render_engine.dart';
import '../../data/models/plot_gesture_modifier.dart';
import '../../data/models/address_config_profile.dart';
import '../../data/models/parser_config.dart';
import '../../data/protocol/r_protocol_codec.dart';
import '../../services/app_settings.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../../viewmodels/settings_drafts.dart';
import '../dialogs/address_profile_dialog.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_draggable_info_box.dart';
import '../plot/plot_layer_stack.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_locator_bar.dart';
import '../plot/plot_viewport.dart';
import '../widgets/app_icon.dart';
import '../widgets/common_widgets.dart';
import '../widgets/plot_status_bar.dart';

part 'plot_page/plot_file_widgets.dart';
part 'plot_page/plot_channel_widgets.dart';
part 'plot_page/plot_parser_config_dialog.dart';
part 'plot_page/plot_overlay_widgets.dart';
part 'plot_page/plot_preset_selector_dialog.dart';

Future<Color?> showPlotCustomColorPicker(
  BuildContext context,
  Color initialColor,
) => _showChannelCustomColorPicker(context, initialColor);

/// 绘图页面入口
///
/// PlotViewModel 已提升为全局 Provider（在 main.dart 中注册），
/// 此处直接消费全局实例，确保页面切换后数据不丢失。
/// 绘图页面 Provider 入口；实际交互状态保存在 [_PlotPageContent]，以便页面切换时
/// 保留全局 [PlotViewModel] 中的运行会话和历史数据。
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
/// 绘图布局、悬浮层和菜单路由的局部状态容器。
class _PlotPageContent extends StatefulWidget {
  const _PlotPageContent();

  @override
  State<_PlotPageContent> createState() => _PlotPageContentState();
}

typedef _PlotToolbarSelection =
    ({
      bool isPlotting,
      bool isStarting,
      bool isStopping,
      bool hasData,
      ParserType parserType,
      bool useRandomSource,
      double randomFrequency,
      bool canUndoZoom,
      bool vCursorEnabled,
      bool triggerToolbarEnabled,
      bool triggerEnabled,
      bool observationPlacementActive,
      bool boxZoomEnabled,
      bool boxZoomContinuous,
      bool xMeasurementEnabled,
      bool yMeasurementEnabled,
      bool statsToolbarEnabled,
      bool statsEnabled,
      bool statsRangeEnabled,
      bool previewToolbarEnabled,
      bool followEnabled,
      bool showGrid,
      String gridDensity,
      SendProtocolType sendProtocolType,
      int profileRevision,
      String selectedZobowProfileId,
      String selectedRProfileId,
    });

typedef _PlotChannelPanelSelection =
    ({
      int channelConfigRevision,
      bool isPlotting,
      bool isStarting,
      bool isStopping,
      ParserType parserType,
      int activeChannelCount,
      int rawDisplayChannelCount,
      SendProtocolType effectiveSendProtocolType,
      int profileRevision,
      String selectedZobowProfileId,
      String selectedRProfileId,
    });

typedef _PlotAreaSelection =
    ({
      bool hasData,
      int dataRevision,
      int channelConfigRevision,
      int viewportRevision,
      int overlayRevision,
      bool boxZoomEnabled,
      String plotBackground,
      double floatingPanelOpacity,
      PlotLodQuality lodQuality,
      PlotRenderEngine renderEngine,
      bool interactionActive,
    });

int? _parseCompactCount(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([kKmM]?)$').firstMatch(text);
  if (match == null) return null;

  final value = double.tryParse(match.group(1)!);
  if (value == null) return null;
  final multiplier = switch (match.group(2)!.toUpperCase()) {
    'K' => 1000,
    'M' => 1000000,
    _ => 1,
  };
  return (value * multiplier).round();
}

String _formatCompactCount(int value) {
  if (value == 0) return '0';
  if (value % 1000000 == 0) return '${value ~/ 1000000}M';
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (value % 1000 == 0) return '${value ~/ 1000}K';
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}K';
  }
  return value.toString();
}

class _PlotPageContentState extends State<_PlotPageContent> {
  bool _measurementModifierPressed(PlotViewModel vm) =>
      vm.gestureModifier == PlotGestureModifier.shift
          ? HardwareKeyboard.instance.isShiftPressed
          : HardwareKeyboard.instance.isControlPressed;

  void _handleMeasurementButton(PlotViewModel vm, {required bool isX}) {
    if (_measurementModifierPressed(vm)) {
      isX ? vm.addXMeasurementGroup() : vm.addYMeasurementGroup();
      return;
    }
    isX ? vm.toggleXMeasurement() : vm.toggleYMeasurement();
  }

  /// 绘图首层工具栏较密集，下拉框边框需要比公共默认位置再低 1px。
  static const double _toolbarDropdownOffsetY = 2;

  /// 面板是否折叠
  bool _isPanelCollapsed = false;

  /// 面板宽度（展开时）
  double _panelWidth = PlotConfiguration.channelPanelDefaultWidth;

  /// 是否正在拖动调整宽度
  bool _isResizing = false;

  /// 是否显示悬浮图例
  bool _legendVisible = false;

  /// 是否显示最新通道值浮窗
  bool _liveValuesVisible = false;
  bool _previewVisible = false;

  OverlayEntry? _channelContextMenuEntry;
  Rect? _channelContextMenuRect;
  bool _channelContextMenuRouteAttached = false;
  Duration? _channelContextMenuHandledPointerTime;

  @override
  void dispose() {
    _hideChannelContextMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PlotPerformanceMetrics.instance.increment(PlotPerformanceMetric.pageBuild);
    return Column(
      children: [
        Selector<PlotViewModel, _PlotToolbarSelection>(
          selector: (_, vm) => _selectToolbar(vm),
          builder:
              (context, _, _) =>
                  _buildPrimaryToolbar(context, context.read<PlotViewModel>()),
        ),
        Selector<PlotViewModel, _PlotToolbarSelection>(
          selector: (_, vm) => _selectToolbar(vm),
          builder:
              (context, _, _) => _buildSecondaryToolbar(
                context,
                context.read<PlotViewModel>(),
              ),
        ),
        Expanded(
          child: Row(
            children: [
              Selector<PlotViewModel, _PlotChannelPanelSelection>(
                selector: (_, vm) => _selectChannelPanel(vm),
                builder:
                    (context, _, _) => _buildChannelPanelArea(
                      context,
                      context.read<PlotViewModel>(),
                    ),
              ),
              Expanded(
                child: Selector<PlotViewModel, _PlotAreaSelection>(
                  selector: (_, vm) => _selectPlotArea(vm),
                  builder:
                      (context, _, _) => _buildPlotArea(
                        context,
                        context.read<PlotViewModel>(),
                      ),
                ),
              ),
            ],
          ),
        ),
        const PlotStatusBar(),
      ],
    );
  }

  _PlotToolbarSelection _selectToolbar(PlotViewModel vm) {
    return (
      isPlotting: vm.isPlotting,
      isStarting: vm.isStarting,
      isStopping: vm.isStopping,
      hasData: vm.dataPoints.isNotEmpty,
      parserType: vm.parserType,
      useRandomSource: vm.useRandomSource,
      randomFrequency: vm.randomFrequency,
      canUndoZoom: vm.canUndoZoom,
      vCursorEnabled: vm.vCursorEnabled,
      triggerToolbarEnabled: vm.triggerToolbarEnabled,
      triggerEnabled: vm.triggerEnabled,
      observationPlacementActive: vm.observationPlacementActive,
      boxZoomEnabled: vm.boxZoomEnabled,
      boxZoomContinuous: vm.boxZoomContinuous,
      xMeasurementEnabled: vm.xMeasurementEnabled,
      yMeasurementEnabled: vm.yMeasurementEnabled,
      statsToolbarEnabled: vm.statsToolbarEnabled,
      statsEnabled: vm.statsEnabled,
      statsRangeEnabled: vm.statsRangeEnabled,
      previewToolbarEnabled: vm.previewToolbarEnabled,
      followEnabled: vm.followEnabled,
      showGrid: vm.showGrid,
      gridDensity: vm.gridDensity,
      sendProtocolType: vm.sendProtocolType,
      profileRevision: vm.profileRevision,
      selectedZobowProfileId: vm.selectedZobowProfileId,
      selectedRProfileId: vm.selectedRProfileId,
    );
  }

  _PlotChannelPanelSelection _selectChannelPanel(PlotViewModel vm) {
    return (
      channelConfigRevision: vm.channelConfigRevision,
      isPlotting: vm.isPlotting,
      isStarting: vm.isStarting,
      isStopping: vm.isStopping,
      parserType: vm.parserType,
      activeChannelCount: vm.activeChannelCount,
      rawDisplayChannelCount: vm.rawDisplayChannelCount,
      effectiveSendProtocolType: vm.effectiveSendProtocolType,
      profileRevision: vm.profileRevision,
      selectedZobowProfileId: vm.selectedZobowProfileId,
      selectedRProfileId: vm.selectedRProfileId,
    );
  }

  _PlotAreaSelection _selectPlotArea(PlotViewModel vm) {
    return (
      hasData: vm.dataPoints.isNotEmpty,
      dataRevision: vm.dataRevision,
      channelConfigRevision: vm.channelConfigRevision,
      viewportRevision: vm.viewportRevision,
      overlayRevision: vm.overlayRevision,
      boxZoomEnabled: vm.boxZoomEnabled,
      plotBackground: vm.plotBackground,
      floatingPanelOpacity: vm.floatingPanelOpacity,
      lodQuality: vm.lodQuality,
      renderEngine: vm.renderEngine,
      interactionActive: vm.plotInteractionActive,
    );
  }

  /// 构建通道面板区域（折叠状态或展开状态）
  Widget _buildChannelPanelArea(BuildContext context, PlotViewModel vm) {
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.channelPanelBuild,
    );
    if (_isPanelCollapsed) {
      return _buildCollapsedPanel(context);
    }
    return _buildExpandedPanel(context, vm);
  }

  /// 折叠后的窄条（32px）
  Widget _buildCollapsedPanel(BuildContext context) {
    return Container(
      width: PlotConfiguration.channelPanelCollapsedWidth,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          // 展开按钮（使用 InkWell 替代 IconButton，避免大圆阴影）
          Tooltip(
            message: AppStrings.plot.expandChannelPanel,
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
                  AppStrings.plot.channel,
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
    final minPanelWidth = _minimumChannelPanelWidth(vm);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 通道面板内容
        SizedBox(
          width: _panelWidth.clamp(
            minPanelWidth,
            PlotConfiguration.channelPanelMaxWidth,
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
                  minPanelWidth,
                  PlotConfiguration.channelPanelMaxWidth,
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

  double _minimumChannelPanelWidth(PlotViewModel vm) {
    if (vm.effectiveSendProtocolType == SendProtocolType.rProtocol) {
      return PlotConfiguration.channelPanelCompactWidth;
    }
    if (vm.parserType != ParserType.zobow) {
      return PlotConfiguration.channelPanelMinWidth;
    }
    final channelCount = vm.parserConfig.zobowChannelCount;
    final allShort = vm.parserConfig.zobowChannelIds
        .take(channelCount)
        .every((address) => (address & 0xFFFF0000) == 0);
    return allShort
        ? PlotConfiguration.channelPanelCompactWidth
        : PlotConfiguration.channelPanelMinWidth;
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
  List<Widget> _withToolbarSpacing(List<Widget> children) {
    return [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: kToolbarItemSpacing),
        children[i],
      ],
    ];
  }

  /// 构建第一栏工具栏
  ///
  /// 包含：开始/停止、数据源设置、解析器、文件、清空+设置
  Widget _buildPrimaryToolbar(BuildContext context, PlotViewModel vm) {
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.primaryToolbarBuild,
    );
    return UnifiedToolbar(
      leadingItems: [
        ToolbarLayoutItem(
          extent: 76,
          child: _buildStartStopButton(context, vm),
        ),
        if (vm.parserType == ParserType.fireWater)
          ToolbarLayoutItem(
            extent: 128,
            child: _buildRandomSourceToggle(context, vm),
            overflowActions: _randomSourceOverflowActions(context, vm),
          ),
        ToolbarLayoutItem(
          extent: _parserSelectorExtent(vm),
          child: _buildParserSelector(context, vm),
        ),
      ],
      trailingItems: [
        ToolbarLayoutItem(
          extent: 68,
          child: _buildFileTools(context, vm),
          overflowActions: _fileOverflowActions(context, vm),
        ),
        ToolbarLayoutItem(
          extent: 68,
          child: _buildClearAndSettings(context, vm),
          overflowActions: _clearSettingsOverflowActions(context, vm),
        ),
      ],
    );
  }

  /// 构建第二栏工具栏（光标+缩放）
  Widget _buildSecondaryToolbar(BuildContext context, PlotViewModel vm) {
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.secondaryToolbarBuild,
    );
    return UnifiedToolbar(
      leadingItems: [
        ToolbarLayoutItem(
          extent: _cursorToolsExtent(vm),
          child: _buildCursorTools(context, vm),
          overflowActions: _cursorOverflowActions(context, vm),
        ),
      ],
      trailingItems: [
        ToolbarLayoutItem(
          extent: 212,
          child: _buildZoomTools(context, vm),
          overflowActions: _zoomOverflowActions(vm),
        ),
        ToolbarLayoutItem(
          extent: 104,
          child: _buildFitTools(context, vm),
          overflowActions: _fitOverflowActions(vm),
        ),
      ],
    );
  }

  double _parserSelectorExtent(PlotViewModel vm) {
    final profileExtent =
        vm.parserType == ParserType.zobow ||
                vm.effectiveSendProtocolType == SendProtocolType.rProtocol
            ? 520.0
            : 304.0;
    // 触发按钮属于解析器工具组，启用入口后必须计入折叠宽度估算。
    return profileExtent +
        (vm.triggerToolbarEnabled || vm.triggerEnabled ? 76 : 0);
  }

  double _cursorToolsExtent(PlotViewModel vm) {
    // 文本按钮宽度受本地化字体度量影响，预留余量可确保折叠发生在实际溢出前。
    var extent = 560.0;
    if (vm.previewToolbarEnabled) extent += 72;
    if (vm.statsToolbarEnabled || vm.statsEnabled) extent += 108;
    return extent;
  }

  List<ToolbarOverflowAction> _randomSourceOverflowActions(
    BuildContext context,
    PlotViewModel vm,
  ) {
    final canChange = !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return [
      ToolbarOverflowAction(
        icon: const Icon(Icons.casino_outlined),
        label: AppStrings.plot.randomSource,
        selected: vm.useRandomSource,
        onPressed:
            canChange ? () => vm.setUseRandomSource(!vm.useRandomSource) : null,
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.speed),
        label: AppStrings.plot.randomSourceFrequencyTooltip(vm.randomFrequency),
        onPressed: () => _showRandomFreqDialog(context, vm),
      ),
    ];
  }

  List<ToolbarOverflowAction> _fileOverflowActions(
    BuildContext context,
    PlotViewModel vm,
  ) {
    final enabled = !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return [
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotImport),
        label: AppStrings.plot.importDataTooltip,
        onPressed: enabled ? () => _importPlotData(context, vm) : null,
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.save),
        label: AppStrings.plot.exportDataTooltip,
        onPressed:
            enabled && vm.dataPoints.isNotEmpty
                ? () => _exportPlotData(context, vm)
                : null,
      ),
    ];
  }

  List<ToolbarOverflowAction> _clearSettingsOverflowActions(
    BuildContext context,
    PlotViewModel vm,
  ) {
    return [
      ToolbarOverflowAction(
        icon: const Icon(Icons.clear),
        label: AppStrings.plot.clearData,
        onPressed: vm.dataPoints.isEmpty ? null : vm.clearData,
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.tune),
        label: AppStrings.plot.advancedSettings,
        onPressed: () => _showAdvancedSettingsDialog(context, vm),
      ),
    ];
  }

  List<ToolbarOverflowAction> _cursorOverflowActions(
    BuildContext context,
    PlotViewModel vm,
  ) {
    return [
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotCursor),
        label: AppStrings.plot.cursor,
        selected: vm.vCursorEnabled,
        onPressed: () => vm.setVCursorEnabled(!vm.vCursorEnabled),
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.add_location_alt),
        label: AppStrings.plot.observation,
        selected: vm.observationPlacementActive,
        onPressed:
            vm.dataPoints.isEmpty
                ? null
                : () {
                  if (vm.observationClickToPlace) {
                    vm.startObservationPlacement();
                  } else {
                    vm.addObservation();
                  }
                },
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotMeasureXx),
        label: AppStrings.plot.measureXx,
        selected: vm.xMeasurementEnabled,
        onPressed: () => _handleMeasurementButton(vm, isX: true),
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotMeasureYy),
        label: AppStrings.plot.measureYy,
        selected: vm.yMeasurementEnabled,
        onPressed: () => _handleMeasurementButton(vm, isX: false),
      ),
      if (vm.previewToolbarEnabled)
        ToolbarOverflowAction(
          icon: const Icon(Icons.preview),
          label: AppStrings.plot.preview,
          selected: _previewVisible,
          onPressed: () => setState(() => _previewVisible = !_previewVisible),
        ),
      if (vm.statsToolbarEnabled || vm.statsEnabled) ...[
        ToolbarOverflowAction(
          icon: const Icon(Icons.query_stats),
          label: AppStrings.plot.stats,
          selected: vm.statsEnabled,
          onPressed: vm.toggleStats,
        ),
        ToolbarOverflowAction(
          icon: const Icon(Icons.swap_horiz),
          label: AppStrings.plot.statsRangeTooltip,
          selected: vm.statsRangeEnabled,
          onPressed: vm.statsEnabled ? vm.toggleStatsRange : null,
        ),
      ],
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotFollow),
        label: AppStrings.plot.follow,
        selected: vm.followEnabled,
        onPressed: () => vm.setFollowEnabled(!vm.followEnabled),
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.list_alt),
        label: AppStrings.plot.legend,
        selected: _legendVisible,
        onPressed: () => setState(() => _legendVisible = !_legendVisible),
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.format_list_numbered),
        label: AppStrings.plot.liveValues,
        selected: _liveValuesVisible,
        onPressed:
            () => setState(() => _liveValuesVisible = !_liveValuesVisible),
      ),
    ];
  }

  List<ToolbarOverflowAction> _zoomOverflowActions(PlotViewModel vm) {
    final hasData = vm.dataPoints.isNotEmpty;
    return [
      ToolbarOverflowAction(
        icon: const Icon(Icons.undo),
        label: AppStrings.plot.undoZoom,
        onPressed: vm.canUndoZoom ? vm.undoZoom : null,
      ),
      ToolbarOverflowAction(
        icon: const Icon(Icons.crop_free),
        label: AppStrings.plot.boxZoom,
        selected: vm.boxZoomEnabled,
        onPressed: () => vm.setBoxZoomEnabled(!vm.boxZoomEnabled),
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotZoomXIn),
        label: AppStrings.plot.zoomXIn,
        onPressed: hasData ? vm.zoomXIn : null,
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotZoomXOut),
        label: AppStrings.plot.zoomXOut,
        onPressed: hasData ? vm.zoomXOut : null,
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotZoomYIn),
        label: AppStrings.plot.zoomYIn,
        onPressed: hasData ? vm.zoomYIn : null,
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotZoomYOut),
        label: AppStrings.plot.zoomYOut,
        onPressed: hasData ? vm.zoomYOut : null,
      ),
    ];
  }

  List<ToolbarOverflowAction> _fitOverflowActions(PlotViewModel vm) {
    final hasData = vm.dataPoints.isNotEmpty;
    return [
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotFitY),
        label: AppStrings.plot.fitYTooltip,
        onPressed: hasData ? vm.fitYAxis : null,
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotFitX),
        label: AppStrings.plot.fitXTooltip,
        onPressed: hasData ? vm.fitXAxis : null,
      ),
      ToolbarOverflowAction(
        icon: const AppIcon(AppIcons.plotFitAll),
        label: AppStrings.plot.fitAll,
        onPressed: hasData ? vm.fitAll : null,
      ),
    ];
  }

  Widget _buildStartStopButton(BuildContext context, PlotViewModel vm) {
    return ToolbarStartStopButton(
      key: const ValueKey('plot-start-stop-button'),
      onPressed:
          vm.isStarting || vm.isStopping
              ? null
              : () {
                if (vm.isPlotting) {
                  vm.stopPlotting();
                } else {
                  unawaited(vm.startPlotting());
                }
              },
      running: vm.isPlotting,
      busy: vm.isStarting || vm.isStopping,
      label:
          vm.isStarting
              ? AppStrings.plot.starting
              : vm.isStopping
              ? AppStrings.plot.stopping
              : vm.isPlotting
              ? AppStrings.plot.stop
              : AppStrings.plot.start,
    );
  }

  /// 随机数据源 + 频率设置
  Widget _buildRandomSourceToggle(BuildContext context, PlotViewModel vm) {
    final canChangeSource = !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        ToolbarToggleTextButton(
          key: const ValueKey('plot-random-source-checkbox'),
          icon: const Icon(Icons.casino_outlined),
          label: AppStrings.plot.randomSource,
          tooltip: AppStrings.plot.randomSource,
          selected: vm.useRandomSource,
          activeColor: Colors.green,
          onPressed:
              canChangeSource
                  ? () => vm.setUseRandomSource(!vm.useRandomSource)
                  : null,
        ),
        ToolbarIconButton(
          key: const ValueKey('plot-random-frequency-button'),
          icon: const Icon(Icons.settings),
          tooltip: AppStrings.plot.randomSourceFrequencyTooltip(
            vm.randomFrequency,
          ),
          onPressed: () => _showRandomFreqDialog(context, vm),
        ),
      ]),
    );
  }

  /// 收发协议选择 + 配置按钮 + 地址配置文件选择
  Widget _buildParserSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration =
        !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToolbarDropdown<ParserType>(
          key: const ValueKey('plot-parser-selector'),
          width: 120,
          visibleFieldOffsetY: _toolbarDropdownOffsetY,
          value: vm.parserType,
          hint: AppStrings.plot.receiveProtocolHint,
          items:
              ParserType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(
                    type.label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'SarasaUiSC',
                    ),
                  ),
                );
              }).toList(),
          onChanged:
              canChangeConfiguration
                  ? (value) {
                    if (value != null) vm.setParserType(value);
                  }
                  : null,
        ),
        const SizedBox(width: kToolbarItemSpacing),
        ToolbarIconButton(
          key: const ValueKey('plot-parser-config-button'),
          icon: const Icon(Icons.settings),
          tooltip: AppStrings.plot.parserConfig,
          onPressed:
              canChangeConfiguration
                  ? () => _showParserConfigDialog(context, vm)
                  : null,
        ),
        const SizedBox(width: kToolbarItemSpacing),
        ToolbarDropdown<SendProtocolType>(
          key: const ValueKey('plot-send-protocol-selector'),
          width: 112,
          visibleFieldOffsetY: _toolbarDropdownOffsetY,
          value:
              vm.parserType == ParserType.zobow
                  ? vm.effectiveSendProtocolType
                  : vm.sendProtocolType,
          hint: AppStrings.plot.sendProtocolHint,
          items:
              (vm.parserType == ParserType.zobow
                      ? const [SendProtocolType.zobowBuiltIn]
                      : const [
                        SendProtocolType.none,
                        SendProtocolType.rProtocol,
                      ])
                  .map(
                    (type) => DropdownMenuItem(
                      value: type,
                      child: Text(
                        type.label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'SarasaUiSC',
                        ),
                      ),
                    ),
                  )
                  .toList(),
          onChanged:
              !canChangeConfiguration || vm.parserType == ParserType.zobow
                  ? null
                  : (value) {
                    if (value != null) vm.setSendProtocolType(value);
                  },
        ),
        ToolbarIconButton(
          key: const ValueKey('send-protocol-config-button'),
          icon: const Icon(Icons.settings),
          tooltip: AppStrings.plot.sendProtocolConfig,
          onPressed:
              canChangeConfiguration &&
                      vm.effectiveSendProtocolType == SendProtocolType.rProtocol
                  ? () => _showSendProtocolConfigDialog(context, vm)
                  : null,
        ),
        // Zobow模式下显示配置文件下拉框
        if (vm.parserType == ParserType.zobow) ...[
          const SizedBox(width: kToolbarItemSpacing),
          _buildZobowProfileSelector(context, vm),
          // 新建配置按钮
          ToolbarIconButton(
            key: const ValueKey('plot-create-zobow-profile-button'),
            icon: const Icon(Icons.add),
            tooltip: AppStrings.plot.createConfig,
            onPressed:
                canChangeConfiguration
                    ? () => _showCreateZobowProfileDialog(context, vm)
                    : null,
          ),
          // 编辑配置按钮
          ToolbarIconButton(
            key: const ValueKey('plot-edit-zobow-profile-button'),
            icon: const Icon(Icons.edit),
            tooltip: AppStrings.plot.editConfig,
            onPressed:
                canChangeConfiguration
                    ? () => _showEditZobowProfileDialog(context, vm)
                    : null,
          ),
        ] else if (vm.sendProtocolType == SendProtocolType.rProtocol) ...[
          const SizedBox(width: kToolbarItemSpacing),
          _buildRProfileSelector(context, vm),
          ToolbarIconButton(
            key: const ValueKey('plot-create-r-profile-button'),
            icon: const Icon(Icons.add),
            tooltip: AppStrings.plot.createRProtocolConfig,
            onPressed:
                canChangeConfiguration
                    ? () => _showCreateRProfileDialog(context, vm)
                    : null,
          ),
          ToolbarIconButton(
            key: const ValueKey('plot-edit-r-profile-button'),
            icon: const Icon(Icons.edit),
            tooltip: AppStrings.plot.editRProtocolConfig,
            onPressed:
                canChangeConfiguration
                    ? () => _showEditRProfileDialog(context, vm)
                    : null,
          ),
        ],
        if (vm.triggerToolbarEnabled || vm.triggerEnabled) ...[
          const SizedBox(width: kToolbarItemSpacing),
          _buildTriggerButton(context, vm),
        ],
      ],
    );
  }

  Widget _buildRProfileSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration =
        !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return ToolbarDropdown<String?>(
      key: const ValueKey('plot-r-profile-selector'),
      width: 140,
      visibleFieldOffsetY: _toolbarDropdownOffsetY,
      value: vm.selectedRProfileId.isEmpty ? null : vm.selectedRProfileId,
      hint: AppStrings.plot.noConfig,
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text(
            AppStrings.plot.noConfig,
            style: const TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
          ),
        ),
        ...vm.rProfiles.map(
          (profile) => DropdownMenuItem(
            value: profile.id,
            child: Text(
              profile.name,
              style: const TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
            ),
          ),
        ),
      ],
      onChanged: canChangeConfiguration ? vm.selectRProfile : null,
    );
  }

  Widget _buildTriggerButton(BuildContext context, PlotViewModel vm) {
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          _showTriggerConfigDialog(context, vm);
        }
      },
      child: ToolbarToggleTextButton(
        icon: const Icon(Icons.online_prediction),
        label: AppStrings.plot.trigger,
        tooltip: AppStrings.plot.triggerTooltip,
        selected: vm.triggerEnabled,
        activeColor: Colors.green,
        onPressed: () => vm.setTriggerEnabled(!vm.triggerEnabled),
      ),
    );
  }

  /// Zobow配置文件选择器
  Widget _buildZobowProfileSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration =
        !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return ToolbarDropdown<String?>(
      key: const ValueKey('plot-zobow-profile-selector'),
      width: 140,
      visibleFieldOffsetY: _toolbarDropdownOffsetY,
      value:
          vm.selectedZobowProfileId.isEmpty ? null : vm.selectedZobowProfileId,
      hint: AppStrings.plot.noConfig,
      items: [
        // "不使用"选项
        DropdownMenuItem<String?>(
          value: null,
          child: Text(
            AppStrings.plot.noConfig,
            style: const TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
          ),
        ),
        // 所有配置文件
        ...vm.zobowProfiles.map((profile) {
          return DropdownMenuItem(
            value: profile.id,
            child: Text(
              profile.name,
              style: const TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
            ),
          );
        }),
      ],
      onChanged:
          canChangeConfiguration
              ? (value) {
                if (value == null) {
                  vm.selectZobowProfile(null);
                } else {
                  vm.selectZobowProfile(value);
                }
              }
              : null,
    );
  }

  /// 光标和测量工具组
  ///
  /// 顺序：垂直光标 | X-X | Y-Y | 跟随
  Widget _buildCursorTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        Listener(
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton && vm.pointCount > 0) {
              _showCursorJumpDialog(context, vm);
            }
          },
          child: ToolbarToggleTextButton(
            icon: const AppIcon(AppIcons.plotCursor),
            label: AppStrings.plot.cursor,
            tooltip: AppStrings.plot.verticalCursor,
            selected: vm.vCursorEnabled,
            activeColor: Colors.orange,
            onPressed: () => vm.setVCursorEnabled(!vm.vCursorEnabled),
          ),
        ),
        Listener(
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton) {
              _showObservationManagerDialog(context, vm);
            }
          },
          child: ToolbarToggleTextButton(
            icon: const Icon(Icons.add_location_alt),
            label: AppStrings.plot.observation,
            tooltip:
                vm.observationPlacementActive
                    ? AppStrings.plot.placeObservation
                    : AppStrings.plot.addObservation,
            selected: vm.observationPlacementActive,
            activeColor: Colors.amber,
            onPressed: () {
              if (vm.dataPoints.isEmpty) return;
              if (vm.observationClickToPlace) {
                vm.startObservationPlacement();
              } else {
                vm.addObservation();
              }
            },
          ),
        ),
        Listener(
          key: const ValueKey('plot-measure-x-button'),
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton) {
              _showMeasurementSettingsDialog(context, vm, isX: true);
            }
          },
          child: ToolbarToggleTextButton(
            icon: const AppIcon(AppIcons.plotMeasureXx),
            label: AppStrings.plot.measureXx,
            tooltip: AppStrings.plot.measureXxTooltip,
            selected: vm.xMeasurementEnabled,
            activeColor: Colors.blue,
            onPressed: () => _handleMeasurementButton(vm, isX: true),
          ),
        ),
        Listener(
          key: const ValueKey('plot-measure-y-button'),
          onPointerDown: (event) {
            if (event.buttons == kSecondaryMouseButton) {
              _showMeasurementSettingsDialog(context, vm, isX: false);
            }
          },
          child: ToolbarToggleTextButton(
            icon: const AppIcon(AppIcons.plotMeasureYy),
            label: AppStrings.plot.measureYy,
            tooltip: AppStrings.plot.measureYyTooltip,
            selected: vm.yMeasurementEnabled,
            activeColor: Colors.blue,
            onPressed: () => _handleMeasurementButton(vm, isX: false),
          ),
        ),
        if (vm.previewToolbarEnabled)
          ToolbarToggleTextButton(
            icon: const Icon(Icons.preview),
            label: AppStrings.plot.preview,
            tooltip: AppStrings.plot.previewTooltip,
            selected: _previewVisible,
            activeColor: Colors.teal,
            onPressed: () => setState(() => _previewVisible = !_previewVisible),
          ),
        if (vm.statsToolbarEnabled || vm.statsEnabled) ...[
          ToolbarToggleTextButton(
            icon: const Icon(Icons.query_stats),
            label: AppStrings.plot.stats,
            tooltip: AppStrings.plot.statsTooltip,
            selected: vm.statsEnabled,
            activeColor: Colors.blue,
            onPressed: vm.toggleStats,
          ),
          ToolbarToggleIconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: AppStrings.plot.statsRangeTooltip,
            selected: vm.statsRangeEnabled,
            activeColor: Colors.blue,
            onPressed: vm.statsEnabled ? vm.toggleStatsRange : null,
          ),
        ],
        ToolbarToggleTextButton(
          icon: const AppIcon(AppIcons.plotFollow),
          label: AppStrings.plot.follow,
          tooltip: AppStrings.plot.followTooltip,
          selected: vm.followEnabled,
          activeColor: Colors.orange,
          onPressed: () => vm.setFollowEnabled(!vm.followEnabled),
        ),
        ToolbarToggleTextButton(
          icon: const Icon(Icons.list_alt),
          label: AppStrings.plot.legend,
          tooltip: AppStrings.plot.legend,
          selected: _legendVisible,
          activeColor: Colors.teal,
          onPressed: () => setState(() => _legendVisible = !_legendVisible),
        ),
        ToolbarToggleTextButton(
          icon: const Icon(Icons.format_list_numbered),
          label: AppStrings.plot.liveValues,
          tooltip: AppStrings.plot.liveValues,
          selected: _liveValuesVisible,
          activeColor: Colors.lightBlue,
          onPressed:
              () => setState(() => _liveValuesVisible = !_liveValuesVisible),
        ),
      ]),
    );
  }

  /// 缩放和框选工具组
  ///
  /// 顺序：撤回缩放 | 框选 | X放 | X缩 | Y放 | Y缩
  Widget _buildZoomTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        ToolbarIconButton(
          icon: const Icon(Icons.undo),
          tooltip: AppStrings.plot.undoZoom,
          onPressed: vm.canUndoZoom ? vm.undoZoom : null,
        ),
        ToolbarToggleIconButton(
          icon: const Icon(Icons.crop_free),
          tooltip: '${AppStrings.plot.boxZoom}（左键单次，右键连续）',
          selected: vm.boxZoomEnabled,
          activeColor: vm.boxZoomContinuous ? Colors.orange : Colors.blue,
          onPressed: () => vm.setBoxZoomEnabled(!vm.boxZoomEnabled),
          onSecondaryPressed:
              () => vm.setBoxZoomEnabled(
                !(vm.boxZoomEnabled && vm.boxZoomContinuous),
                continuous: true,
              ),
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotZoomXIn),
          tooltip: AppStrings.plot.zoomXIn,
          onPressed: vm.dataPoints.isEmpty ? null : vm.zoomXIn,
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotZoomXOut),
          tooltip: AppStrings.plot.zoomXOut,
          onPressed: vm.dataPoints.isEmpty ? null : vm.zoomXOut,
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotZoomYIn),
          tooltip: AppStrings.plot.zoomYIn,
          onPressed: vm.dataPoints.isEmpty ? null : vm.zoomYIn,
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotZoomYOut),
          tooltip: AppStrings.plot.zoomYOut,
          onPressed: vm.dataPoints.isEmpty ? null : vm.zoomYOut,
        ),
      ]),
    );
  }

  /// 文件工具组
  ///
  /// 顺序：导入数据 | 导出数据
  Widget _buildFileTools(BuildContext context, PlotViewModel vm) {
    final fileOperationsEnabled =
        !vm.isPlotting && !vm.isStarting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        ToolbarIconButton(
          key: const ValueKey('plot-import-data-button'),
          icon: const AppIcon(AppIcons.plotImport),
          tooltip: AppStrings.plot.importDataTooltip,
          onPressed:
              fileOperationsEnabled ? () => _importPlotData(context, vm) : null,
        ),
        ToolbarIconButton(
          key: const ValueKey('plot-export-data-button'),
          icon: const Icon(Icons.save),
          tooltip: AppStrings.plot.exportDataTooltip,
          onPressed:
              !fileOperationsEnabled || vm.dataPoints.isEmpty
                  ? null
                  : () => _exportPlotData(context, vm),
        ),
      ]),
    );
  }

  /// 自适应工具组
  ///
  /// 顺序：Y自适应 | X自适应 | 全自适应
  Widget _buildFitTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotFitY),
          tooltip: AppStrings.plot.fitYTooltip,
          onPressed: vm.dataPoints.isEmpty ? null : vm.fitYAxis,
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotFitX),
          tooltip: AppStrings.plot.fitXTooltip,
          onPressed: vm.dataPoints.isEmpty ? null : vm.fitXAxis,
        ),
        ToolbarIconButton(
          icon: const AppIcon(AppIcons.plotFitAll),
          tooltip: AppStrings.plot.fitAll,
          onPressed: vm.dataPoints.isEmpty ? null : vm.fitAll,
        ),
      ]),
    );
  }

  /// 清空 + 高级设置
  Widget _buildClearAndSettings(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        ToolbarIconButton(
          icon: const Icon(Icons.clear),
          tooltip: AppStrings.plot.clearData,
          onPressed: vm.dataPoints.isEmpty ? null : vm.clearData,
        ),
        ToolbarAdvancedSettingsButton(
          onPressed: () => _showAdvancedSettingsDialog(context, vm),
          tooltip: AppStrings.plot.advancedSettings,
        ),
      ]),
    );
  }

  /// 通道面板内容（展开状态）
  Widget _buildChannelPanelContent(BuildContext context, PlotViewModel vm) {
    // 只显示实际有数据的通道
    final rawDisplayCount = vm.rawDisplayChannelCount;
    final enabledMathChannels = vm.enabledMathChannels;
    final displayCount = rawDisplayCount + enabledMathChannels.length;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.only(
              left: PlotConfiguration.channelPanelHorizontalPadding,
              right:
                  PlotConfiguration.channelPanelHorizontalPadding +
                  PlotConfiguration.channelPanelListRightPadding,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Tooltip(
                  message: AppStrings.plot.collapseChannelPanel,
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
                Text(
                  AppStrings.plot.channel,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const Spacer(),
                Tooltip(
                  message: AppStrings.plot.offsetToggle,
                  child: SizedBox(
                    width: 20,
                    child: Center(
                      child: Text(
                        AppStrings.plot.offset,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                // 全显/全隐按钮
                _ChannelVisibilityButton(
                  visible: vm.displayChannels.any((ch) => ch.visible),
                  tooltip:
                      vm.displayChannels.any((ch) => ch.visible)
                          ? AppStrings.plot.hideAllChannels
                          : AppStrings.plot.showAllChannels,
                  onToggle: () {
                    // 只要还有任一通道显示，点击表头就隐藏全部；全部隐藏时再点击才显示全部。
                    final anyVisible = vm.displayChannels.any(
                      (ch) => ch.visible,
                    );
                    vm.setAllChannelsVisible(!anyVisible);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (event.kind != PointerDeviceKind.mouse) return;
                if (event.buttons == kPrimaryMouseButton) {
                  _hideChannelContextMenu();
                } else if (event.buttons == kSecondaryMouseButton) {
                  _showBlankChannelContextMenu(
                    context,
                    vm,
                    event.position,
                    event.timeStamp,
                  );
                }
              },
              child: ListView.builder(
                padding: const EdgeInsets.only(
                  right: PlotConfiguration.channelPanelListRightPadding,
                ),
                itemCount: displayCount + 1,
                itemBuilder: (context, index) {
                  if (index == displayCount) {
                    return const SizedBox(height: 88);
                  }
                  if (index >= rawDisplayCount) {
                    final mathChannel =
                        enabledMathChannels[index - rawDisplayCount];
                    return Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        if (event.kind == PointerDeviceKind.mouse &&
                            event.buttons == kSecondaryMouseButton) {
                          _channelContextMenuHandledPointerTime =
                              event.timeStamp;
                          _showChannelContextMenu(
                            context,
                            vm,
                            event.position,
                            target: _ChannelContextMenuTarget.math(mathChannel),
                          );
                        }
                      },
                      child: _MathChannelItem(
                        key: ValueKey('math_${mathChannel.index}'),
                        vm: vm,
                        channel: mathChannel,
                      ),
                    );
                  }
                  final ch = vm.channels[index];
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      if (event.kind == PointerDeviceKind.mouse &&
                          event.buttons == kSecondaryMouseButton) {
                        _channelContextMenuHandledPointerTime = event.timeStamp;
                        _showChannelContextMenu(
                          context,
                          vm,
                          event.position,
                          target: _ChannelContextMenuTarget.raw(ch),
                        );
                      }
                    },
                    child: _ChannelItem(
                      key: ValueKey('ch_${ch.index}'),
                      vm: vm,
                      ch: ch,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showChannelContextMenu(
    BuildContext context,
    PlotViewModel vm,
    Offset position, {
    _ChannelContextMenuTarget target = const _ChannelContextMenuTarget.blank(),
  }) {
    _hideChannelContextMenu();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final menuContext = context;
    final capturedThemes = InheritedTheme.capture(
      from: context,
      to: overlay.context,
    );

    const menuWidth = 188.0;
    final itemCount = switch (target.kind) {
      _ChannelContextMenuTargetKind.blank => 2,
      _ChannelContextMenuTargetKind.raw =>
        target.channel?.offsetEnabled == true ? 2 : 1,
      _ChannelContextMenuTargetKind.math =>
        target.channel?.offsetEnabled == true ? 3 : 2,
    };
    final menuHeight = 34.0 + itemCount * 40.0;
    final screenSize = MediaQuery.sizeOf(context);
    final maxLeft = math.max(8.0, screenSize.width - menuWidth - 8.0);
    final maxTop = math.max(8.0, screenSize.height - menuHeight - 8.0);
    final left = position.dx.clamp(8.0, maxLeft);
    final top = position.dy.clamp(8.0, maxTop);
    _channelContextMenuRect = Rect.fromLTWH(left, top, menuWidth, menuHeight);
    _attachChannelContextMenuGlobalRoute();

    _channelContextMenuEntry = OverlayEntry(
      builder:
          (context) => capturedThemes.wrap(
            Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: menuWidth,
                  child: _ChannelContextMenu(
                    target: target,
                    onAddMathChannel:
                        target.kind == _ChannelContextMenuTargetKind.blank
                            ? () {
                              _hideChannelContextMenu();
                              _addMathChannelFromContextMenu(menuContext, vm);
                            }
                            : null,
                    onResetAllChannels:
                        target.kind == _ChannelContextMenuTargetKind.blank &&
                                !vm.isPlotting &&
                                !vm.isStopping
                            ? () {
                              _hideChannelContextMenu();
                              _confirmResetAllChannels(menuContext, vm);
                            }
                            : null,
                    onEditChannel:
                        target.kind == _ChannelContextMenuTargetKind.raw
                            ? () {
                              _hideChannelContextMenu();
                              _showChannelEditDialog(
                                menuContext,
                                vm,
                                target.rawChannel!,
                              );
                            }
                            : target.kind == _ChannelContextMenuTargetKind.math
                            ? () {
                              _hideChannelContextMenu();
                              _showMathChannelDialog(
                                menuContext,
                                vm,
                                target.mathChannel!,
                              );
                            }
                            : null,
                    onOffsetBinding:
                        target.channel?.offsetEnabled == true
                            ? () {
                              _hideChannelContextMenu();
                              _showOffsetBindingDialog(
                                menuContext,
                                vm,
                                target.channel!.index,
                              );
                            }
                            : null,
                    onDeleteMathChannel:
                        target.mathChannel == null
                            ? null
                            : () {
                              _hideChannelContextMenu();
                              vm.disableMathChannel(target.mathChannel!.index);
                            },
                  ),
                ),
              ],
            ),
          ),
    );
    overlay.insert(_channelContextMenuEntry!);
  }

  void _showBlankChannelContextMenu(
    BuildContext context,
    PlotViewModel vm,
    Offset position,
    Duration pointerTime,
  ) {
    Future.microtask(() {
      if (!mounted || !context.mounted) {
        return;
      }
      if (_channelContextMenuHandledPointerTime == pointerTime) return;
      _showChannelContextMenu(context, vm, position);
    });
  }

  void _hideChannelContextMenu() {
    final entry = _channelContextMenuEntry;
    _channelContextMenuEntry = null;
    _channelContextMenuRect = null;
    _detachChannelContextMenuGlobalRoute();
    if (entry == null) return;
    entry
      ..remove()
      ..dispose();
  }

  void _attachChannelContextMenuGlobalRoute() {
    if (_channelContextMenuRouteAttached) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleChannelContextMenuPointerEvent,
    );
    _channelContextMenuRouteAttached = true;
  }

  void _detachChannelContextMenuGlobalRoute() {
    if (!_channelContextMenuRouteAttached) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleChannelContextMenuPointerEvent,
    );
    _channelContextMenuRouteAttached = false;
  }

  void _handleChannelContextMenuPointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final rect = _channelContextMenuRect;
    if (rect != null && rect.contains(event.position)) return;
    final entry = _channelContextMenuEntry;
    Future.microtask(() {
      if (!mounted || _channelContextMenuEntry != entry) return;
      _hideChannelContextMenu();
    });
  }

  void _addMathChannelFromContextMenu(BuildContext context, PlotViewModel vm) {
    final channel = vm.firstAvailableMathChannel();
    if (channel == null) {
      vm.showStatusMessage(AppStrings.plot.noAvailableMathChannel);
      return;
    }
    _showMathChannelDialog(context, vm, channel);
  }

  Future<void> _confirmResetAllChannels(
    BuildContext context,
    PlotViewModel vm,
  ) async {
    if (vm.isPlotting || vm.isStarting || vm.isStopping) {
      vm.showStatusMessage(AppStrings.plot.resetAllChannelsStoppedOnly);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(AppStrings.plot.resetAllChannelsTitle),
            content: SizedBox(
              width: kAdvancedSettingsDialogWidth,
              child: Text(AppStrings.plot.resetAllChannelsMessage),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppStrings.common.confirm),
              ),
            ],
          ),
    );
    if (confirmed == true) {
      vm.resetAllChannels();
    }
  }

  void _showChannelEditDialog(
    BuildContext context,
    PlotViewModel vm,
    ChannelConfig channel,
  ) {
    showDialog(
      context: context,
      builder: (context) => _ChannelEditDialog(vm: vm, ch: channel),
    );
  }

  void _showOffsetBindingDialog(
    BuildContext context,
    PlotViewModel vm,
    int channelIndex,
  ) {
    showDialog(
      context: context,
      builder:
          (context) => _OffsetBindingDialog(vm: vm, channelIndex: channelIndex),
    );
  }

  // ========== 绘图区域 ==========
  /// 构建右侧绘图区域
  ///
  /// 无数据时显示提示，有数据时显示：
  /// - [PlotGestureHandler]：处理手势交互
  /// - [PlotLayerPainter]：分层绘制波形
  /// - 测量/统计信息框（可拖动）
  Widget _buildPlotArea(BuildContext context, PlotViewModel vm) {
    // 绘图区只订阅渲染快照相关 revision，工具栏和通道面板不随高频数据重建。
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.plotAreaBuild,
    );
    if (vm.dataPoints.isEmpty) {
      return ColoredBox(
        key: const ValueKey('plot-empty-background'),
        color: AppTheme.pageBackgroundColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.show_chart, size: 48, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.plot.noData,
                    style: const TextStyle(color: Colors.grey),
                  ),
                  Text(
                    AppStrings.plot.startPlotHint,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_liveValuesVisible) _buildLiveValuesBox(vm),
          ],
        ),
      );
    }

    // 计算可见的偏移通道数量，同步到视口以动态调整右边距
    final displayChannels = vm.displayChannels;
    final displayDataPoints = vm.displayDataPoints;
    final activeChannelCount = vm.displayActiveChannelCount;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridDensity = _parseGridDensity(vm.gridDensity);
        final plotBackground = _parsePlotBackground(vm.plotBackground);
        final leftAxisWidth = PlotLayerPainter.calculateLeftAxisWidth(
          viewport: vm.viewport,
          canvasHeight: constraints.maxHeight,
          gridDensity: gridDensity,
          plotFontSizeDelta: vm.plotFontSizeDelta.toDouble(),
          plotFontBold: vm.plotFontBold,
        );
        final offsetAxisColumnWidths =
            PlotLayerPainter.calculateOffsetAxisColumnWidths(
              viewport: vm.viewport,
              channels: displayChannels,
              activeChannelCount: activeChannelCount,
              canvasHeight: constraints.maxHeight,
              gridDensity: gridDensity,
              plotFontSizeDelta: vm.plotFontSizeDelta.toDouble(),
              plotFontBold: vm.plotFontBold,
              yValuesAreInteger: vm.displayYValuesAreInteger,
            );
        final renderViewport = vm.viewport.copyWith(marginLeft: leftAxisWidth)
          ..setOffsetAxisColumnWidths(offsetAxisColumnWidths);

        final renderSnapshot = PlotRenderSnapshot(
          viewport: renderViewport,
          data: displayDataPoints,
          dataRevision: vm.dataRevision,
          channelConfigRevision: vm.channelConfigRevision,
          viewportRevision: vm.viewportRevision,
          overlayRevision: vm.overlayRevision,
          lodIndex: vm.lodIndex,
          lodQuality: vm.lodQuality,
          renderEngine: vm.renderEngine,
          interactionActive: vm.plotInteractionActive,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          channels: displayChannels,
          activeChannelCount: activeChannelCount,
          showGrid: vm.showGrid,
          gridDensity: gridDensity,
          backgroundStyle: plotBackground,
          floatingPanelOpacity: vm.floatingPanelOpacity,
          cursor: vm.cursor,
          xCursor1: vm.xCursor1,
          xCursor2: vm.xCursor2,
          yCursor1: vm.yCursor1,
          yCursor2: vm.yCursor2,
          xMeasurementGroups: vm.xMeasurementGroups,
          yMeasurementGroups: vm.yMeasurementGroups,
          xMeasurementLine1Color: vm.xMeasurementLine1Color,
          xMeasurementLine2Color: vm.xMeasurementLine2Color,
          yMeasurementLine1Color: vm.yMeasurementLine1Color,
          yMeasurementLine2Color: vm.yMeasurementLine2Color,
          xMeasurementLine1Opacity: vm.xMeasurementLine1Opacity,
          xMeasurementLine2Opacity: vm.xMeasurementLine2Opacity,
          yMeasurementLine1Opacity: vm.yMeasurementLine1Opacity,
          yMeasurementLine2Opacity: vm.yMeasurementLine2Opacity,
          statsEnabled: vm.statsEnabled,
          statsRangeEnabled: vm.statsRangeEnabled,
          statsX1: vm.statsX1,
          statsX2: vm.statsX2,
          snapHighlights: vm.snapHighlights,
          snapHighlightEnabled: vm.snapHighlightEnabled,
          snapHighlightDiameter: vm.snapHighlightDiameter,
          antiAliasEnabled: vm.antiAliasEnabled,
          yValuesAreInteger: vm.displayYValuesAreInteger,
          plotFontSizeDelta: vm.plotFontSizeDelta,
          plotFontBold: vm.plotFontBold,
        );

        final previewPanelHeight =
            _previewVisible && vm.previewToolbarEnabled
                ? PlotConfiguration.locatorBarHeight
                : 0.0;
        return Stack(
          children: [
            Positioned.fill(
              bottom: previewPanelHeight,
              child: Stack(
                children: [
                  PlotGestureHandler(
                    viewport: renderViewport,
                    vCursorEnabled: vm.vCursorEnabled,
                    boxZoomEnabled: vm.boxZoomEnabled,
                    onBoxZoomCompleted: () {
                      if (!vm.boxZoomContinuous) {
                        vm.setBoxZoomEnabled(false);
                      }
                    },
                    refreshFps: vm.effectiveRefreshFps,
                    plotFontSizeDelta: vm.plotFontSizeDelta,
                    gestureModifier: vm.gestureModifier,
                    channels: displayChannels,
                    activeChannelCount: activeChannelCount,
                    data: displayDataPoints,
                    observations: vm.observations,
                    onObservationDrag:
                        (index, x) => vm.updateObservation(index, x),
                    onObservationDelete: (index) => vm.removeObservation(index),
                    observationPlacementActive: vm.observationPlacementActive,
                    onObservationPlacementHover: vm.updateObservationPlacement,
                    onObservationPlacementCommit: vm.commitObservationPlacement,
                    onViewportChanged:
                        (viewport, {fromDrag = false}) =>
                            vm.updateViewport(viewport, fromDrag: fromDrag),
                    onDragEnd: vm.saveDragViewport,
                    onInteractionChanged: vm.setPlotInteractionActive,
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
                    xMeasurementGroups: vm.xMeasurementGroups,
                    yMeasurementGroups: vm.yMeasurementGroups,
                    yMeasurementSnapEnabled: vm.yMeasurementSnapEnabled,
                    onXMeasurementDrag:
                        vm.xMeasurementEnabled
                            ? vm.setXMeasurementCursor
                            : null,
                    onYMeasurementDrag:
                        vm.yMeasurementEnabled
                            ? vm.setYMeasurementCursor
                            : null,
                    onXMeasurementDelete:
                        (index) => vm.removeMeasurementGroup(
                          isX: true,
                          groupIndex: index,
                        ),
                    onYMeasurementDelete:
                        (index) => vm.removeMeasurementGroup(
                          isX: false,
                          groupIndex: index,
                        ),
                    // 测量线拖动回调
                    onXCursor1Drag:
                        vm.xMeasurementEnabled
                            ? (x) => vm.setXCursor1(x)
                            : null,
                    onXCursor2Drag:
                        vm.xMeasurementEnabled
                            ? (x) => vm.setXCursor2(x)
                            : null,
                    onYCursor1Drag:
                        vm.yMeasurementEnabled
                            ? (y) => vm.setYCursor1(y)
                            : null,
                    onYCursor2Drag:
                        vm.yMeasurementEnabled
                            ? (y) => vm.setYCursor2(y)
                            : null,
                    // 统计范围位置
                    statsX1: vm.statsRangeEnabled ? vm.statsX1 : null,
                    statsX2: vm.statsRangeEnabled ? vm.statsX2 : null,
                    // 统计范围拖动回调
                    onStatsX1Drag:
                        vm.statsRangeEnabled ? (x) => vm.setStatsX1(x) : null,
                    onStatsX2Drag:
                        vm.statsRangeEnabled ? (x) => vm.setStatsX2(x) : null,
                    // 通道偏移拖动回调
                    onChannelOffsetDrag:
                        (index, yOffset) =>
                            vm.setChannelYOffset(index, yOffset),
                    // 通道 Y 轴缩放回调（修饰键+滚轮在偏置Y轴列上）
                    onChannelYScaleZoom:
                        (index, scaleDelta) =>
                            vm.zoomChannelYScale(index, scaleDelta),
                    child: PlotLayerStack(snapshot: renderSnapshot),
                  ),
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          children: _buildObservationWidgets(
                            context,
                            vm,
                            renderViewport,
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
                  if (_liveValuesVisible) _buildLiveValuesBox(vm),
                ],
              ),
            ),
            if (_previewVisible && vm.previewToolbarEnabled)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: previewPanelHeight,
                child: _buildLocatorBar(context, vm),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLocatorBar(BuildContext context, PlotViewModel vm) {
    // 定位条只反映完整 X 范围与当前视口；它不绘制曲线，也不依赖主图 Y 轴状态。
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: PlotLocatorBar(
        pointCount: vm.pointCount,
        viewport: vm.viewport,
        onNavigate:
            (centerX, {required fromDrag}) =>
                vm.movePreviewViewportTo(centerX, fromDrag: fromDrag),
        onDragEnd: vm.saveDragViewport,
      ),
    );
  }

  double _plotFontSize(PlotViewModel vm, double base) {
    return (base + 1 + vm.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  List<Widget> _buildObservationWidgets(
    BuildContext context,
    PlotViewModel vm,
    PlotViewport viewport,
    Size size,
  ) {
    final widgets = <Widget>[];
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
        _DraggableObservationBox(
          key: ValueKey('observation_info_$i'),
          initialLeft: (sx + 10).clamp(plotLeft, plotRight - 180).toDouble(),
          initialTop:
              (plotTop + 8 + i * 8).clamp(plotTop, plotBottom - 80).toDouble(),
          child: _buildObservationTooltip(i, observation, vm),
        ),
      );
    }

    final preview = vm.observationPreview;
    if (vm.observationPlacementActive && preview != null) {
      final sx = viewport.dataToScreenX(preview.x, size.width);
      if (sx >= plotLeft && sx <= plotRight) {
        widgets.addAll([
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
                    color: Colors.amber.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: (sx - 22).clamp(plotLeft, plotRight - 44).toDouble(),
            top: plotTop - 24,
            child: IgnorePointer(
              child: Container(
                width: 44,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.black54, width: 0.5),
                ),
                child: Text(
                  'O${vm.observations.length + 1}',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: _plotFontSize(vm, 10),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ]);
      }
    }

    return widgets;
  }

  Widget _buildObservationTooltip(
    int index,
    PlotObservation observation,
    PlotViewModel vm,
  ) {
    final values = observation.channelValues;
    final rows = <Widget>[
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.amber,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              'O${index + 1}',
              style: TextStyle(
                color: Colors.black,
                fontSize: _plotFontSize(vm, 11),
                fontWeight: FontWeight.bold,
                fontFamily: 'SarasaUiSC',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'X: ${observation.x.toInt()}',
            style: TextStyle(
              color: _floatingTextColor(vm),
              fontSize: _plotFontSize(vm, 12),
              fontWeight: FontWeight.bold,
              fontFamily: 'SarasaUiSC',
            ),
          ),
        ],
      ),
    ];
    if (observation.hasData && values != null) {
      final currentChannels = vm.displayChannels;
      for (int i = 0; i < values.length && i < currentChannels.length; i++) {
        final channel = currentChannels[i];
        if (!channel.visible) continue;
        final name =
            channel.alias.isNotEmpty ? channel.alias : 'Ch${channel.index}';
        rows.add(
          _buildFloatingChannelValueRow(
            vm: vm,
            name: name,
            value: formatPlotValue(values[i]),
            color: channel.color,
          ),
        );
      }
    }
    if (observation.note.trim().isNotEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            observation.note,
            style: TextStyle(
              color: _floatingSubtleTextColor(vm),
              fontSize: _plotFontSize(vm, 11),
              fontFamily: 'SarasaUiSC',
              fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _floatingBoxBackgroundColor(vm),
        border: Border.all(color: _floatingBoxBorderColor(vm), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _buildLiveValuesBox(PlotViewModel vm) {
    final latestPoint = vm.latestDisplayDataPoint;
    if (latestPoint == null) return const SizedBox.shrink();

    final displayChannels = vm.displayChannels;
    final fontSize = _plotFontSize(vm, 12);
    var contentWidth = _measureFloatingTextWidth(
      AppStrings.plot.liveValues,
      fontSize: fontSize,
      fontWeight: FontWeight.bold,
    );
    final rows = <Widget>[
      Text(
        AppStrings.plot.liveValues,
        style: TextStyle(
          color: _floatingTextColor(vm),
          fontSize: _plotFontSize(vm, 12),
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 6),
    ];

    for (
      int i = 0;
      i < latestPoint.values.length && i < displayChannels.length;
      i++
    ) {
      final channel = displayChannels[i];
      if (!channel.visible) continue;
      final name =
          channel.alias.isNotEmpty ? channel.alias : 'Ch${channel.index}';
      final value = formatPlotValue(latestPoint.values[i]);
      contentWidth = math.max(
        contentWidth,
        14 +
            _measureFloatingTextWidth(
              '$name: $value',
              fontSize: fontSize,
              fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
            ),
      );
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: channel.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                fit: FlexFit.loose,
                child: _buildFloatingChannelValueRow(
                  vm: vm,
                  name: name,
                  value: value,
                  color: channel.color,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.length == 2) {
      rows.add(
        Text(
          '无显示通道',
          style: TextStyle(
            color: _floatingSubtleTextColor(vm),
            fontSize: _plotFontSize(vm, 12),
            fontFamily: 'SarasaUiSC',
            fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
    }

    return PlotDraggableInfoBox(
      key: const ValueKey('plot-live-values-box'),
      initialRight: vm.liveValuesPanelRight,
      initialTop: vm.liveValuesPanelTop(legendVisible: _legendVisible),
      backgroundColor: _floatingBoxBackgroundColor(vm),
      borderColor: Colors.lightBlue.withValues(alpha: 0.55),
      onPositionChanged:
          (right, top) => vm.setLiveValuesPanelPosition(right: right, top: top),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
        child: SizedBox(
          key: const ValueKey('plot-live-values-content'),
          width: contentWidth.clamp(120, 240),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: rows,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingChannelValueRow({
    required PlotViewModel vm,
    required String name,
    required String value,
    required Color color,
  }) {
    final style = TextStyle(
      color: color,
      fontSize: _plotFontSize(vm, 12),
      fontFamily: 'SarasaUiSC',
      fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Text(': $value', maxLines: 1, style: style),
      ],
    );
  }

  double _measureFloatingTextWidth(
    String text, {
    required double fontSize,
    FontWeight? fontWeight,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontFamily: 'SarasaUiSC',
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  Widget _buildLegendBox(PlotViewModel vm) {
    final displayCount = _activeDisplayChannelCount(vm);
    final visibleChannels =
        vm.channels
            .take(displayCount)
            .where((channel) => channel.visible)
            .toList();
    if (visibleChannels.isEmpty) return const SizedBox.shrink();
    final fontSize = _plotFontSize(vm, 12);
    final fontWeight = vm.plotFontBold ? FontWeight.bold : FontWeight.normal;
    // 图例按最长名称扩展，优先显示完整名称；极长名称仍限制宽度，避免遮住
    // 大部分绘图区。外层 Positioned 的可用宽度还会继续约束窄窗口。
    final longestNameWidth = visibleChannels.fold<double>(
      0,
      (width, channel) => math.max(
        width,
        _measureFloatingTextWidth(
          channel.alias.isNotEmpty ? channel.alias : 'Ch${channel.index}',
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
    );
    final contentWidth = (16 + longestNameWidth).clamp(96.0, 480.0);

    return PlotDraggableInfoBox(
      key: const ValueKey('plot-legend-box'),
      initialRight: vm.legendPanelRight,
      initialTop: vm.legendPanelTop,
      backgroundColor: _floatingBoxBackgroundColor(vm),
      borderColor: Colors.teal.withValues(alpha: 0.55),
      onPositionChanged:
          (right, top) => vm.setLegendPanelPosition(right: right, top: top),
      child: SizedBox(
        width: contentWidth,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '图例',
                  style: TextStyle(
                    color: _floatingTextColor(vm),
                    fontSize: fontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...visibleChannels.map((channel) {
                  final name =
                      channel.alias.isNotEmpty
                          ? channel.alias
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
                              color: _floatingTextColor(vm),
                              fontSize: fontSize,
                              fontFamily: 'SarasaUiSC',
                              fontWeight: fontWeight,
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
      case ParserType.justFloat:
        final configured = vm.parserConfig.channelCount;
        return (configured > 0 ? configured : vm.channels.length)
            .clamp(0, vm.channels.length)
            .toInt();
    }
  }

  // ========== 对话框 ==========
  /// 显示解析器配置对话框
  void _showParserConfigDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    showDialog(
      context: context,
      builder: (context) => _ParserConfigDialog(vm: vm),
    );
  }

  void _showSendProtocolConfigDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.sendProtocolConfig),
            content: SizedBox(
              width: 360,
              child:
                  vm.effectiveSendProtocolType == SendProtocolType.rProtocol
                      ? StatefulBuilder(
                        builder:
                            (context, setDialogState) => SwitchListTile(
                              value: vm.rProtocolLooseChannelSettings,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                AppStrings.plot.rProtocolLooseChannelSettings,
                              ),
                              subtitle: Text(
                                AppStrings
                                    .plot
                                    .rProtocolLooseChannelSettingsHelp,
                              ),
                              onChanged: (value) {
                                vm.setRProtocolLooseChannelSettings(value);
                                setDialogState(() {});
                              },
                            ),
                      )
                      : Text(AppStrings.plot.noSendProtocolConfig),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(AppStrings.common.close),
              ),
            ],
          ),
    );
  }

  /// 显示随机源频率设置对话框
  void _showRandomFreqDialog(BuildContext context, PlotViewModel vm) {
    final controller = TextEditingController(
      text: vm.randomFrequency.round().toString(),
    );
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.randomSourceFrequency),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppDialogTextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  labelText: AppStrings.plot.frequencyHz,
                  hintText: '1 ~ 100000',
                  suffixText: 'Hz',
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.plot.currentFrequency(vm.randomFrequency),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.cancel),
              ),
              TextButton(
                onPressed: () {
                  final hz = int.tryParse(controller.text);
                  if (hz != null) {
                    vm.setRandomFrequency(hz.toDouble());
                  }
                  Navigator.pop(context);
                },
                child: Text(AppStrings.common.confirm),
              ),
            ],
          ),
    ).whenComplete(controller.dispose);
  }

  Future<_PlotFileFormat?> _choosePlotFileFormat(
    BuildContext context,
    String title, {
    bool includeLegacyDat = false,
  }) {
    return showDialog<_PlotFileFormat>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: Text(title),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _PlotFileFormat.csv),
                child: Text(AppStrings.plot.csvText),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _PlotFileFormat.bin),
                child: Text(AppStrings.plot.binBinary),
              ),
              if (includeLegacyDat)
                SimpleDialogOption(
                  onPressed:
                      () => Navigator.pop(context, _PlotFileFormat.legacyDat),
                  child: Text(AppStrings.plot.legacyDat),
                ),
            ],
          ),
    );
  }

  void _exportPlotData(BuildContext context, PlotViewModel vm) async {
    if (!_canUsePlotFileOperations(vm)) return;
    final format = await _choosePlotFileFormat(
      context,
      AppStrings.plot.chooseExportFormat,
    );
    if (format == null || !context.mounted || !_canUsePlotFileOperations(vm)) {
      return;
    }
    switch (format) {
      case _PlotFileFormat.csv:
        _exportCsv(context, vm);
        break;
      case _PlotFileFormat.bin:
        _exportBin(context, vm);
        break;
      case _PlotFileFormat.legacyDat:
        break;
    }
  }

  void _exportCsv(BuildContext context, PlotViewModel vm) async {
    final options = await _showPlotExportOptionsDialog(context, vm);
    if (options == null || !context.mounted) return;

    final result = await FilePicker.saveFile(
      dialogTitle: AppStrings.plot.saveCsvFile,
      fileName: 'vscope_plot_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null) return; // 用户取消
    if (!context.mounted) return;

    await _runExportWithProgress(
      context: context,
      vm: vm,
      title: AppStrings.plot.exportCsvTitle,
      exportFile:
          ({onProgress, cancelToken}) => vm.exportToCsv(
            result,
            startIndex: options.startIndex,
            endIndex: options.endIndex,
            channelIndices: options.channelIndices,
            onProgress: onProgress,
            cancelToken: cancelToken,
          ),
    );
  }

  void _exportBin(BuildContext context, PlotViewModel vm) async {
    final options = await _showPlotExportOptionsDialog(context, vm);
    if (options == null || !context.mounted) return;

    final result = await FilePicker.saveFile(
      dialogTitle: AppStrings.plot.saveBinFile,
      fileName: 'vscope_plot_${DateTime.now().millisecondsSinceEpoch}.bin',
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    if (result == null) return;
    if (!context.mounted) return;

    await _runExportWithProgress(
      context: context,
      vm: vm,
      title: AppStrings.plot.exportBinTitle,
      exportFile:
          ({onProgress, cancelToken}) => vm.exportToBin(
            result,
            startIndex: options.startIndex,
            endIndex: options.endIndex,
            channelIndices: options.channelIndices,
            onProgress: onProgress,
            cancelToken: cancelToken,
          ),
    );
  }

  Future<_PlotExportOptions?> _showPlotExportOptionsDialog(
    BuildContext context,
    PlotViewModel vm,
  ) async {
    final maxIndex = vm.pointCount - 1;
    if (maxIndex < 0) return null;
    final candidateChannels = vm.exportCandidateChannels;
    if (candidateChannels.isEmpty) return null;
    final startController = TextEditingController(text: '0');
    final endController = TextEditingController(text: maxIndex.toString());
    final selectedChannelIndices = <int>{
      for (final channel in candidateChannels) channel.index,
    };
    String? errorText;

    return showDialog<_PlotExportOptions>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              void useCurrentViewport() {
                final start = vm.viewport.xMin.floor().clamp(0, maxIndex);
                final end = vm.viewport.xMax.ceil().clamp(0, maxIndex);
                startController.text = start.toString();
                endController.text = math.max(start, end).toString();
                setDialogState(() => errorText = null);
              }

              void submit() {
                final start = int.tryParse(startController.text.trim());
                final end = int.tryParse(endController.text.trim());
                if (start == null || end == null) {
                  setDialogState(() => errorText = '请输入整数起始点和结束点');
                  return;
                }
                if (start < 0 || end > maxIndex || start > end) {
                  setDialogState(
                    () => errorText = '范围应满足 0 <= 起始点 <= 结束点 <= $maxIndex',
                  );
                  return;
                }
                if (selectedChannelIndices.isEmpty) {
                  setDialogState(() => errorText = '请至少选择 1 个通道');
                  return;
                }
                if (selectedChannelIndices.length >
                    PlotConfiguration.totalChannelCount) {
                  setDialogState(
                    () =>
                        errorText =
                            '最多可同时导出 '
                            '${PlotConfiguration.totalChannelCount} 个通道',
                  );
                  return;
                }
                Navigator.of(dialogContext).pop(
                  _PlotExportOptions(
                    startIndex: start,
                    endIndex: end,
                    channelIndices: [
                      for (final channel in candidateChannels)
                        if (selectedChannelIndices.contains(channel.index))
                          channel.index,
                    ],
                  ),
                );
              }

              return AlertDialog(
                title: const Text('导出范围与通道'),
                content: SizedBox(
                  width: 440,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '可导出范围: 0-$maxIndex，导出文件内 X 将从 0 重新编号。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: AppDialogTextField(
                              controller: startController,
                              autofocus: true,
                              keyboardType: TextInputType.number,
                              labelText: '起始点',
                              onChanged: (_) {
                                if (errorText != null) {
                                  setDialogState(() => errorText = null);
                                }
                              },
                              onSubmitted: (_) => submit(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AppDialogTextField(
                              controller: endController,
                              keyboardType: TextInputType.number,
                              labelText: '结束点',
                              onChanged: (_) {
                                if (errorText != null) {
                                  setDialogState(() => errorText = null);
                                }
                              },
                              onSubmitted: (_) => submit(),
                            ),
                          ),
                        ],
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '导出通道',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(
                            '已选 ${selectedChannelIndices.length}/'
                            '${PlotConfiguration.totalChannelCount}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              setDialogState(() {
                                selectedChannelIndices.clear();
                                errorText = null;
                              });
                            },
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                      Container(
                        height: math.min(240, candidateChannels.length * 48),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: ListView.builder(
                          itemCount: candidateChannels.length,
                          itemBuilder: (context, index) {
                            final channel = candidateChannels[index];
                            final selected = selectedChannelIndices.contains(
                              channel.index,
                            );
                            final atLimit =
                                selectedChannelIndices.length >=
                                    PlotConfiguration.totalChannelCount &&
                                !selected;
                            return CheckboxListTile(
                              dense: true,
                              value: selected,
                              title: Text(vm.displayChannelName(channel.index)),
                              subtitle:
                                  channel.index >=
                                          PlotConfiguration.rawChannelCount
                                      ? Text(
                                        vm
                                            .mathChannels[channel.index -
                                                PlotConfiguration
                                                    .rawChannelCount]
                                            .expression,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                      : Text('Ch${channel.index}'),
                              onChanged:
                                  atLimit
                                      ? null
                                      : (value) {
                                        setDialogState(() {
                                          if (value ?? false) {
                                            selectedChannelIndices.add(
                                              channel.index,
                                            );
                                          } else {
                                            selectedChannelIndices.remove(
                                              channel.index,
                                            );
                                          }
                                          errorText = null;
                                        });
                                      },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '数学通道导出表达式计算后的实际值。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: useCurrentViewport,
                    child: const Text('使用当前视口'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  TextButton(onPressed: submit, child: const Text('继续')),
                ],
              );
            },
          ),
    ).whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        startController.dispose();
        endController.dispose();
      });
    });
  }

  Future<void> _runExportWithProgress({
    // 文件 IO 在 ViewModel 分批执行；页面仅托管可取消的进度弹窗和最终提示。
    required BuildContext context,
    required PlotViewModel vm,
    required String title,
    required Future<String?> Function({
      PlotExportProgressCallback? onProgress,
      PlotExportCancelToken? cancelToken,
    })
    exportFile,
  }) async {
    final cancelToken = PlotExportCancelToken();
    final progressNotifier = ValueNotifier<PlotImportProgress>(
      PlotImportProgress(
        stage: AppStrings.plot.exportPreparing,
        current: 0,
        total: 0,
      ),
    );
    var dialogClosed = false;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => _PlotFileProgressDialog(
              title: title,
              progressListenable: progressNotifier,
              cancelToken: cancelToken,
            ),
      ).whenComplete(() => dialogClosed = true),
    );
    await _waitForImportDialogPresentation();

    final path = await exportFile(
      onProgress: (progress) => progressNotifier.value = progress,
      cancelToken: cancelToken,
    );
    if (context.mounted && !dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progressNotifier.dispose();
    if (!context.mounted) return;
    vm.showStatusMessage(
      cancelToken.isCancelled
          ? '导出已取消'
          : path == null
          ? AppStrings.plot.exportFailed
          : '${AppStrings.plot.exportedPrefix}: $path',
    );
  }

  void _importPlotData(BuildContext context, PlotViewModel vm) async {
    if (!_canUsePlotFileOperations(vm)) return;
    final format = await _choosePlotFileFormat(
      context,
      AppStrings.plot.chooseImportFormat,
      includeLegacyDat: true,
    );
    if (format == null || !context.mounted || !_canUsePlotFileOperations(vm)) {
      return;
    }
    switch (format) {
      case _PlotFileFormat.csv:
        _importCsv(context, vm);
        break;
      case _PlotFileFormat.bin:
        _importBin(context, vm);
        break;
      case _PlotFileFormat.legacyDat:
        _importLegacyDat(context, vm);
        break;
    }
  }

  bool _canUsePlotFileOperations(PlotViewModel vm) {
    if (!vm.isPlotting && !vm.isStarting && !vm.isStopping) return true;
    vm.showStatusMessage(AppStrings.plot.fileOperationDisabledWhilePlotting);
    return false;
  }

  void _importCsv(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.plot.chooseCsvFile,
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;
    if (!context.mounted) return;

    await _runImportWithProgress(
      context: context,
      vm: vm,
      filePath: filePath,
      title: AppStrings.plot.importCsvTitle,
      importFile: vm.importFromCsv,
      successMessage: AppStrings.plot.importCsvSuccess,
    );
  }

  void _importBin(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.plot.chooseBinFile,
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;
    if (!context.mounted) return;

    await _runImportWithProgress(
      context: context,
      vm: vm,
      filePath: filePath,
      title: AppStrings.plot.importBinTitle,
      importFile: vm.importFromBin,
      successMessage: AppStrings.plot.importBinSuccess,
    );
  }

  void _importLegacyDat(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.plot.chooseLegacyDatFile,
      type: FileType.custom,
      allowedExtensions: ['dat'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null || !context.mounted) return;

    await _runImportWithProgress(
      context: context,
      vm: vm,
      filePath: filePath,
      title: AppStrings.plot.importLegacyDatTitle,
      importFile: vm.importFromLegacyDat,
      successMessage: AppStrings.plot.importLegacyDatSuccess,
    );
  }

  void _showTriggerConfigDialog(BuildContext context, PlotViewModel vm) {
    final initial = vm.triggerConfig;
    final triggerChannels = vm.triggerCandidateChannels;
    var enabled = initial.enabled;
    var channelIndex =
        triggerChannels.any((channel) => channel.index == initial.channelIndex)
            ? initial.channelIndex
            : (triggerChannels.isNotEmpty
                ? triggerChannels.first.index
                : initial.channelIndex);
    var comparison = initial.comparison;
    var action = initial.action;
    var observationMode = initial.observationMode;
    var includeSystemTime = initial.includeSystemTimeInNote;
    final targetController = TextEditingController(
      text: formatPlotValue(initial.targetValue),
    );
    final hitThresholdController = TextEditingController(
      text: initial.hitThreshold.toString(),
    );
    final triggerLimitController = TextEditingController(
      text: initial.triggerLimit.toString(),
    );
    final postPacketsController = TextEditingController(
      text: initial.postTriggerPacketCount.toString(),
    );

    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(AppStrings.plot.triggerConfig),
                  content: SizedBox(
                    width: 520,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(child: Text('启用触发')),
                              Switch(
                                value: enabled,
                                onChanged:
                                    triggerChannels.isEmpty
                                        ? null
                                        : (value) => setDialogState(
                                          () => enabled = value,
                                        ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          if (triggerChannels.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                '当前没有可用的普通或数学通道，无法选择触发通道。',
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: AppDialogDropdown<int>(
                                  value:
                                      triggerChannels.isEmpty
                                          ? null
                                          : channelIndex,
                                  hint: '通道',
                                  labelText: '通道',
                                  items: [
                                    for (final channel in triggerChannels)
                                      DropdownMenuItem(
                                        value: channel.index,
                                        child: Text(
                                          vm.displayChannelName(channel.index),
                                        ),
                                      ),
                                  ],
                                  onChanged:
                                      triggerChannels.isEmpty
                                          ? null
                                          : (value) => setDialogState(
                                            () => channelIndex = value ?? 0,
                                          ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AppDialogDropdown<PlotTriggerComparison>(
                                  value: comparison,
                                  hint: '条件',
                                  labelText: '条件',
                                  items: [
                                    for (final item
                                        in PlotTriggerComparison.values)
                                      DropdownMenuItem(
                                        value: item,
                                        child: Text(
                                          item.label,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                  ],
                                  onChanged:
                                      (value) => setDialogState(
                                        () =>
                                            comparison =
                                                value ??
                                                PlotTriggerComparison.greater,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 120,
                                child: AppDialogTextField(
                                  controller: targetController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      ),
                                  labelText: '目标值',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '数学通道按表达式原始值触发；包含 CHn[...] 数据偏移的数学通道暂不支持。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: AppDialogTextField(
                                  controller: hitThresholdController,
                                  keyboardType: TextInputType.number,
                                  labelText: '累计命中次数',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: AppDialogTextField(
                                  controller: triggerLimitController,
                                  keyboardType: TextInputType.number,
                                  labelText: '触发次数',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '累计命中次数表示命中 N 次算一次触发；触发次数表示 N 次触发后执行触发行为。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          AppDialogDropdown<PlotTriggerAction>(
                            value: action,
                            hint: '触发行为',
                            labelText: '触发行为',
                            items: [
                              for (final item in PlotTriggerAction.values)
                                DropdownMenuItem(
                                  value: item,
                                  child: Text(item.label),
                                ),
                            ],
                            onChanged:
                                (value) => setDialogState(
                                  () =>
                                      action =
                                          value ?? PlotTriggerAction.markOnly,
                                ),
                          ),
                          if (action == PlotTriggerAction.stopAfterPackets) ...[
                            const SizedBox(height: 12),
                            AppDialogTextField(
                              controller: postPacketsController,
                              keyboardType: TextInputType.number,
                              labelText: '继续接收包数',
                            ),
                          ],
                          const SizedBox(height: 12),
                          AppDialogDropdown<PlotTriggerObservationMode>(
                            value: observationMode,
                            hint: '观察标记',
                            labelText: '观察标记',
                            items: [
                              for (final item
                                  in PlotTriggerObservationMode.values)
                                DropdownMenuItem(
                                  value: item,
                                  child: Text(item.label),
                                ),
                            ],
                            onChanged:
                                (value) => setDialogState(
                                  () =>
                                      observationMode =
                                          value ??
                                          PlotTriggerObservationMode.none,
                                ),
                          ),
                          if (observationMode !=
                              PlotTriggerObservationMode.none)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('备注记录触发系统时间'),
                              value: includeSystemTime,
                              onChanged:
                                  (value) => setDialogState(
                                    () => includeSystemTime = value ?? false,
                                  ),
                            ),
                          Text(
                            AppStrings.plot.triggerObservationLimitHelp,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        vm.updateTriggerConfig(
                          PlotTriggerConfig(
                            enabled: enabled && triggerChannels.isNotEmpty,
                            channelIndex: channelIndex,
                            comparison: comparison,
                            targetValue:
                                double.tryParse(targetController.text.trim()) ??
                                initial.targetValue,
                            hitThreshold:
                                int.tryParse(
                                  hitThresholdController.text.trim(),
                                ) ??
                                1,
                            triggerLimit:
                                int.tryParse(
                                  triggerLimitController.text.trim(),
                                ) ??
                                1,
                            action: action,
                            postTriggerPacketCount:
                                int.tryParse(
                                  postPacketsController.text.trim(),
                                ) ??
                                0,
                            observationMode: observationMode,
                            includeSystemTimeInNote: includeSystemTime,
                          ),
                        );
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
          ),
    ).whenComplete(() {
      targetController.dispose();
      hitThresholdController.dispose();
      triggerLimitController.dispose();
      postPacketsController.dispose();
    });
  }

  void _showObservationManagerDialog(BuildContext context, PlotViewModel vm) {
    final noteControllers = <int, TextEditingController>{};

    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(AppStrings.plot.observationManage),
                  content: SizedBox(
                    width: 680,
                    height: 420,
                    child:
                        vm.observations.isEmpty
                            ? const Center(child: Text('暂无观察'))
                            : Column(
                              children: [
                                Container(
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    children: [
                                      SizedBox(width: 64, child: Text('观察')),
                                      SizedBox(width: 84, child: Text('X')),
                                      Expanded(child: Text('备注')),
                                      SizedBox(
                                        width: 128,
                                        child: Align(
                                          alignment: Alignment.center,
                                          child: Text('操作'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: vm.observations.length,
                                    separatorBuilder:
                                        (context, index) =>
                                            const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final observation =
                                          vm.observations[index];
                                      final controller = noteControllers
                                          .putIfAbsent(
                                            index,
                                            () => TextEditingController(
                                              text: observation.note,
                                            ),
                                          );
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: 64,
                                              child: Text(
                                                'O${index + 1}',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 84,
                                              child: Text(
                                                observation.x
                                                    .toInt()
                                                    .toString(),
                                              ),
                                            ),
                                            Expanded(
                                              child: TextField(
                                                controller: controller,
                                                minLines: 1,
                                                maxLines: 2,
                                                decoration:
                                                    const InputDecoration(
                                                      border:
                                                          OutlineInputBorder(),
                                                      isDense: true,
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 8,
                                                          ),
                                                    ),
                                                onChanged:
                                                    (value) => vm
                                                        .updateObservationNote(
                                                          index,
                                                          value,
                                                        ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 128,
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  IconButton(
                                                    tooltip:
                                                        observation.locked
                                                            ? '解除锁定'
                                                            : '锁定',
                                                    onPressed: () {
                                                      vm.setObservationLocked(
                                                        index,
                                                        !observation.locked,
                                                      );
                                                      setDialogState(() {});
                                                    },
                                                    icon: Icon(
                                                      observation.locked
                                                          ? Icons.lock
                                                          : Icons.lock_open,
                                                    ),
                                                  ),
                                                  IconButton(
                                                    tooltip: '跳转',
                                                    onPressed: () {
                                                      vm.jumpToObservation(
                                                        index,
                                                      );
                                                      Navigator.of(
                                                        dialogContext,
                                                      ).pop();
                                                    },
                                                    icon: const Icon(
                                                      Icons.my_location,
                                                    ),
                                                  ),
                                                  IconButton(
                                                    tooltip: '删除',
                                                    onPressed: () {
                                                      vm.removeObservation(
                                                        index,
                                                      );
                                                      for (final controller
                                                          in noteControllers
                                                              .values) {
                                                        controller.dispose();
                                                      }
                                                      noteControllers.clear();
                                                      setDialogState(() {});
                                                    },
                                                    icon: const Icon(
                                                      Icons.delete_outline,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
          ),
    ).whenComplete(() {
      for (final controller in noteControllers.values) {
        controller.dispose();
      }
    });
  }

  void _showCursorJumpDialog(BuildContext context, PlotViewModel vm) {
    final maxX = vm.maxJumpXIndex;
    if (maxX == null) return;
    final initialX = vm.cursor?.x ?? vm.viewport.xMin + vm.viewport.xRange / 2;
    final initialIndex = initialX.round().clamp(0, maxX).toInt();
    final controller = TextEditingController(text: initialIndex.toString());
    String? errorText;

    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              void submit() {
                final text = controller.text.trim();
                final x = int.tryParse(text);
                if (x == null) {
                  setDialogState(() => errorText = '请输入整数 X');
                  return;
                }
                if (!vm.canJumpToXIndex(x)) {
                  setDialogState(() => errorText = 'X 范围应为 0-$maxX');
                  return;
                }
                vm.jumpToXIndex(x);
                Navigator.of(dialogContext).pop();
              }

              return AlertDialog(
                title: const Text('跳转到 X'),
                content: SizedBox(
                  width: 260,
                  child: AppDialogTextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    labelText: 'X',
                    helperText: '范围: 0-$maxX',
                    errorText: errorText,
                    onChanged: (_) {
                      if (errorText != null) {
                        setDialogState(() => errorText = null);
                      }
                    },
                    onSubmitted: (_) => submit(),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  TextButton(onPressed: submit, child: const Text('跳转')),
                ],
              );
            },
          ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _runImportWithProgress({
    // 导入预检失败时 ViewModel 保留旧历史，页面不应预先清空图面。
    required BuildContext context,
    required PlotViewModel vm,
    required String filePath,
    required String title,
    required Future<String?> Function(
      String filePath, {
      PlotImportProgressCallback? onProgress,
    })
    importFile,
    required String successMessage,
  }) async {
    final progressNotifier = ValueNotifier<PlotImportProgress>(
      PlotImportProgress(
        stage: AppStrings.plot.importPreparing,
        current: 0,
        total: 0,
      ),
    );
    var dialogClosed = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => _PlotFileProgressDialog(
              title: title,
              progressListenable: progressNotifier,
            ),
      ).whenComplete(() => dialogClosed = true),
    );
    await _waitForImportDialogPresentation();

    final error = await importFile(
      filePath,
      onProgress: (progress) => progressNotifier.value = progress,
    );

    if (context.mounted && !dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progressNotifier.dispose();

    if (!context.mounted) return;
    if (error == null) {
      vm.showStatusMessage(successMessage);
    } else {
      vm.showStatusMessage(AppStrings.plot.importFailed(error));
    }
  }

  Future<void> _waitForImportDialogPresentation() async {
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    await SchedulerBinding.instance.endOfFrame;
  }

  /// 将字符串网格密度转换为 [GridDensity] 枚举
  GridDensity _parseGridDensity(String density) {
    return switch (density) {
      'sparse' => GridDensity.sparse,
      'dense' => GridDensity.dense,
      _ => GridDensity.normal,
    };
  }

  PlotBackgroundStyle _parsePlotBackground(String background) {
    return switch (background) {
      'light' => PlotBackgroundStyle.light,
      _ => PlotBackgroundStyle.dark,
    };
  }

  bool _usesLightPlotBackground(PlotViewModel vm) {
    return vm.plotBackground == 'light';
  }

  Color _floatingBoxBackgroundColor(PlotViewModel vm) {
    final color =
        _usesLightPlotBackground(vm) ? Colors.white : const Color(0xFF1A1A2E);
    return color.withValues(alpha: vm.floatingPanelOpacity);
  }

  Color _floatingBoxBorderColor(PlotViewModel vm) {
    return _usesLightPlotBackground(vm)
        ? const Color(0xFF94A3B8)
        : const Color(0xFF8888AA);
  }

  Color _floatingTextColor(PlotViewModel vm) {
    return _usesLightPlotBackground(vm)
        ? const Color(0xFF0F172A)
        : Colors.white;
  }

  Color _floatingSubtleTextColor(PlotViewModel vm) {
    return _usesLightPlotBackground(vm)
        ? const Color(0xFF475569)
        : Colors.white70;
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
            color: _floatingTextColor(vm),
            fontSize: _plotFontSize(vm, 12),
            fontFamily: 'SarasaUiSC',
            fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
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
            color: _floatingBoxBorderColor(vm).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(0.5),
          ),
        ),
      );
    }

    // 第二列及以后：统计信息（多列）
    if (vm.statsText != null) {
      children.add(_buildStatsContent(vm.statsText!, vm));
    }

    return PlotDraggableInfoBox(
      initialRight: 16,
      initialTop: 16,
      backgroundColor: _floatingBoxBackgroundColor(vm),
      borderColor:
          vm.statsText != null
              ? Colors.green.withValues(alpha: 0.5)
              : _floatingBoxBorderColor(vm),
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
      return _buildColoredStatsText(lines, vm);
    }

    // 多列布局
    final columns = <Widget>[];
    final itemsPerColumn = (channelBlocks.length / columnCount).ceil();

    for (int col = 0; col < columnCount; col++) {
      final start = col * itemsPerColumn;
      final end = (start + itemsPerColumn).clamp(0, channelBlocks.length);
      if (start >= end) break;

      final colBlocks = channelBlocks.sublist(start, end);
      final colLines = <String>[];
      for (int i = 0; i < colBlocks.length; i++) {
        if (i > 0) colLines.add('---');
        colLines.addAll(colBlocks[i]);
      }

      columns.add(_buildColoredStatsText(colLines, vm));

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

  Widget _buildColoredStatsText(List<String> lines, PlotViewModel vm) {
    final baseStyle = TextStyle(
      color: _floatingTextColor(vm),
      fontSize: _plotFontSize(vm, 11),
      fontFamily: 'SarasaUiSC',
      fontWeight: vm.plotFontBold ? FontWeight.bold : FontWeight.normal,
      height: 1.5,
    );
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      Color? channelColor;
      if (line.endsWith(':')) {
        final name = line.substring(0, line.length - 1);
        for (
          var channelIndex = 0;
          channelIndex < vm.displayChannels.length;
          channelIndex++
        ) {
          final channel = vm.displayChannels[channelIndex];
          final channelName =
              channel.alias.isNotEmpty ? channel.alias : 'Ch$channelIndex';
          if (channelName == name) {
            channelColor = channel.color;
            break;
          }
        }
      }
      spans.add(
        TextSpan(
          text: i == lines.length - 1 ? line : '$line\n',
          style:
              channelColor == null
                  ? baseStyle
                  : baseStyle.copyWith(color: channelColor),
        ),
      );
    }
    return RichText(text: TextSpan(children: spans));
  }

  Future<void> _showMeasurementSettingsDialog(
    BuildContext context,
    PlotViewModel vm, {
    required bool isX,
  }) async {
    var line1Color =
        isX ? vm.xMeasurementLine1Color : vm.yMeasurementLine1Color;
    var line2Color =
        isX ? vm.xMeasurementLine2Color : vm.yMeasurementLine2Color;
    var line1Opacity =
        isX ? vm.xMeasurementLine1Opacity : vm.yMeasurementLine1Opacity;
    var line2Opacity =
        isX ? vm.xMeasurementLine2Opacity : vm.yMeasurementLine2Opacity;
    var snapEnabled = vm.yMeasurementSnapEnabled;
    var multiEnabled =
        isX ? vm.xMultiMeasurementEnabled : vm.yMultiMeasurementEnabled;
    final opacityInputFormatter = TextInputFormatter.withFunction((
      oldValue,
      newValue,
    ) {
      if (newValue.text.isEmpty) return newValue;
      final value = int.tryParse(newValue.text);
      return value != null && value <= 100 ? newValue : oldValue;
    });

    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              Widget buildLineEditor({
                required String label,
                required Color color,
                required double opacity,
                required ValueKey<String> colorKey,
                required ValueKey<String> opacityKey,
                required VoidCallback onChooseColor,
                required ValueChanged<double> onOpacityChanged,
              }) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(AppStrings.plot.measurementLineColor),
                        const SizedBox(width: 12),
                        InkWell(
                          key: colorKey,
                          onTap: onChooseColor,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            width: 42,
                            height: 24,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade400),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          AppStrings.plot.measurementLineOpacity,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: kSecondaryDialogFieldWidth,
                          child: TextFormField(
                            key: opacityKey,
                            initialValue: (opacity * 100).round().toString(),
                            decoration: secondaryDialogFieldDecoration(
                              suffixText: '%',
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              opacityInputFormatter,
                            ],
                            onChanged: (text) {
                              final value = int.tryParse(text);
                              if (value != null) {
                                onOpacityChanged(value / 100);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              }

              Future<void> chooseColor(bool first) async {
                final selected = await _showChannelCustomColorPicker(
                  dialogContext,
                  first ? line1Color : line2Color,
                );
                if (selected == null) return;
                setDialogState(() {
                  if (first) {
                    line1Color = selected;
                  } else {
                    line2Color = selected;
                  }
                });
              }

              final prefix = isX ? 'x' : 'y';
              return AlertDialog(
                shape: kAdvancedSettingsDialogShape,
                title: Text(
                  isX
                      ? AppStrings.plot.measureXSettings
                      : AppStrings.plot.measureYSettings,
                ),
                content: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildLineEditor(
                        label: isX ? 'X1' : 'Y1',
                        color: line1Color,
                        opacity: line1Opacity,
                        colorKey: ValueKey('$prefix-measure-line1-color'),
                        opacityKey: ValueKey('$prefix-measure-line1-opacity'),
                        onChooseColor: () => chooseColor(true),
                        onOpacityChanged: (value) => line1Opacity = value,
                      ),
                      const Divider(height: 20),
                      buildLineEditor(
                        label: isX ? 'X2' : 'Y2',
                        color: line2Color,
                        opacity: line2Opacity,
                        colorKey: ValueKey('$prefix-measure-line2-color'),
                        opacityKey: ValueKey('$prefix-measure-line2-opacity'),
                        onChooseColor: () => chooseColor(false),
                        onOpacityChanged: (value) => line2Opacity = value,
                      ),
                      const Divider(height: 20),
                      AppSwitchRow(
                        key: ValueKey('$prefix-multi-measure-toggle'),
                        title: Text(AppStrings.plot.multiMeasurement),
                        subtitle: Text(
                          AppStrings.plot.multiMeasurementHelp,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: multiEnabled,
                        onChanged:
                            (value) =>
                                setDialogState(() => multiEnabled = value),
                      ),
                      if (!isX) ...[
                        const Divider(height: 20),
                        AppSwitchRow(
                          key: const ValueKey('y-measure-snap-toggle'),
                          title: Text(AppStrings.plot.measurementSnap),
                          subtitle: Text(
                            AppStrings.plot.measurementSnapHelp,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          value: snapEnabled,
                          onChanged:
                              (value) =>
                                  setDialogState(() => snapEnabled = value),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(AppStrings.common.cancel),
                  ),
                  FilledButton(
                    key: ValueKey('$prefix-measure-settings-save'),
                    onPressed: () {
                      if (isX) {
                        vm.setXMeasurementStyle(
                          line1Color: line1Color,
                          line1Opacity: line1Opacity,
                          line2Color: line2Color,
                          line2Opacity: line2Opacity,
                        );
                      } else {
                        vm.setYMeasurementStyle(
                          line1Color: line1Color,
                          line1Opacity: line1Opacity,
                          line2Color: line2Color,
                          line2Opacity: line2Opacity,
                        );
                        vm.setYMeasurementSnapEnabled(snapEnabled);
                      }
                      vm.setMultiMeasurementEnabled(
                        isX: isX,
                        value: multiEnabled,
                      );
                      Navigator.pop(dialogContext);
                    },
                    child: Text(AppStrings.common.save),
                  ),
                ],
              );
            },
          ),
    );
  }

  /// 显示高级设置对话框
  ///
  /// 包含：网格开关、网格密度、刷新帧率、绘图窗口上限。
  void _showAdvancedSettingsDialog(BuildContext context, PlotViewModel vm) {
    final draft = PlotUiSettingsDraft(
      showGrid: vm.showGrid,
      gridDensity: vm.gridDensity,
      background: vm.plotBackground,
      floatingPanelOpacity: vm.floatingPanelOpacity,
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      followPositionRatio: vm.followPositionRatio,
      observationClickToPlace: vm.observationClickToPlace,
      gestureModifier: vm.gestureModifier,
      showPlotSendDataInRaw: vm.showPlotSendDataInRaw,
      quality: vm.lodQuality,
      renderEngine: vm.renderEngine,
      windowPointLimit: vm.maxVisiblePoints,
      historyLimit: vm.plotRetentionLimitGiB,
      refreshFps: vm.refreshFps,
      yFitDisplayRatio: vm.yFitDisplayRatio,
      keepPlotOnRestart: vm.keepPlotOnRestart,
      discardInitialPacketCount: vm.discardInitialPacketCount,
      previewToolbarEnabled: vm.previewToolbarEnabled,
      triggerToolbarEnabled: vm.triggerToolbarEnabled,
      statsToolbarEnabled: vm.statsToolbarEnabled,
      snapHighlightEnabled: vm.snapHighlightEnabled,
      snapHighlightDiameter: vm.snapHighlightDiameter,
      snapHighlightColorMode: vm.snapHighlightColorMode,
    );
    final refreshFpsController = TextEditingController(
      text: vm.refreshFps.toString(),
    );
    final snapDiameterController = TextEditingController(
      text: vm.snapHighlightDiameter.toStringAsFixed(0),
    );
    final maxVisibleController = TextEditingController(
      text: _formatCompactCount(vm.maxVisiblePoints),
    );
    final plotRetentionLimitController = TextEditingController(
      text: vm.plotRetentionLimitGiB.toString(),
    );
    final discardInitialPacketController = TextEditingController(
      text: _formatCompactCount(vm.discardInitialPacketCount),
    );
    final followPositionController = TextEditingController(
      text: (vm.followPositionRatio * 100).round().toString(),
    );
    final yFitDisplayRatioController = TextEditingController(
      text: (vm.yFitDisplayRatio * 100).round().toString(),
    );
    final floatingPanelOpacityController = TextEditingController(
      text: (vm.floatingPanelOpacity * 100).round().toString(),
    );
    final advancedSettingsScrollController = ScrollController();
    final appearanceSectionKey = GlobalKey();
    final performanceSectionKey = GlobalKey();
    final fontSectionKey = GlobalKey();
    final viewportSectionKey = GlobalKey();
    final toolbarSectionKey = GlobalKey();
    final interactionSectionKey = GlobalKey();
    final dataSectionKey = GlobalKey();

    void applyFloatingPanelOpacity(StateSetter setDialogState) {
      final percent = double.tryParse(
        floatingPanelOpacityController.text.trim(),
      );
      if (percent != null) {
        draft.floatingPanelOpacity = percent / 100;
      }
      setDialogState(() {});
    }

    void applyFollowPosition(StateSetter setDialogState) {
      final percent = double.tryParse(followPositionController.text.trim());
      if (percent != null) {
        draft.followPositionRatio = percent / 100;
      }
      setDialogState(() {});
    }

    void applyYFitRatio(StateSetter setDialogState) {
      final percent = double.tryParse(yFitDisplayRatioController.text.trim());
      if (percent != null) {
        draft.yFitDisplayRatio = percent / 100;
      }
      setDialogState(() {});
    }

    showDialog(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setState) {
              return AppSettingsDialog(
                title: Text(AppStrings.plot.advancedSettings),
                size: AppDialogSize.navigation,
                hasUnsavedChanges:
                    () =>
                        draft.showGrid != vm.showGrid ||
                        draft.gridDensity != vm.gridDensity ||
                        draft.background != vm.plotBackground ||
                        floatingPanelOpacityController.text !=
                            '${(vm.floatingPanelOpacity * 100).round()}' ||
                        draft.fontSizeDelta != vm.plotFontSizeDelta ||
                        draft.fontBold != vm.plotFontBold ||
                        followPositionController.text !=
                            '${(vm.followPositionRatio * 100).round()}' ||
                        yFitDisplayRatioController.text !=
                            '${(vm.yFitDisplayRatio * 100).round()}' ||
                        draft.observationClickToPlace !=
                            vm.observationClickToPlace ||
                        draft.gestureModifier != vm.gestureModifier ||
                        draft.showPlotSendDataInRaw !=
                            vm.showPlotSendDataInRaw ||
                        draft.quality != vm.lodQuality ||
                        draft.renderEngine != vm.renderEngine ||
                        refreshFpsController.text != '${vm.refreshFps}' ||
                        draft.previewToolbarEnabled !=
                            vm.previewToolbarEnabled ||
                        draft.triggerToolbarEnabled !=
                            vm.triggerToolbarEnabled ||
                        draft.statsToolbarEnabled != vm.statsToolbarEnabled ||
                        draft.snapHighlightEnabled != vm.snapHighlightEnabled ||
                        snapDiameterController.text !=
                            vm.snapHighlightDiameter.toStringAsFixed(0) ||
                        draft.snapHighlightColorMode !=
                            vm.snapHighlightColorMode ||
                        draft.keepPlotOnRestart != vm.keepPlotOnRestart ||
                        plotRetentionLimitController.text !=
                            '${vm.plotRetentionLimitGiB}' ||
                        maxVisibleController.text !=
                            _formatCompactCount(vm.maxVisiblePoints) ||
                        discardInitialPacketController.text !=
                            _formatCompactCount(vm.discardInitialPacketCount),
                onSave: () async {
                  applyFloatingPanelOpacity(setState);
                  applyFollowPosition(setState);
                  applyYFitRatio(setState);
                  final fps = int.tryParse(refreshFpsController.text.trim());
                  final diameter = double.tryParse(
                    snapDiameterController.text.trim(),
                  );
                  final history = int.tryParse(
                    plotRetentionLimitController.text.trim(),
                  );
                  final window = _parseCompactCount(
                    maxVisibleController.text.trim(),
                  );
                  final discard = _parseCompactCount(
                    discardInitialPacketController.text.trim(),
                  );
                  if (fps == null ||
                      fps < PlotConfiguration.minRefreshFps ||
                      fps > PlotConfiguration.maxRefreshFps ||
                      diameter == null ||
                      diameter < 6 ||
                      diameter > 12 ||
                      draft.floatingPanelOpacity < 0 ||
                      draft.floatingPanelOpacity > 1 ||
                      draft.followPositionRatio < 0.5 ||
                      draft.followPositionRatio > 0.95 ||
                      draft.yFitDisplayRatio! < 0.5 ||
                      draft.yFitDisplayRatio! > 0.95 ||
                      history == null ||
                      history < PlotConfiguration.minHistoryMemoryLimitGiB ||
                      history > PlotConfiguration.maxHistoryMemoryLimitGiB ||
                      window == null ||
                      window < PlotViewModel.minVisiblePoints ||
                      window > PlotViewModel.maxVisiblePointsLimit ||
                      discard == null ||
                      discard < 0 ||
                      discard > PlotViewModel.maxDiscardInitialPacketCount) {
                    throw const FormatException('请检查绘图设置中的数值范围');
                  }
                  draft
                    ..refreshFps = fps
                    ..snapHighlightDiameter = diameter
                    ..historyLimit = history
                    ..windowPointLimit = window
                    ..discardInitialPacketCount = discard;
                  await vm.applyPlotSettings(draft);
                  if (!(draft.previewToolbarEnabled ?? true)) {
                    _previewVisible = false;
                  }
                },
                child: SettingsNavigationView(
                  scrollController: advancedSettingsScrollController,
                  items: [
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsAppearance,
                      anchorKey: appearanceSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsPerformance,
                      anchorKey: performanceSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsText,
                      anchorKey: fontSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsViewport,
                      anchorKey: viewportSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsToolbar,
                      anchorKey: toolbarSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsInteraction,
                      anchorKey: interactionSectionKey,
                    ),
                    SettingsNavigationItem(
                      label: AppStrings.common.settingsData,
                      anchorKey: dataSectionKey,
                    ),
                  ],
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        key: appearanceSectionKey,
                        AppStrings.plot.plotBackground,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      AppSegmentedSelector<String>(
                        value: draft.background as String,
                        items: {
                          'dark': Text(AppStrings.plot.plotBackgroundDark),
                          'light': Text(AppStrings.plot.plotBackgroundLight),
                        },
                        onChanged:
                            (value) => setState(() => draft.background = value),
                      ),
                      const SizedBox(height: 8),
                      // 网格开关
                      Row(
                        children: [
                          Text(
                            AppStrings.plot.showGrid,
                            style: const TextStyle(fontSize: 14),
                          ),
                          const Spacer(),
                          Switch(
                            value: draft.showGrid,
                            onChanged: (value) {
                              setState(() => draft.showGrid = value);
                            },
                          ),
                        ],
                      ),
                      // 网格密度
                      if (draft.showGrid) ...[
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.plot.gridDensity,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        AppSegmentedSelector<String>(
                          value: draft.gridDensity as String,
                          items: {
                            'sparse': Text(AppStrings.plot.densitySparse),
                            'normal': Text(AppStrings.plot.densityNormal),
                            'dense': Text(AppStrings.plot.densityDense),
                          },
                          onChanged:
                              (value) =>
                                  setState(() => draft.gridDensity = value),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            AppStrings.plot.floatingPanelOpacity,
                            style: const TextStyle(fontSize: 14),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: floatingPanelOpacityController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '%',
                              ),
                              onSubmitted:
                                  (_) => applyFloatingPanelOpacity(setState),
                            ),
                          ),
                        ],
                      ),
                      const Divider(),
                      Text(
                        AppStrings.plot.renderEngine,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      AppSegmentedSelector<PlotRenderEngine>(
                        key: const ValueKey('plotRenderEngineSelector'),
                        value:
                            draft.renderEngine as PlotRenderEngine? ??
                            PlotRenderEngine.canvas,
                        items: {
                          PlotRenderEngine.canvas: Text(
                            AppStrings.plot.renderEngineCanvas,
                          ),
                          PlotRenderEngine.d3d11: Text(
                            AppStrings.plot.renderEngineD3d11,
                          ),
                        },
                        onChanged:
                            (value) =>
                                setState(() => draft.renderEngine = value),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.renderEngineHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        key: performanceSectionKey,
                        AppStrings.plot.lodQuality,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      AppSegmentedSelector<PlotLodQuality>(
                        key: const ValueKey('plotLodQualitySelector'),
                        value: draft.quality as PlotLodQuality,
                        items: {
                          PlotLodQuality.performance: Text(
                            AppStrings.plot.lodQualityPerformance,
                          ),
                          PlotLodQuality.balanced: Text(
                            AppStrings.plot.lodQualityBalanced,
                          ),
                          PlotLodQuality.quality: Text(
                            AppStrings.plot.lodQualityQuality,
                          ),
                        },
                        onChanged:
                            (value) => setState(() => draft.quality = value),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.lodQualityHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 刷新帧率是对质量档位的进一步性能约束，因此放在质量选择之后。
                      Text(
                        AppStrings.plot.refreshFps,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: refreshFpsController,
                              keyboardType: TextInputType.number,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: AppStrings.plot.unitFps,
                              ),
                              onSubmitted: (value) {
                                final fps = int.tryParse(value);
                                if (fps != null) {
                                  draft.refreshFps = fps;
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () {
                              final fps = int.tryParse(
                                refreshFpsController.text,
                              );
                              if (fps != null) {
                                draft.refreshFps = fps;
                                setState(() {});
                              }
                            },
                            child: Text(AppStrings.common.apply),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(1000 / (draft.refreshFps ?? vm.refreshFps)).round()}ms',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.refreshFpsHelp,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const Divider(),
                      Text(
                        key: fontSectionKey,
                        AppStrings.plot.plotFontSize,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            draft.fontSizeDelta == 0
                                ? AppStrings.plot.defaultValue
                                : draft.fontSizeDelta > 0
                                ? '+${draft.fontSizeDelta}'
                                : '${draft.fontSizeDelta}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            AppStrings.plot.fontPreview,
                            style: TextStyle(
                              fontSize:
                                  (14 + draft.fontSizeDelta)
                                      .clamp(10, 24)
                                      .toDouble(),
                              fontFamily: 'SarasaUiSC',
                              fontWeight:
                                  draft.fontBold
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: draft.fontSizeDelta.toDouble(),
                        min: -3,
                        max: 6,
                        divisions: 9,
                        label:
                            draft.fontSizeDelta == 0
                                ? AppStrings.plot.defaultValue
                                : draft.fontSizeDelta > 0
                                ? '+${draft.fontSizeDelta}'
                                : '${draft.fontSizeDelta}',
                        onChanged: (value) {
                          setState(() => draft.fontSizeDelta = value.round());
                        },
                      ),
                      AppSwitchRow(
                        title: Text(AppStrings.plot.plotFontBold),
                        value: draft.fontBold,
                        onChanged: (value) {
                          setState(() => draft.fontBold = value);
                        },
                      ),
                      Text(
                        AppStrings.plot.plotFontSizeHelp,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const Divider(),
                      Text(
                        key: viewportSectionKey,
                        AppStrings.plot.followPosition,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: followPositionController,
                              keyboardType: TextInputType.number,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '%',
                              ),
                              onSubmitted: (_) => applyFollowPosition(setState),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.followPositionHelp,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppStrings.plot.yFitDisplayRatio,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: yFitDisplayRatioController,
                              keyboardType: TextInputType.number,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '%',
                              ),
                              onSubmitted: (_) => applyYFitRatio(setState),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.yFitDisplayRatioHelp,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const Divider(),
                      Row(
                        key: toolbarSectionKey,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.plot.previewFeatureToggle,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppStrings.plot.previewFeatureHelp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.previewToolbarEnabled!,
                            onChanged: (value) {
                              setState(
                                () => draft.previewToolbarEnabled = value,
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.plot.triggerFeatureToggle,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppStrings.plot.triggerFeatureHelp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.triggerToolbarEnabled!,
                            onChanged: (value) {
                              setState(
                                () => draft.triggerToolbarEnabled = value,
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.plot.statsFeatureToggle,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppStrings.plot.statsFeatureHelp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.statsToolbarEnabled!,
                            onChanged: (value) {
                              setState(() => draft.statsToolbarEnabled = value);
                            },
                          ),
                        ],
                      ),
                      const Divider(),
                      Row(
                        key: interactionSectionKey,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.plot.observationClickToPlace,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppStrings.plot.observationClickToPlaceHelp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.observationClickToPlace,
                            onChanged: (value) {
                              setState(
                                () => draft.observationClickToPlace = value,
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      AppSwitchRow(
                        title: Text(AppStrings.plot.showPlotSendDataInRaw),
                        subtitle: Text(
                          AppStrings.plot.showPlotSendDataInRawHelp,
                        ),
                        value: draft.showPlotSendDataInRaw ?? true,
                        onChanged:
                            (value) => setState(
                              () => draft.showPlotSendDataInRaw = value,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.plot.axisZoomModifier,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      AppSegmentedSelector<PlotGestureModifier>(
                        value:
                            draft.gestureModifier as PlotGestureModifier? ??
                            PlotGestureModifier.shift,
                        items: const {
                          PlotGestureModifier.shift: Text('Shift'),
                          PlotGestureModifier.control: Text('Ctrl'),
                        },
                        onChanged:
                            (value) =>
                                setState(() => draft.gestureModifier = value),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.axisZoomModifierHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 吸附点高亮
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              AppStrings.plot.snapHighlight,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          Switch(
                            value: draft.snapHighlightEnabled!,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (value) {
                              setState(
                                () => draft.snapHighlightEnabled = value,
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: snapDiameterController,
                              keyboardType: TextInputType.number,
                              enabled: draft.snapHighlightEnabled,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: AppStrings.plot.unitPixel,
                              ),
                              onSubmitted: (value) {
                                final diameter = double.tryParse(value);
                                if (diameter != null) {
                                  draft.snapHighlightDiameter = diameter;
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.snapHighlightHelp,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppStrings.plot.snapHighlightColorMode,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      AppSegmentedSelector<String>(
                        value: draft.snapHighlightColorMode!,
                        enabled: draft.snapHighlightEnabled!,
                        items: {
                          'cursor': Text(
                            AppStrings.plot.snapHighlightColorCursor,
                          ),
                          'channel': Text(
                            AppStrings.plot.snapHighlightColorChannel,
                          ),
                        },
                        onChanged:
                            (value) => setState(
                              () => draft.snapHighlightColorMode = value,
                            ),
                      ),
                      const Divider(),
                      Row(
                        key: dataSectionKey,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.plot.keepPlotOnRestart,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  AppStrings.plot.keepPlotOnRestartHelp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.keepPlotOnRestart!,
                            onChanged: (value) {
                              setState(() => draft.keepPlotOnRestart = value);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.plot.plotHistoryMemoryLimit,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              key: const ValueKey('plot-retention-limit-field'),
                              controller: plotRetentionLimitController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: AppStrings.plot.unitGiB,
                              ),
                              onSubmitted: (value) {
                                final gib = int.tryParse(value);
                                if (gib != null) {
                                  draft.historyLimit = gib;
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.plotHistoryMemoryLimitHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.plot.plotWindowLimit,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: maxVisibleController,
                              keyboardType: TextInputType.text,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: AppStrings.plot.unitPacket,
                              ),
                              onSubmitted: (value) {
                                final points = _parseCompactCount(value);
                                if (points != null) {
                                  draft.windowPointLimit = points;
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.plotWindowLimitHelp(
                          min: _formatCompactCount(
                            PlotViewModel.minVisiblePoints,
                          ),
                          max: _formatCompactCount(
                            PlotViewModel.maxVisiblePointsLimit,
                          ),
                          defaultValue: _formatCompactCount(
                            PlotViewModel.defaultVisiblePoints,
                          ),
                          current: _formatCompactCount(vm.visiblePointCount),
                        ),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.plot.droppedPackets,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              controller: discardInitialPacketController,
                              keyboardType: TextInputType.text,
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: AppStrings.plot.unitPacket,
                              ),
                              onSubmitted: (value) {
                                final count = _parseCompactCount(value);
                                if (count != null) {
                                  draft.discardInitialPacketCount = count;
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.droppedPacketsHelp(
                          max: _formatCompactCount(
                            PlotViewModel.maxDiscardInitialPacketCount,
                          ),
                        ),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
    ).whenComplete(() {
      disposeAfterDialogTransition(() {
        refreshFpsController.dispose();
        snapDiameterController.dispose();
        maxVisibleController.dispose();
        plotRetentionLimitController.dispose();
        discardInitialPacketController.dispose();
        followPositionController.dispose();
        yFitDisplayRatioController.dispose();
        floatingPanelOpacityController.dispose();
        advancedSettingsScrollController.dispose();
      });
    });
  }

  /// 显示新建Zobow配置文件对话框
  void _showCreateZobowProfileDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    showDialog(
      context: context,
      builder: (context) => ZobowProfileDialog(vm: vm),
    );
  }

  /// 显示编辑Zobow配置文件对话框
  void _showEditZobowProfileDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    final profile = vm.selectedZobowProfile;
    if (profile == null) {
      vm.showStatusMessage(AppStrings.plot.selectConfigFirst);
      return;
    }
    showDialog(
      context: context,
      builder: (context) => ZobowProfileDialog(vm: vm, profile: profile),
    );
  }

  void _showCreateRProfileDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    showDialog(
      context: context,
      builder: (context) => RProtocolProfileDialog(vm: vm),
    );
  }

  void _showEditRProfileDialog(BuildContext context, PlotViewModel vm) {
    if (!_canOpenInputConfiguration(vm)) return;
    final profile = vm.selectedRProfile;
    if (profile == null) {
      vm.showStatusMessage(AppStrings.plot.selectRProtocolConfigFirst);
      return;
    }
    showDialog(
      context: context,
      builder: (context) => RProtocolProfileDialog(vm: vm, profile: profile),
    );
  }

  bool _canOpenInputConfiguration(PlotViewModel vm) {
    if (!vm.isPlotting && !vm.isStarting && !vm.isStopping) return true;
    vm.showStatusMessage(
      AppStrings.plot.inputConfigurationDisabledWhilePlotting,
    );
    return false;
  }
}

/// 通道面板使用自绘右键菜单，避免 [showMenu] 默认动画偏慢且样式过重。
class _ChannelContextMenu extends StatelessWidget {
  final _ChannelContextMenuTarget target;
  final VoidCallback? onAddMathChannel;
  final VoidCallback? onResetAllChannels;
  final VoidCallback? onEditChannel;
  final VoidCallback? onOffsetBinding;
  final VoidCallback? onDeleteMathChannel;

  const _ChannelContextMenu({
    required this.target,
    required this.onAddMathChannel,
    required this.onResetAllChannels,
    required this.onEditChannel,
    required this.onOffsetBinding,
    required this.onDeleteMathChannel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final children = switch (target.kind) {
      _ChannelContextMenuTargetKind.blank => [
        _ChannelContextMenuItem(
          icon: Icons.functions,
          label: AppStrings.plot.addMathChannel,
          onTap: onAddMathChannel,
        ),
        _ChannelContextMenuItem(
          icon: Icons.restart_alt,
          label: AppStrings.plot.resetAllChannels,
          onTap: onResetAllChannels,
        ),
      ],
      _ChannelContextMenuTargetKind.math => [
        _ChannelContextMenuItem(
          icon: Icons.settings_outlined,
          label: AppStrings.plot.editMathChannel,
          onTap: onEditChannel,
        ),
        if (target.channel?.offsetEnabled == true)
          _ChannelContextMenuItem(
            icon: Icons.link,
            label: AppStrings.plot.offsetBinding,
            onTap: onOffsetBinding,
          ),
        _ChannelContextMenuItem(
          icon: Icons.delete_outline,
          label: AppStrings.plot.deleteMathChannel,
          onTap: onDeleteMathChannel,
        ),
      ],
      _ChannelContextMenuTargetKind.raw => [
        _ChannelContextMenuItem(
          icon: Icons.settings_outlined,
          label: AppStrings.plot.editChannel,
          onTap: onEditChannel,
        ),
        if (target.channel?.offsetEnabled == true)
          _ChannelContextMenuItem(
            icon: Icons.link,
            label: AppStrings.plot.offsetBinding,
            onTap: onOffsetBinding,
          ),
      ],
    };
    return Material(
      color: colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                target.title,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ChannelContextMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ChannelContextMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color =
        enabled ? IconTheme.of(context).color : Theme.of(context).disabledColor;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ChannelContextMenuTargetKind { blank, raw, math }

class _ChannelContextMenuTarget {
  final _ChannelContextMenuTargetKind kind;
  final ChannelConfig? rawChannel;
  final MathChannelConfig? mathChannel;

  const _ChannelContextMenuTarget.blank()
    : kind = _ChannelContextMenuTargetKind.blank,
      rawChannel = null,
      mathChannel = null;

  const _ChannelContextMenuTarget.raw(this.rawChannel)
    : kind = _ChannelContextMenuTargetKind.raw,
      mathChannel = null;

  const _ChannelContextMenuTarget.math(this.mathChannel)
    : kind = _ChannelContextMenuTargetKind.math,
      rawChannel = null;

  ChannelConfig? get channel {
    return switch (kind) {
      _ChannelContextMenuTargetKind.raw => rawChannel,
      _ChannelContextMenuTargetKind.math => mathChannel?.display,
      _ChannelContextMenuTargetKind.blank => null,
    };
  }

  String get title {
    return switch (kind) {
      _ChannelContextMenuTargetKind.blank => AppStrings.plot.channelActions,
      _ChannelContextMenuTargetKind.raw =>
        rawChannel == null
            ? AppStrings.plot.channelActions
            : 'Ch${rawChannel!.index}',
      _ChannelContextMenuTargetKind.math =>
        mathChannel?.name ?? AppStrings.plot.channelActions,
    };
  }
}

class _OffsetBindingDialog extends StatefulWidget {
  final PlotViewModel vm;
  final int channelIndex;

  const _OffsetBindingDialog({required this.vm, required this.channelIndex});

  @override
  State<_OffsetBindingDialog> createState() => _OffsetBindingDialogState();
}

class _OffsetBindingDialogState extends State<_OffsetBindingDialog> {
  late Set<int> _selectedIndices;

  @override
  void initState() {
    super.initState();
    final members = widget.vm.offsetBindingMemberIndices(widget.channelIndex);
    _selectedIndices =
        members.where((index) => index != widget.channelIndex).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final candidates = widget.vm.offsetBindingCandidates(widget.channelIndex);
    final currentName = widget.vm.displayChannelName(widget.channelIndex);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text('${AppStrings.plot.offsetBindingTitle} - $currentName'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.plot.offsetBindingHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (candidates.isEmpty)
              Text(
                AppStrings.plot.offsetBindingNoCandidates,
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (context, index) {
                    final channel = candidates[index];
                    final name = widget.vm.displayChannelName(channel.index);
                    return CheckboxListTile(
                      value: _selectedIndices.contains(channel.index),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text(name, overflow: TextOverflow.ellipsis),
                      secondary: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: channel.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _selectedIndices.add(channel.index);
                          } else {
                            _selectedIndices.remove(channel.index);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.vm.clearOffsetBinding(widget.channelIndex);
            Navigator.pop(context);
          },
          child: Text(AppStrings.plot.closeOffsetBinding),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.common.cancel),
        ),
        ElevatedButton(
          onPressed:
              candidates.isEmpty
                  ? null
                  : () {
                    widget.vm.setOffsetBindingGroup(
                      widget.channelIndex,
                      _selectedIndices,
                    );
                    Navigator.pop(context);
                  },
          child: Text(AppStrings.common.confirm),
        ),
      ],
    );
  }
}
