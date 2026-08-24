import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/constants/rtt_configuration.dart';
import '../../core/constants/plot_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../core/utils/byte_size_formatter.dart';
import '../../core/utils/plot_value_formatter.dart';
import '../../data/models/plot_lod_index.dart';
import '../../data/models/plot_render_engine.dart';
import '../../data/models/probe_plot_config.dart';
import '../../data/models/probe_connection_config.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/j_scope_rtt_parser.dart';
import '../../viewmodels/probe_plot_viewmodel.dart';
import '../../viewmodels/settings_drafts.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_presentation_coordinator.dart';
import '../plot/plot_draggable_info_box.dart';
import '../plot/plot_layer_stack.dart';
import '../plot/plot_legend_box.dart';
import '../plot/plot_channel_row.dart';
import '../plot/plot_live_values_box.dart';
import '../plot/plot_locator_bar.dart';
import '../plot/plot_measurement_box.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_viewport.dart';
import '../widgets/app_icon.dart';
import '../widgets/common_widgets.dart';
import '../widgets/plot_color_picker.dart';
import '../widgets/plot_tools_toolbar.dart';

/// 将 ViewModel 暴露的 ARGB32 整数颜色转换回 Flutter `Color`。
Color? _argbToColor(int? value) => value == null ? null : Color(value);

/// 工具栏最小订阅集合：只包含工具栏按钮的禁用/选中与运行状态。
typedef _ProbeToolbarSelection =
    ({
      bool isConnected,
      bool operationPending,
      bool running,
      ProbePlotMode mode,
      int pointCount,
      bool vCursorEnabled,
      int? maxJumpPacketIndex,
      bool observationPlacementActive,
      bool xMeasurementEnabled,
      bool yMeasurementEnabled,
      bool follow,
      bool canUndoZoom,
      bool boxZoomEnabled,
      bool boxZoomContinuous,
      bool previewToolbarEnabled,
    });

/// 通道面板最小订阅集合：活动通道数量与通道配置版本号。
typedef _ProbeChannelPanelSelection =
    ({int activeChannelCount, int channelConfigRevision});

/// 独立于串口绘图的数据探针绘图页面。
class ProbePlotPage extends StatefulWidget {
  const ProbePlotPage({super.key});

  @override
  State<ProbePlotPage> createState() => _ProbePlotPageState();
}

class _ProbePlotPageState extends State<ProbePlotPage> {
  bool _channelPanelCollapsed = false;
  bool _legendVisible = false;
  bool _liveValuesVisible = false;
  bool _previewVisible = false;
  bool _cursorJumpDialogOpen = false;
  final PlotPresentationCoordinator _plotPresentation =
      PlotPresentationCoordinator();

  @override
  void dispose() {
    _plotPresentation.dispose();
    super.dispose();
  }

  Future<void> _toggle(ProbePlotViewModel vm) async {
    try {
      vm.running ? await vm.stop() : await vm.start();
    } catch (error) {
      AppNotifications.show('探针绘图操作失败: $error');
    }
  }

  Future<void> _confirmClear(ProbePlotViewModel vm) async {
    final confirmed = await showConfirmDialog(
      context,
      title: AppStrings.plot.clearData,
      message: AppStrings.probe.clearDataConfirmMessage,
    );
    if (confirmed) vm.clear();
  }

  _ProbeToolbarSelection _selectToolbar(ProbePlotViewModel vm) {
    return (
      isConnected: vm.service.isConnected,
      operationPending: vm.operationPending,
      running: vm.running,
      mode: vm.mode,
      pointCount: vm.pointCount,
      vCursorEnabled: vm.vCursorEnabled,
      maxJumpPacketIndex: vm.maxJumpPacketIndex,
      observationPlacementActive: vm.observationPlacementActive,
      xMeasurementEnabled: vm.xMeasurementEnabled,
      yMeasurementEnabled: vm.yMeasurementEnabled,
      follow: vm.follow,
      canUndoZoom: vm.canUndoZoom,
      boxZoomEnabled: vm.boxZoomEnabled,
      boxZoomContinuous: vm.boxZoomContinuous,
      previewToolbarEnabled: vm.previewToolbarEnabled,
    );
  }

  _ProbeChannelPanelSelection _selectChannelPanel(ProbePlotViewModel vm) {
    return (
      activeChannelCount: vm.activeChannelCount,
      channelConfigRevision: vm.channelConfigRevision,
    );
  }

  Widget _buildPrimaryToolbar(BuildContext context, ProbePlotViewModel vm) {
    return UnifiedToolbar(
      leadingItems: [
        ToolbarLayoutItem(
          extent: 92,
          child: ToolbarStartStopButton(
            onPressed:
                vm.service.isConnected && !vm.operationPending
                    ? () => unawaited(_toggle(vm))
                    : null,
            running: vm.running,
            label:
                vm.operationPending
                    ? (vm.running
                        ? AppStrings.plot.stopping
                        : AppStrings.probe.starting)
                    : vm.running
                    ? AppStrings.plot.stop
                    : AppStrings.plot.start,
          ),
        ),
        ToolbarLayoutItem(
          extent: 96,
          child: SizedBox(
            height: 24,
            child: SegmentedButton<ProbePlotMode>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: WidgetStatePropertyAll(Size(42, 24)),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 8),
                ),
                textStyle: WidgetStatePropertyAll(
                  TextStyle(
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                alignment: Alignment.center,
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                ),
              ),
              segments: [
                const ButtonSegment(
                  value: ProbePlotMode.hss,
                  label: SizedBox(
                    width: 28,
                    child: Center(
                      child: AppSegmentedButtonLabel(
                        child: Text('HSS', textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ),
                const ButtonSegment(
                  value: ProbePlotMode.rtt,
                  label: SizedBox(
                    width: 28,
                    child: Center(
                      child: AppSegmentedButtonLabel(
                        child: Text('RTT', textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ),
              ],
              selected: {vm.mode},
              onSelectionChanged:
                  vm.running
                      ? null
                      : (value) =>
                          unawaited(_changeMode(context, vm, value.first)),
              showSelectedIcon: false,
            ),
          ),
        ),
        ToolbarLayoutItem(
          extent: kToolbarControlExtent,
          child: ToolbarIconButton(
            key: const ValueKey('probe-source-settings-button'),
            icon: const Icon(Icons.settings),
            tooltip: AppStrings.probe.dataConfigTitle(vm.mode.label),
            onPressed: vm.running ? null : () => _showConfig(context, vm),
          ),
          overflowActions: [
            ToolbarOverflowAction(
              icon: const Icon(Icons.settings),
              label: AppStrings.probe.dataConfigTitle(vm.mode.label),
              onPressed: vm.running ? null : () => _showConfig(context, vm),
            ),
          ],
        ),
      ],
      trailingItems: [..._clearSettingsToolItems(context, vm)],
    );
  }

  Widget _buildSecondaryToolbar(BuildContext context, ProbePlotViewModel vm) {
    return UnifiedToolbar(
      leadingItems: [..._interactionToolItems(context, vm)],
      trailingItems: [..._zoomToolItems(vm), ..._fitToolItems(vm)],
    );
  }

  /// 探针页交互工具（光标/测量/跟随/图例/实时值）的共享配置。
  ///
  /// 与串口绘图页共用 [PlotToolConfig]/[PlotToolbarButton]，展示形态一致：
  /// 交互类 toggle 工具用图标+文字按钮（[label] 非空）。
  List<PlotToolConfig> _interactionToolConfigs(
    BuildContext context,
    ProbePlotViewModel vm,
  ) {
    return [
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotCursor),
        label: AppStrings.plot.cursor,
        tooltip: AppStrings.plot.verticalCursor,
        overflowLabel: AppStrings.plot.cursor,
        selected: vm.vCursorEnabled,
        activeColor: Colors.orange,
        onPressed:
            vm.pointCount == 0
                ? null
                : () => vm.setVCursorEnabled(!vm.vCursorEnabled),
        onSecondaryPressed:
            vm.maxJumpPacketIndex == null
                ? null
                : () => unawaited(_showCursorJumpDialog(context, vm)),
      ),
      PlotToolConfig(
        icon: const Icon(Icons.add_location_alt),
        label: AppStrings.plot.observation,
        tooltip:
            vm.observationPlacementActive
                ? AppStrings.plot.placeObservation
                : AppStrings.plot.addObservation,
        overflowLabel: AppStrings.plot.observation,
        selected: vm.observationPlacementActive,
        activeColor: Colors.amber,
        onPressed: vm.pointCount == 0 ? null : () => _addObservation(vm),
        onSecondaryPressed:
            () => unawaited(_showObservationManager(context, vm)),
      ),
      PlotToolConfig(
        key: const ValueKey('probe-plot-measure-x-button'),
        icon: const AppIcon(AppIcons.plotMeasureXx),
        label: AppStrings.plot.measureXx,
        tooltip: AppStrings.plot.measureXxTooltip,
        overflowLabel: AppStrings.plot.measureXx,
        selected: vm.xMeasurementEnabled,
        activeColor: Colors.blue,
        onPressed: vm.pointCount == 0 ? null : vm.toggleXMeasurement,
        onSecondaryPressed:
            () => unawaited(_showMeasurementSettings(context, vm, isX: true)),
      ),
      PlotToolConfig(
        key: const ValueKey('probe-plot-measure-y-button'),
        icon: const AppIcon(AppIcons.plotMeasureYy),
        label: AppStrings.plot.measureYy,
        tooltip: AppStrings.plot.measureYyTooltip,
        overflowLabel: AppStrings.plot.measureYy,
        selected: vm.yMeasurementEnabled,
        activeColor: Colors.blue,
        onPressed: vm.pointCount == 0 ? null : vm.toggleYMeasurement,
        onSecondaryPressed:
            () => unawaited(_showMeasurementSettings(context, vm, isX: false)),
      ),
      PlotToolConfig(
        key: const ValueKey('probe-plot-preview-button'),
        icon: const Icon(Icons.preview),
        label: AppStrings.plot.preview,
        tooltip: AppStrings.plot.previewTooltip,
        overflowLabel: AppStrings.plot.preview,
        selected: _previewVisible,
        activeColor: Colors.teal,
        visible: vm.previewToolbarEnabled,
        onPressed: () => setState(() => _previewVisible = !_previewVisible),
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotFollow),
        label: AppStrings.plot.follow,
        tooltip: AppStrings.plot.followTooltip,
        overflowLabel: AppStrings.plot.follow,
        selected: vm.follow,
        activeColor: Colors.orange,
        onPressed: () => vm.setFollow(!vm.follow),
      ),
      PlotToolConfig(
        icon: const Icon(Icons.list_alt),
        label: AppStrings.plot.legend,
        tooltip: AppStrings.plot.legend,
        overflowLabel: AppStrings.plot.legend,
        selected: _legendVisible,
        activeColor: Colors.teal,
        onPressed: () => setState(() => _legendVisible = !_legendVisible),
      ),
      PlotToolConfig(
        icon: const Icon(Icons.format_list_numbered),
        label: AppStrings.plot.liveValues,
        tooltip: AppStrings.plot.liveValues,
        overflowLabel: AppStrings.plot.liveValues,
        selected: _liveValuesVisible,
        activeColor: Colors.lightBlue,
        onPressed:
            () => setState(() => _liveValuesVisible = !_liveValuesVisible),
      ),
    ];
  }

  /// 交互工具按钮的内联宽度估算：图标+文字按钮比纯图标按钮更宽。
  double _toolExtent(PlotToolConfig tool) =>
      tool.label != null ? 80 : kToolbarControlExtent;

  List<ToolbarLayoutItem> _interactionToolItems(
    BuildContext context,
    ProbePlotViewModel vm,
  ) {
    return [
      for (final tool in _interactionToolConfigs(context, vm))
        if (tool.visible)
          ToolbarLayoutItem(
            extent: _toolExtent(tool),
            child: PlotToolbarButton(config: tool),
            overflowActions: [tool.toOverflowAction()],
          ),
    ];
  }

  /// 缩放/框选工具组配置。
  ///
  /// 顺序与串口页一致：撤回缩放 | 框选 | X放 | X缩 | Y放 | Y缩。
  List<PlotToolConfig> _zoomToolConfigs(ProbePlotViewModel vm) {
    final hasData = vm.pointCount > 0;
    return [
      PlotToolConfig(
        icon: const Icon(Icons.undo),
        tooltip: AppStrings.plot.undoZoom,
        overflowLabel: AppStrings.plot.undoZoom,
        toggle: false,
        onPressed: vm.canUndoZoom ? vm.undoZoom : null,
      ),
      PlotToolConfig(
        icon: const Icon(Icons.crop_free),
        tooltip: AppStrings.probe.boxZoomTooltip(AppStrings.plot.boxZoom),
        overflowLabel: AppStrings.plot.boxZoom,
        selected: vm.boxZoomEnabled,
        activeColor: vm.boxZoomContinuous ? Colors.orange : Colors.blue,
        onPressed: () => vm.setBoxZoomEnabled(!vm.boxZoomEnabled),
        onSecondaryPressed:
            () => vm.setBoxZoomEnabled(
              !(vm.boxZoomEnabled && vm.boxZoomContinuous),
              continuous: true,
            ),
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotZoomXIn),
        tooltip: AppStrings.plot.zoomXIn,
        overflowLabel: AppStrings.plot.zoomXIn,
        toggle: false,
        onPressed: hasData ? vm.zoomXIn : null,
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotZoomXOut),
        tooltip: AppStrings.plot.zoomXOut,
        overflowLabel: AppStrings.plot.zoomXOut,
        toggle: false,
        onPressed: hasData ? vm.zoomXOut : null,
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotZoomYIn),
        tooltip: AppStrings.plot.zoomYIn,
        overflowLabel: AppStrings.plot.zoomYIn,
        toggle: false,
        onPressed: hasData ? vm.zoomYIn : null,
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotZoomYOut),
        tooltip: AppStrings.plot.zoomYOut,
        overflowLabel: AppStrings.plot.zoomYOut,
        toggle: false,
        onPressed: hasData ? vm.zoomYOut : null,
      ),
    ];
  }

  List<ToolbarLayoutItem> _zoomToolItems(ProbePlotViewModel vm) {
    return [
      for (final tool in _zoomToolConfigs(vm))
        if (tool.visible)
          ToolbarLayoutItem(
            extent: _toolExtent(tool),
            child: PlotToolbarButton(config: tool),
            overflowActions: [tool.toOverflowAction()],
          ),
    ];
  }

  /// 自适应工具组配置（Y / X / 全自适应），形态与串口页一致。
  List<PlotToolConfig> _fitToolConfigs(ProbePlotViewModel vm) {
    final hasData = vm.pointCount > 0;
    return [
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotFitY),
        tooltip: AppStrings.plot.fitYTooltip,
        overflowLabel: AppStrings.plot.fitYTooltip,
        toggle: false,
        onPressed: hasData ? vm.fitYAxis : null,
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotFitX),
        tooltip: AppStrings.plot.fitXTooltip,
        overflowLabel: AppStrings.plot.fitXTooltip,
        toggle: false,
        onPressed: hasData ? vm.fitXAxis : null,
      ),
      PlotToolConfig(
        icon: const AppIcon(AppIcons.plotFitAll),
        tooltip: AppStrings.plot.fitAll,
        overflowLabel: AppStrings.plot.fitAll,
        toggle: false,
        onPressed: hasData ? vm.fitAll : null,
      ),
    ];
  }

  List<ToolbarLayoutItem> _fitToolItems(ProbePlotViewModel vm) {
    return [
      for (final tool in _fitToolConfigs(vm))
        if (tool.visible)
          ToolbarLayoutItem(
            extent: _toolExtent(tool),
            child: PlotToolbarButton(config: tool),
            overflowActions: [tool.toOverflowAction()],
          ),
    ];
  }

  List<PlotToolConfig> _clearSettingsToolConfigs(
    BuildContext context,
    ProbePlotViewModel vm,
  ) {
    return [
      PlotToolConfig(
        icon: const Icon(Icons.clear),
        tooltip: AppStrings.plot.clearData,
        overflowLabel: AppStrings.plot.clearData,
        toggle: false,
        onPressed:
            vm.pointCount == 0 ? null : () => unawaited(_confirmClear(vm)),
      ),
      PlotToolConfig(
        icon: const Icon(Icons.tune),
        tooltip: AppStrings.probe.plotSettings,
        overflowLabel: AppStrings.probe.plotSettings,
        toggle: false,
        onPressed: () => _showPlotSettings(context, vm),
      ),
    ];
  }

  List<ToolbarLayoutItem> _clearSettingsToolItems(
    BuildContext context,
    ProbePlotViewModel vm,
  ) {
    return [
      for (final tool in _clearSettingsToolConfigs(context, vm))
        if (tool.visible)
          ToolbarLayoutItem(
            extent: kToolbarControlExtent,
            child: PlotToolbarButton(config: tool),
            overflowActions: [tool.toOverflowAction()],
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.read<ProbePlotViewModel>();
    return Column(
      children: [
        Selector<ProbePlotViewModel, _ProbeToolbarSelection>(
          selector: (_, viewModel) => _selectToolbar(viewModel),
          builder:
              (context, _, _) => _buildPrimaryToolbar(
                context,
                context.read<ProbePlotViewModel>(),
              ),
        ),
        Selector<ProbePlotViewModel, _ProbeToolbarSelection>(
          selector: (_, viewModel) => _selectToolbar(viewModel),
          builder:
              (context, _, _) => _buildSecondaryToolbar(
                context,
                context.read<ProbePlotViewModel>(),
              ),
        ),
        Expanded(
          child: Row(
            children: [
              Selector<ProbePlotViewModel, _ProbeChannelPanelSelection>(
                selector: (_, viewModel) => _selectChannelPanel(viewModel),
                builder:
                    (context, _, _) => _buildChannelPanel(
                      context,
                      context.read<ProbePlotViewModel>(),
                    ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: vm.renderListenable,
                  builder:
                      (context, renderRevision, child) => LayoutBuilder(
                        builder: (context, constraints) {
                          final leftAxisWidth =
                              PlotLayerPainter.calculateLeftAxisWidth(
                                viewport: vm.viewport,
                                canvasHeight: constraints.maxHeight,
                                gridDensity: vm.gridDensity,
                                plotFontSizeDelta:
                                    vm.plotFontSizeDelta.toDouble(),
                                plotFontBold: vm.plotFontBold,
                              );
                          final renderViewport = vm.viewport.copyWith(
                            marginLeft: leftAxisWidth,
                          );
                          final plotPoints = vm.points;
                          final Widget plotSurface;
                          if (vm.pointCount == 0) {
                            plotSurface = Center(
                              child: Text(AppStrings.probe.noSamplingData),
                            );
                          } else {
                            final renderSnapshot = PlotRenderSnapshot(
                              viewport: renderViewport,
                              data: plotPoints,
                              dataRevision: vm.dataRevision,
                              viewportRevision: vm.viewportRevision,
                              channelConfigRevision: vm.channelConfigRevision,
                              overlayRevision: vm.overlayRevision,
                              lodIndex: vm.lodIndex,
                              lodQuality: vm.lodQuality,
                              renderEngine: vm.renderEngine,
                              devicePixelRatio: MediaQuery.devicePixelRatioOf(
                                context,
                              ),
                              channels: vm.channels,
                              activeChannelCount: vm.activeChannelCount,
                              showGrid: vm.showGrid,
                              gridDensity: vm.gridDensity,
                              backgroundStyle: vm.backgroundStyle,
                              floatingPanelOpacity: vm.floatingPanelOpacity,
                              cursor: vm.cursor,
                              xCursor1: vm.xCursor1,
                              xCursor2: vm.xCursor2,
                              yCursor1: vm.yCursor1,
                              yCursor2: vm.yCursor2,
                              xMeasurementLine1Color: _argbToColor(
                                vm.xMeasurementLine1Color,
                              ),
                              xMeasurementLine2Color: _argbToColor(
                                vm.xMeasurementLine2Color,
                              ),
                              yMeasurementLine1Color: _argbToColor(
                                vm.yMeasurementLine1Color,
                              ),
                              yMeasurementLine2Color: _argbToColor(
                                vm.yMeasurementLine2Color,
                              ),
                              xMeasurementLine1Opacity:
                                  vm.xMeasurementLine1Opacity,
                              xMeasurementLine2Opacity:
                                  vm.xMeasurementLine2Opacity,
                              yMeasurementLine1Opacity:
                                  vm.yMeasurementLine1Opacity,
                              yMeasurementLine2Opacity:
                                  vm.yMeasurementLine2Opacity,
                              plotFontSizeDelta: vm.plotFontSizeDelta,
                              plotFontBold: vm.plotFontBold,
                            );
                            if (vm.renderEngine == PlotRenderEngine.canvas ||
                                _plotPresentation.presentedSnapshot == null) {
                              _plotPresentation.present(
                                renderSnapshot,
                                frameId: vm.viewportRevision,
                                notify: false,
                                resetFrameSequence:
                                    vm.renderEngine == PlotRenderEngine.canvas,
                              );
                            }
                            plotSurface = PlotLayerStack(
                              snapshot: renderSnapshot,
                              presentationCoordinator: _plotPresentation,
                            );
                          }
                          final previewPanelHeight =
                              _previewVisible && vm.previewToolbarEnabled
                                  ? PlotConfiguration.locatorBarHeight
                                  : 0.0;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned.fill(
                                bottom: previewPanelHeight,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    PlotGestureHandler(
                                      viewport: renderViewport,
                                      presentationCoordinator:
                                          _plotPresentation,
                                      channels: vm.channels,
                                      activeChannelCount: vm.activeChannelCount,
                                      data: plotPoints,
                                      vCursorEnabled: vm.vCursorEnabled,
                                      boxZoomEnabled: vm.boxZoomEnabled,
                                      onBoxZoomCompleted: () {
                                        if (!vm.boxZoomContinuous) {
                                          vm.setBoxZoomEnabled(false);
                                        }
                                      },
                                      refreshFps: 60,
                                      plotFontSizeDelta: vm.plotFontSizeDelta,
                                      observations: vm.observations,
                                      onObservationDrag: vm.updateObservation,
                                      onObservationDelete: vm.removeObservation,
                                      observationPlacementActive:
                                          vm.observationPlacementActive,
                                      onObservationPlacementHover:
                                          vm.updateObservationPlacement,
                                      onObservationPlacementCommit:
                                          vm.commitObservationPlacement,
                                      onViewportChanged: vm.updateViewport,
                                      onContinuousZoomChanged:
                                          (viewport) => vm.updateViewport(
                                            viewport,
                                            fromDrag: true,
                                            preserveFollow: true,
                                          ),
                                      onDragEnd: vm.saveDragViewport,
                                      onCursorChanged: vm.updateCursor,
                                      xCursor1: vm.xCursor1,
                                      xCursor2: vm.xCursor2,
                                      yCursor1: vm.yCursor1,
                                      yCursor2: vm.yCursor2,
                                      yMeasurementSnapEnabled:
                                          vm.yMeasurementSnapEnabled,
                                      onXCursor1Drag:
                                          vm.xMeasurementEnabled
                                              ? vm.setXCursor1
                                              : null,
                                      onXCursor2Drag:
                                          vm.xMeasurementEnabled
                                              ? vm.setXCursor2
                                              : null,
                                      onYCursor1Drag:
                                          vm.yMeasurementEnabled
                                              ? vm.setYCursor1
                                              : null,
                                      onYCursor2Drag:
                                          vm.yMeasurementEnabled
                                              ? vm.setYCursor2
                                              : null,
                                      child: plotSurface,
                                    ),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: AnimatedBuilder(
                                          animation: _plotPresentation,
                                          builder:
                                              (context, _) => LayoutBuilder(
                                                builder: (
                                                  context,
                                                  overlayConstraints,
                                                ) {
                                                  final presentedViewport =
                                                      _plotPresentation
                                                          .presentedSnapshot
                                                          ?.viewport ??
                                                      renderViewport;
                                                  return Stack(
                                                    children:
                                                        _buildObservationWidgets(
                                                          context,
                                                          vm,
                                                          presentedViewport,
                                                          Size(
                                                            overlayConstraints
                                                                .maxWidth,
                                                            overlayConstraints
                                                                .maxHeight,
                                                          ),
                                                        ),
                                                  );
                                                },
                                              ),
                                        ),
                                      ),
                                    ),
                                    if (vm.measurementText != null)
                                      _buildMeasurementBox(context, vm),
                                    if (_legendVisible)
                                      _buildLegendBox(context, vm),
                                    if (_liveValuesVisible)
                                      _buildLiveValuesBox(context, vm),
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
                      ),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: kPageStatusBarHeight,
          padding: kPageStatusBarPadding,
          alignment: Alignment.centerLeft,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: ValueListenableBuilder<int>(
            valueListenable: vm.statusListenable,
            builder:
                (context, _, _) => Text(
                  '${vm.running ? AppStrings.probe.running : AppStrings.probe.stopped}  ${vm.mode.label}  '
                  '${AppStrings.probe.pointCountLabel} ${vm.pointCount}  ${AppStrings.probe.actualRateLabel} ${vm.actualRate.toStringAsFixed(1)} Hz  '
                  '${AppStrings.probe.memoryLabel} ${formatByteSize(vm.estimatedHistoryBytes)} / '
                  '${vm.historyMemoryLimitMiB} MiB'
                  '${vm.retentionLimitReached ? '  ${AppStrings.probe.retentionLimitReached}' : ''}',
                  style: kPageStatusBarTextStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          ),
        ),
      ],
    );
  }

  Future<void> _changeMode(
    BuildContext context,
    ProbePlotViewModel vm,
    ProbePlotMode mode,
  ) async {
    if (mode == vm.mode) return;
    if (vm.pointCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(AppStrings.probe.switchModeTitle),
              content: Text(
                AppStrings.probe.switchModeMessage(vm.mode.label, mode.label),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(AppStrings.common.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(AppStrings.probe.clearAndSwitch),
                ),
              ],
            ),
      );
      if (confirmed != true) return;
      vm.clear();
    }
    vm.setMode(mode);
  }

  Future<void> _showCursorJumpDialog(
    BuildContext context,
    ProbePlotViewModel vm,
  ) async {
    if (_cursorJumpDialogOpen) return;
    final minX = vm.minJumpPacketIndex;
    final maxX = vm.maxJumpPacketIndex;
    if (minX == null || maxX == null) return;
    final initialX = vm.cursor?.x ?? vm.viewport.xMin + vm.viewport.xRange / 2;
    final initialIndex = initialX.round().clamp(minX, maxX).toInt();
    _cursorJumpDialogOpen = true;
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder:
            (_) => _ProbeCursorJumpDialog(
              minX: minX,
              maxX: maxX,
              initialIndex: initialIndex,
            ),
      );
    } finally {
      _cursorJumpDialogOpen = false;
    }
    if (!mounted || index == null || !vm.canJumpToPacketIndex(index)) return;
    vm.jumpToPacketIndex(index);
  }

  Widget _buildChannelPanel(BuildContext context, ProbePlotViewModel vm) {
    if (_channelPanelCollapsed) {
      return Container(
        width: 26,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            Tooltip(
              message: AppStrings.plot.expandChannelPanel,
              child: InkWell(
                onTap: () => setState(() => _channelPanelCollapsed = false),
                child: const SizedBox(
                  width: 26,
                  height: 32,
                  child: Icon(Icons.chevron_right, size: 18),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: Text(
                    AppStrings.plot.channel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: 180,
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Text(
                  '${AppStrings.plot.channel} (${vm.activeChannelCount})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: AppStrings.plot.collapseChannelPanel,
                  child: InkWell(
                    onTap: () => setState(() => _channelPanelCollapsed = true),
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(Icons.chevron_left, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: vm.activeChannelCount,
              itemExtent: 40,
              itemBuilder: (context, index) {
                final channel = vm.channels[index];
                return InkWell(
                  onTap: () => vm.toggleChannel(index),
                  onLongPress: () => _renameChannel(context, vm, index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: PlotChannelRow(
                      data: PlotChannelRowData(
                        name: channel.alias,
                        color: channel.color,
                        visible: channel.visible,
                      ),
                      onToggleVisible: () => vm.toggleChannel(index),
                      dimNameWhenHidden: false,
                      colorBlockRadius: 0,
                      visibilityBuilder:
                          (visible, onToggle) => Checkbox(
                            value: visible,
                            onChanged: (_) => onToggle(),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendBox(BuildContext context, ProbePlotViewModel vm) {
    final visible = vm.channels
        .take(vm.activeChannelCount)
        .where((channel) => channel.visible)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    return PlotDraggableInfoBox(
      key: const ValueKey('probe-plot-legend-box'),
      initialRight: 12,
      initialTop: 12,
      borderColor: Colors.teal.withValues(alpha: 0.55),
      backgroundColor: Theme.of(
        context,
      ).colorScheme.surface.withValues(alpha: vm.floatingPanelOpacity),
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 96, maxWidth: 320),
        child: PlotLegendBox(channels: visible, nameMaxLines: 1),
      ),
    );
  }

  Widget _buildLiveValuesBox(BuildContext context, ProbePlotViewModel vm) {
    final latest = vm.latestPoint;
    if (latest == null) return const SizedBox.shrink();
    final entries = <PlotLiveValueEntry>[];
    for (
      var index = 0;
      index < latest.values.length &&
          index < vm.activeChannelCount &&
          index < vm.channels.length;
      index++
    ) {
      if (!vm.channels[index].visible) continue;
      entries.add(
        PlotLiveValueEntry(
          color: vm.channels[index].color,
          name: vm.channels[index].alias,
          value: formatPlotValue(latest.values[index]),
        ),
      );
    }
    return PlotDraggableInfoBox(
      key: const ValueKey('probe-plot-live-values-box'),
      initialRight: 12,
      initialTop: _legendVisible ? 150 : 12,
      borderColor: Colors.lightBlue.withValues(alpha: 0.55),
      backgroundColor: Theme.of(
        context,
      ).colorScheme.surface.withValues(alpha: vm.floatingPanelOpacity),
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
        child: PlotLiveValuesBox(
          entries: entries,
          rowPadding: const EdgeInsets.symmetric(vertical: 2),
        ),
      ),
    );
  }

  Widget _buildLocatorBar(BuildContext context, ProbePlotViewModel vm) {
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

  Future<void> _renameChannel(
    BuildContext context,
    ProbePlotViewModel vm,
    int index,
  ) async {
    final controller = TextEditingController(text: vm.channels[index].alias);
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(AppStrings.probe.renameChannel),
            content: AppDialogTextField(
              controller: controller,
              autofocus: true,
              labelText: AppStrings.probe.channelNameLabel,
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: Text(AppStrings.common.confirm),
              ),
            ],
          ),
    );
    controller.dispose();
    if (name != null) vm.renameChannel(index, name);
  }

  Future<void> _showConfig(BuildContext context, ProbePlotViewModel vm) async {
    if (vm.mode == ProbePlotMode.rtt) {
      await showDialog<void>(
        context: context,
        builder: (_) => _ProbeRttDataConfigDialog(vm: vm),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(AppStrings.probe.dataConfigTitle(vm.mode.label)),
            content: SingleChildScrollView(child: _HssConfigContent(vm: vm)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.confirm),
              ),
            ],
          ),
    );
  }

  void _addObservation(ProbePlotViewModel vm) {
    if (vm.observationClickToPlace) {
      vm.startObservationPlacement();
    } else {
      vm.addObservation();
    }
  }

  double _plotFontSize(ProbePlotViewModel vm, double base) {
    return (base + 1 + vm.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  Widget _buildMeasurementBox(BuildContext context, ProbePlotViewModel vm) {
    return PlotDraggableInfoBox(
      key: const ValueKey('probe-plot-measurement-box'),
      initialRight: 12,
      initialTop: 12,
      borderColor: Colors.blue.withValues(alpha: 0.55),
      backgroundColor: Theme.of(
        context,
      ).colorScheme.surface.withValues(alpha: vm.floatingPanelOpacity),
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: PlotMeasurementBox(
        text: vm.measurementText!,
        fontSize: _plotFontSize(vm, 12),
        tabularFigures: true,
      ),
    );
  }

  List<Widget> _buildObservationWidgets(
    BuildContext context,
    ProbePlotViewModel vm,
    PlotViewport viewport,
    Size size,
  ) {
    final widgets = <Widget>[];
    final plotTop = viewport.marginTop;
    final plotBottom = size.height - viewport.marginBottom;
    final plotLeft = viewport.marginLeft;
    final plotRight = size.width - viewport.marginRight;

    void appendObservation(
      PlotObservation observation,
      String label,
      double alpha,
    ) {
      final sx = viewport.dataToScreenX(observation.x, size.width);
      if (sx < plotLeft || sx > plotRight) return;
      widgets.add(
        Positioned(
          left: sx - 5,
          top: plotTop,
          bottom: viewport.marginBottom,
          child: SizedBox(
            width: 10,
            child: Center(
              child: Container(
                width: 1,
                color: Colors.amber.withValues(alpha: alpha),
              ),
            ),
          ),
        ),
      );
      widgets.add(
        Positioned(
          left: (sx - 22).clamp(plotLeft, plotRight - 44).toDouble(),
          top: (plotTop - 24).clamp(0, plotBottom).toDouble(),
          child: Container(
            width: 44,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.black54, width: 0.5),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.black,
                fontSize: _plotFontSize(vm, 10),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
    }

    for (var index = 0; index < vm.observations.length; index++) {
      appendObservation(vm.observations[index], 'O${index + 1}', 0.9);
    }
    final preview = vm.observationPreview;
    if (vm.observationPlacementActive && preview != null) {
      appendObservation(preview, 'O${vm.observations.length + 1}', 0.65);
    }
    return widgets;
  }

  Future<void> _showObservationManager(
    BuildContext context,
    ProbePlotViewModel vm,
  ) {
    return showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(AppStrings.plot.observationManage),
                  content: SizedBox(
                    width: 520,
                    height: 360,
                    child:
                        vm.observations.isEmpty
                            ? Center(
                              child: Text(AppStrings.probe.noObservation),
                            )
                            : ListView.separated(
                              itemCount: vm.observations.length,
                              separatorBuilder:
                                  (_, _) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final observation = vm.observations[index];
                                return ListTile(
                                  dense: true,
                                  leading: Text(
                                    'O${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.amber,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  title: TextFormField(
                                    initialValue: observation.note,
                                    decoration: InputDecoration(
                                      hintText: AppStrings.probe.noteHint,
                                      isDense: true,
                                      suffixText:
                                          'X=${observation.x.toStringAsFixed(0)}',
                                    ),
                                    onChanged:
                                        (value) => vm.updateObservationNote(
                                          index,
                                          value,
                                        ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: AppStrings.probe.locate,
                                        icon: const Icon(Icons.my_location),
                                        onPressed: () {
                                          vm.jumpToObservation(index);
                                          Navigator.pop(dialogContext);
                                        },
                                      ),
                                      IconButton(
                                        tooltip:
                                            observation.locked
                                                ? AppStrings.probe.unlock
                                                : AppStrings.probe.lock,
                                        icon: Icon(
                                          observation.locked
                                              ? Icons.lock
                                              : Icons.lock_open,
                                        ),
                                        onPressed: () {
                                          vm.setObservationLocked(
                                            index,
                                            !observation.locked,
                                          );
                                          setDialogState(() {});
                                        },
                                      ),
                                      IconButton(
                                        tooltip: AppStrings.common.delete,
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () {
                                          vm.removeObservation(index);
                                          setDialogState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(AppStrings.common.close),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _showMeasurementSettings(
    BuildContext context,
    ProbePlotViewModel vm, {
    required bool isX,
  }) async {
    final defaultPrimary =
        vm.backgroundStyle == PlotBackgroundStyle.light
            ? const Color(0xFF0369A1)
            : Colors.cyan;
    final defaultSecondary =
        vm.backgroundStyle == PlotBackgroundStyle.light
            ? const Color(0xFFB45309)
            : Colors.yellow;
    var line1Color =
        _argbToColor(
          isX ? vm.xMeasurementLine1Color : vm.yMeasurementLine1Color,
        ) ??
        defaultPrimary;
    var line2Color =
        _argbToColor(
          isX ? vm.xMeasurementLine2Color : vm.yMeasurementLine2Color,
        ) ??
        defaultSecondary;
    var line1Opacity =
        isX ? vm.xMeasurementLine1Opacity : vm.yMeasurementLine1Opacity;
    var line2Opacity =
        isX ? vm.xMeasurementLine2Opacity : vm.yMeasurementLine2Opacity;
    var snapEnabled = vm.yMeasurementSnapEnabled;
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
                final selected = await showPlotCustomColorPicker(
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
                      if (!isX) ...[
                        const Divider(height: 20),
                        AppSwitchRow(
                          key: const ValueKey('y-measure-snap-toggle'),
                          title: Text(AppStrings.plot.measurementSnap),
                          subtitle: Text(AppStrings.plot.measurementSnapHelp),
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
                          line1Color: line1Color.toARGB32(),
                          line1Opacity: line1Opacity,
                          line2Color: line2Color.toARGB32(),
                          line2Opacity: line2Opacity,
                        );
                      } else {
                        vm.setYMeasurementStyle(
                          line1Color: line1Color.toARGB32(),
                          line1Opacity: line1Opacity,
                          line2Color: line2Color.toARGB32(),
                          line2Opacity: line2Opacity,
                        );
                        vm.setYMeasurementSnapEnabled(snapEnabled);
                      }
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

  Future<void> _showPlotSettings(
    BuildContext context,
    ProbePlotViewModel vm,
  ) async {
    final draft = PlotUiSettingsDraft(
      showGrid: vm.showGrid,
      gridDensity: vm.gridDensity,
      background: vm.backgroundStyle,
      floatingPanelOpacity: vm.floatingPanelOpacity,
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      followPositionRatio: vm.followPositionRatio,
      observationClickToPlace: vm.observationClickToPlace,
      quality: vm.lodQuality,
      renderEngine: vm.renderEngine,
      windowPointLimit: vm.windowPointLimit,
      historyLimit: vm.historyMemoryLimitMiB,
      previewToolbarEnabled: vm.previewToolbarEnabled,
    );
    final windowController = TextEditingController(
      text: vm.windowPointLimit.toString(),
    );
    final memoryController = TextEditingController(
      text: vm.historyMemoryLimitMiB.toString(),
    );
    final opacityController = TextEditingController(
      text: (vm.floatingPanelOpacity * 100).round().toString(),
    );
    final followController = TextEditingController(
      text: (vm.followPositionRatio * 100).round().toString(),
    );
    final settingsScrollController = ScrollController();
    final appearanceSectionKey = GlobalKey();
    final performanceSectionKey = GlobalKey();
    final fontSectionKey = GlobalKey();
    final viewportSectionKey = GlobalKey();
    final toolbarSectionKey = GlobalKey();
    final interactionSectionKey = GlobalKey();
    final dataSectionKey = GlobalKey();

    void applyWindowPointLimit(StateSetter setDialogState) {
      final value = int.tryParse(windowController.text.trim());
      if (value != null) draft.windowPointLimit = value;
      setDialogState(() {});
    }

    void applyHistoryMemoryLimit(StateSetter setDialogState) {
      final value = int.tryParse(memoryController.text.trim());
      if (value != null) draft.historyLimit = value;
      setDialogState(() {});
    }

    void applyFloatingPanelOpacity(StateSetter setDialogState) {
      final percent = int.tryParse(opacityController.text.trim());
      if (percent != null) draft.floatingPanelOpacity = percent / 100;
      setDialogState(() {});
    }

    void applyFollowPosition(StateSetter setDialogState) {
      final percent = int.tryParse(followController.text.trim());
      if (percent != null) draft.followPositionRatio = percent / 100;
      setDialogState(() {});
    }

    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AppSettingsDialog(
                title: Text(AppStrings.plot.advancedSettings),
                size: AppDialogSize.navigation,
                changeListenables: [
                  windowController,
                  memoryController,
                  opacityController,
                  followController,
                ],
                hasUnsavedChanges:
                    () =>
                        draft.showGrid != vm.showGrid ||
                        draft.gridDensity != vm.gridDensity ||
                        draft.background != vm.backgroundStyle ||
                        opacityController.text !=
                            '${(vm.floatingPanelOpacity * 100).round()}' ||
                        draft.fontSizeDelta != vm.plotFontSizeDelta ||
                        draft.fontBold != vm.plotFontBold ||
                        followController.text !=
                            '${(vm.followPositionRatio * 100).round()}' ||
                        draft.observationClickToPlace !=
                            vm.observationClickToPlace ||
                        draft.quality != vm.lodQuality ||
                        draft.renderEngine != vm.renderEngine ||
                        draft.previewToolbarEnabled !=
                            vm.previewToolbarEnabled ||
                        windowController.text != '${vm.windowPointLimit}' ||
                        memoryController.text != '${vm.historyMemoryLimitMiB}',
                onSave: () async {
                  applyFloatingPanelOpacity(setDialogState);
                  applyFollowPosition(setDialogState);
                  applyHistoryMemoryLimit(setDialogState);
                  applyWindowPointLimit(setDialogState);
                  if (draft.floatingPanelOpacity < 0 ||
                      draft.floatingPanelOpacity > 1 ||
                      draft.followPositionRatio < 0.5 ||
                      draft.followPositionRatio > 0.95 ||
                      draft.historyLimit <
                          ProbePlotViewModel.minHistoryMemoryLimitMiB ||
                      draft.historyLimit >
                          ProbePlotViewModel.maxHistoryMemoryLimitMiB ||
                      draft.windowPointLimit <
                          ProbePlotViewModel.minWindowPointLimit ||
                      draft.windowPointLimit >
                          ProbePlotViewModel.maxWindowPointLimit) {
                    throw FormatException(
                      AppStrings.probe.plotSettingsRangeError,
                    );
                  }
                  await vm.applyPlotSettings(draft);
                  if (mounted && !(draft.previewToolbarEnabled ?? true)) {
                    setState(() => _previewVisible = false);
                  }
                },
                child: SettingsNavigationView(
                  scrollController: settingsScrollController,
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
                      AppSegmentedSelector<PlotBackgroundStyle>(
                        value: draft.background,
                        items: {
                          PlotBackgroundStyle.dark: Text(
                            AppStrings.plot.plotBackgroundDark,
                          ),
                          PlotBackgroundStyle.light: Text(
                            AppStrings.plot.plotBackgroundLight,
                          ),
                        },
                        onChanged:
                            (value) =>
                                setDialogState(() => draft.background = value),
                      ),
                      const SizedBox(height: 8),
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
                              setDialogState(() => draft.showGrid = value);
                            },
                          ),
                        ],
                      ),
                      if (draft.showGrid) ...[
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.plot.gridDensity,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        AppSegmentedSelector<GridDensity>(
                          value: draft.gridDensity,
                          items: {
                            GridDensity.sparse: Text(
                              AppStrings.plot.densitySparse,
                            ),
                            GridDensity.normal: Text(
                              AppStrings.plot.densityNormal,
                            ),
                            GridDensity.dense: Text(
                              AppStrings.plot.densityDense,
                            ),
                          },
                          onChanged:
                              (value) => setDialogState(
                                () => draft.gridDensity = value,
                              ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      AppNumberRow(
                        key: const ValueKey(
                          'probe-floating-panel-opacity-field',
                        ),
                        label: AppStrings.plot.floatingPanelOpacity,
                        controller: opacityController,
                        suffixText: '%',
                        onApply:
                            () => applyFloatingPanelOpacity(setDialogState),
                      ),
                      const Divider(),
                      Text(
                        AppStrings.plot.renderEngine,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      AppSegmentedSelector<PlotRenderEngine>(
                        key: const ValueKey('probePlotRenderEngineSelector'),
                        value: draft.renderEngine ?? PlotRenderEngine.d3d11,
                        items: {
                          PlotRenderEngine.canvas: Text(
                            AppStrings.plot.renderEngineCanvas,
                          ),
                          PlotRenderEngine.d3d11: Text(
                            AppStrings.plot.renderEngineD3d11,
                          ),
                        },
                        onChanged:
                            (value) => setDialogState(
                              () => draft.renderEngine = value,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.renderEngineHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const Divider(),
                      Text(
                        key: performanceSectionKey,
                        AppStrings.plot.lodQuality,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      AppSegmentedSelector<PlotLodQuality>(
                        key: const ValueKey('probe-plot-lod-quality-selector'),
                        value: draft.quality,
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
                            (value) =>
                                setDialogState(() => draft.quality = value),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.lodQualityHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
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
                          setDialogState(
                            () => draft.fontSizeDelta = value.round(),
                          );
                        },
                      ),
                      AppSwitchRow(
                        title: Text(AppStrings.plot.plotFontBold),
                        value: draft.fontBold,
                        onChanged: (value) {
                          setDialogState(() => draft.fontBold = value);
                        },
                      ),
                      Text(
                        AppStrings.plot.plotFontSizeHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const Divider(),
                      Text(
                        key: viewportSectionKey,
                        AppStrings.plot.followPosition,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: kSecondaryDialogFieldWidth,
                        child: AppNumberField(
                          key: const ValueKey('probe-follow-position-field'),
                          controller: followController,
                          suffixText: '%',
                          onSubmitted:
                              (_) => applyFollowPosition(setDialogState),
                          onEditingComplete:
                              () => applyFollowPosition(setDialogState),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.plot.followPositionHelp,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
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
                              setDialogState(
                                () => draft.previewToolbarEnabled = value,
                              );
                            },
                          ),
                        ],
                      ),
                      const Divider(),
                      AppSwitchRow(
                        key: interactionSectionKey,
                        title: Text(AppStrings.plot.observationClickToPlace),
                        subtitle: Text(
                          AppStrings.plot.observationClickToPlaceHelp,
                        ),
                        value: draft.observationClickToPlace,
                        onChanged: (value) {
                          setDialogState(
                            () => draft.observationClickToPlace = value,
                          );
                        },
                      ),
                      const Divider(),
                      Text(
                        key: dataSectionKey,
                        AppStrings.plot.plotHistoryMemoryLimit,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: kSecondaryDialogFieldWidth,
                        child: AppNumberField(
                          key: const ValueKey(
                            'probe-history-memory-limit-field',
                          ),
                          controller: memoryController,
                          suffixText: 'MiB',
                          onSubmitted:
                              (_) => applyHistoryMemoryLimit(setDialogState),
                          onEditingComplete:
                              () => applyHistoryMemoryLimit(setDialogState),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.probe.historyMemoryLimitHelp(
                          min: ProbePlotViewModel.minHistoryMemoryLimitMiB,
                          max: ProbePlotViewModel.maxHistoryMemoryLimitMiB,
                          currentBytes: formatByteSize(
                            vm.estimatedHistoryBytes,
                          ),
                        ),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.probe.windowPointLimitLabel,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: kSecondaryDialogFieldWidth,
                        child: AppNumberField(
                          key: const ValueKey('probe-window-point-limit-field'),
                          controller: windowController,
                          suffixText: AppStrings.probe.pointUnit,
                          onSubmitted:
                              (_) => applyWindowPointLimit(setDialogState),
                          onEditingComplete:
                              () => applyWindowPointLimit(setDialogState),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.probe.windowPointLimitHelp(
                          min: ProbePlotViewModel.minWindowPointLimit,
                          max: ProbePlotViewModel.maxWindowPointLimit,
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
    );
    disposeAfterDialogTransition(() {
      windowController.dispose();
      memoryController.dispose();
      opacityController.dispose();
      followController.dispose();
      settingsScrollController.dispose();
    });
  }
}

class _ProbeRttDataConfigDialog extends StatefulWidget {
  const _ProbeRttDataConfigDialog({required this.vm});

  final ProbePlotViewModel vm;

  @override
  State<_ProbeRttDataConfigDialog> createState() =>
      _ProbeRttDataConfigDialogState();
}

class _ProbeRttDataConfigDialogState extends State<_ProbeRttDataConfigDialog> {
  late final TextEditingController _channel;
  late final TextEditingController _format;
  late final TextEditingController _address;
  late final TextEditingController _rangeStart;
  late final TextEditingController _rangeEnd;
  late final TextEditingController _pollingInterval;
  late RttControlBlockMode _mode;
  String? _error;
  bool _refreshing = false;

  bool get _supportsAutomatic =>
      widget.vm.service.supportsAutomaticControlBlock;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _channel = TextEditingController(text: widget.vm.rttChannelName);
    _format = TextEditingController(text: widget.vm.rttFormat);
    _mode = RttControlBlockMode.fromString(settings.rttControlBlockMode);
    if (!_supportsAutomatic && _mode == RttControlBlockMode.automatic) {
      _mode = RttControlBlockMode.address;
    }
    _address = TextEditingController(
      text: _formatRttAddress(settings.rttControlBlockAddress),
    );
    _rangeStart = TextEditingController(
      text: _formatRttAddress(settings.rttControlBlockRangeStart),
    );
    _rangeEnd = TextEditingController(
      text: _formatRttAddress(settings.rttControlBlockRangeEnd),
    );
    _pollingInterval = TextEditingController(
      text: '${settings.probeRttPollingIntervalMs}',
    );
  }

  @override
  void dispose() {
    _channel.dispose();
    _format.dispose();
    _address.dispose();
    _rangeStart.dispose();
    _rangeEnd.dispose();
    _pollingInterval.dispose();
    super.dispose();
  }

  Future<void> _refreshChannels() async {
    setState(() => _refreshing = true);
    try {
      if (!_saveControlBlock()) return;
      await widget.vm.refreshRttChannels();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  bool _saveControlBlock() {
    final address = _parseRttAddress(_address.text);
    final start = _parseRttAddress(_rangeStart.text);
    final end = _parseRttAddress(_rangeEnd.text);
    final pollingInterval = int.tryParse(_pollingInterval.text);
    if (_mode == RttControlBlockMode.address &&
        (address == null || address < 0)) {
      setState(() => _error = AppStrings.probe.invalidControlBlockAddress);
      return false;
    }
    if (_mode == RttControlBlockMode.range &&
        (start == null || start < 0 || end == null || end <= start)) {
      setState(() => _error = AppStrings.probe.rangeEndMustExceedStart);
      return false;
    }
    if (pollingInterval == null ||
        pollingInterval < RttConfiguration.minPollingIntervalMs ||
        pollingInterval > RttConfiguration.maxPollingIntervalMs) {
      setState(
        () =>
            _error = AppStrings.probe.pollingIntervalRange(
              min: RttConfiguration.minPollingIntervalMs,
              max: RttConfiguration.maxPollingIntervalMs,
            ),
      );
      return false;
    }
    final settings =
        AppSettings()
          ..rttControlBlockMode = _mode.value
          ..rttControlBlockAddress = address
          ..rttControlBlockRangeStart = start
          ..rttControlBlockRangeEnd = end
          ..probeRttPollingIntervalMs = pollingInterval;
    unawaited(settings.save());
    setState(() => _error = null);
    return true;
  }

  void _submit() {
    if (!_saveControlBlock()) return;
    widget.vm.setRttConfig(channelName: _channel.text, format: _format.text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.vm.rttChannels;
    final selectedExists = channels.any((item) => item.name == _channel.text);
    return AlertDialog(
      title: Text(AppStrings.probe.rttDataConfigTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppLabeledField(
                label: AppStrings.probe.controlBlockPositioning,
                child: NoAnimDropdown<RttControlBlockMode>(
                  key: const ValueKey('probe-rtt-control-block-mode'),
                  value: _mode,
                  hint: AppStrings.probe.controlBlockPositioningHint,
                  decoration: secondaryDialogFieldDecoration(),
                  items:
                      RttControlBlockMode.values
                          .where(
                            (value) =>
                                _supportsAutomatic ||
                                value != RttControlBlockMode.automatic,
                          )
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value.label),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _mode = value);
                  },
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _mode.description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_mode == RttControlBlockMode.address) ...[
                const SizedBox(height: 12),
                AppLabeledField(
                  label: AppStrings.probe.controlBlockAddressLabel,
                  child: TextField(
                    key: const ValueKey('probe-rtt-control-block-address'),
                    controller: _address,
                    decoration: secondaryDialogFieldDecoration(
                      hintText: AppStrings.probe.controlBlockAddressHint,
                    ),
                  ),
                ),
              ],
              if (_mode == RttControlBlockMode.range) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AppLabeledField(
                        label: AppStrings.probe.rangeStartLabel,
                        child: TextField(
                          controller: _rangeStart,
                          decoration: secondaryDialogFieldDecoration(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppLabeledField(
                        label: AppStrings.probe.rangeEndLabel,
                        child: TextField(
                          controller: _rangeEnd,
                          decoration: secondaryDialogFieldDecoration(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              AppLabeledField(
                label: AppStrings.probe.pollingIntervalLabel,
                child: AppNumberField(
                  key: const ValueKey('probe-rtt-polling-interval'),
                  controller: _pollingInterval,
                  suffixText: 'ms',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppStrings.probe.rttPollingIntervalHelp,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Divider(height: 28),
              Row(
                children: [
                  Text(AppStrings.probe.rttUpChannel),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('probe-rtt-refresh-channels'),
                    tooltip: AppStrings.probe.refreshRttUpChannels,
                    onPressed: _refreshing ? null : _refreshChannels,
                    icon:
                        _refreshing
                            ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (channels.isNotEmpty)
                AppLabeledField(
                  label: AppStrings.probe.rttUpChannel,
                  child: AppDropdown<String>(
                    value: selectedExists ? _channel.text : null,
                    hint: AppStrings.probe.rttUpChannel,
                    decoration: secondaryDialogFieldDecoration(),
                    items: [
                      for (final channel in channels)
                        DropdownMenuItem(
                          value: channel.name,
                          child: Text('Up ${channel.index}  ${channel.name}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _channel.text = value;
                      if (JScopeFormat.tryParse(value) != null) {
                        _format.text = value;
                      }
                    },
                  ),
                )
              else
                AppLabeledField(
                  label: AppStrings.probe.rttUpChannelName,
                  child: TextField(
                    controller: _channel,
                    decoration: secondaryDialogFieldDecoration(),
                  ),
                ),
              const SizedBox(height: 12),
              AppLabeledField(
                label: AppStrings.probe.jScopeDataFormat,
                child: TextField(
                  controller: _format,
                  decoration: secondaryDialogFieldDecoration().copyWith(
                    helperText: AppStrings.probe.jScopeDataFormatHelp,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(AppStrings.common.confirm),
        ),
      ],
    );
  }
}

int? _parseRttAddress(String value) {
  final text = value.trim();
  final hex = text.startsWith('0x') || text.startsWith('0X');
  return int.tryParse(hex ? text.substring(2) : text, radix: hex ? 16 : 10);
}

String _formatRttAddress(int? value) =>
    value == null ? '' : '0x${value.toRadixString(16)}';

class _ProbeCursorJumpDialog extends StatefulWidget {
  const _ProbeCursorJumpDialog({
    required this.minX,
    required this.maxX,
    required this.initialIndex,
  });

  final int minX;
  final int maxX;
  final int initialIndex;

  @override
  State<_ProbeCursorJumpDialog> createState() => _ProbeCursorJumpDialogState();
}

class _ProbeCursorJumpDialogState extends State<_ProbeCursorJumpDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialIndex.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final index = int.tryParse(_controller.text.trim());
    if (index == null) {
      setState(() => _errorText = AppStrings.probe.invalidPacketIndex);
      return;
    }
    if (index < widget.minX || index > widget.maxX) {
      setState(
        () =>
            _errorText = AppStrings.probe.packetIndexRange(
              min: widget.minX,
              max: widget.maxX,
            ),
      );
      return;
    }
    Navigator.of(context).pop(index);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppStrings.probe.jumpToPacketIndexTitle),
      content: SizedBox(
        width: 260,
        child: AppDialogTextField(
          key: const ValueKey('probe-cursor-jump-input'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          labelText: AppStrings.probe.packetIndexLabel,
          helperText: AppStrings.probe.packetIndexHelper(
            min: widget.minX,
            max: widget.maxX,
          ),
          errorText: _errorText,
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(AppStrings.probe.jump)),
      ],
    );
  }
}

class _HssConfigContent extends StatefulWidget {
  const _HssConfigContent({required this.vm});
  final ProbePlotViewModel vm;

  @override
  State<_HssConfigContent> createState() => _HssConfigContentState();
}

class _HssConfigContentState extends State<_HssConfigContent> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _symbolSearch = TextEditingController();
  late final TextEditingController _frequency = TextEditingController(
    text: '${widget.vm.hssFrequencyHz}',
  );
  ProbeScalarType _type = ProbeScalarType.uint32;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _symbolSearch.dispose();
    _frequency.dispose();
    super.dispose();
  }

  Future<void> _chooseProgram() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['elf', 'axf', 'out'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      await widget.vm.loadProgram(path);
      if (mounted) {
        setState(_symbolSearch.clear);
      }
    } catch (error) {
      AppNotifications.show('程序文件读取失败: $error');
    }
  }

  ProbeScalarType _symbolType(ProbeSymbolInfo symbol) =>
      symbol.type ??
      switch (symbol.size) {
        1 => ProbeScalarType.uint8,
        2 => ProbeScalarType.uint16,
        8 => ProbeScalarType.uint64,
        _ => ProbeScalarType.uint32,
      };

  void _addSymbol(ProbeSymbolInfo symbol) {
    try {
      widget.vm.addHssVariable(
        ProbeSampleVariable(
          name: symbol.name,
          address: symbol.address,
          type: _symbolType(symbol),
        ),
      );
      setState(() {});
    } catch (error) {
      AppNotifications.show('$error');
    }
  }

  void _add() {
    final normalized = _address.text.trim().toLowerCase();
    final address = int.tryParse(
      normalized.startsWith('0x') ? normalized.substring(2) : normalized,
      radix: 16,
    );
    if (address == null) {
      AppNotifications.show('请输入有效的十六进制地址');
      return;
    }
    widget.vm.addHssVariable(
      ProbeSampleVariable(
        name:
            _name.text.trim().isEmpty
                ? '0x${address.toRadixString(16)}'
                : _name.text.trim(),
        address: address,
        type: _type,
      ),
    );
    setState(() {
      _name.clear();
      _address.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppStrings.probe.hssIntro),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.vm.programPath.isEmpty
                      ? AppStrings.probe.noProgramFile
                      : widget.vm.programPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _chooseProgram,
                icon: const Icon(Icons.folder_open),
                label: Text(AppStrings.probe.chooseProgramFile),
              ),
            ],
          ),
          _HssLabeledControl(
            label: AppStrings.probe.samplingRateLabel,
            child: SecondaryDialogTextField(
              key: const ValueKey('hss-frequency-field'),
              controller: _frequency,
              keyboardType: TextInputType.number,
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed != null) widget.vm.setHssFrequency(parsed);
              },
            ),
          ),
          if (widget.vm.symbols.isNotEmpty) ...[
            const SizedBox(height: 10),
            _HssLabeledControl(
              label: AppStrings.probe.searchElfVariables,
              child: SecondaryDialogTextField(
                key: const ValueKey('hss-symbol-search'),
                controller: _symbolSearch,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon:
                    _symbolSearch.text.isEmpty
                        ? null
                        : AppFieldIconButton(
                          tooltip: AppStrings.probe.clearSearch,
                          onPressed: () {
                            setState(_symbolSearch.clear);
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.probe.recognizedSymbolsCount(widget.vm.symbols.length),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 220,
              child: Builder(
                builder: (context) {
                  final keyword = _symbolSearch.text.trim().toLowerCase();
                  final matches = widget.vm.symbols
                      .where(
                        (symbol) =>
                            keyword.isEmpty ||
                            symbol.name.toLowerCase().contains(keyword),
                      )
                      .take(500)
                      .toList(growable: false);
                  if (matches.isEmpty) {
                    return Center(
                      child: Text(AppStrings.probe.noMatchingVariable),
                    );
                  }
                  return ListView.builder(
                    key: const ValueKey('hss-symbol-list'),
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final symbol = matches[index];
                      final selected = widget.vm.hssVariables.any(
                        (item) => item.address == symbol.address,
                      );
                      return ListTile(
                        dense: true,
                        title: Text(symbol.name),
                        subtitle: Text(
                          '0x${symbol.address.toRadixString(16)}  '
                          '${_symbolType(symbol).label}  ${symbol.size} bytes',
                        ),
                        trailing:
                            selected
                                ? const Icon(Icons.check, color: Colors.green)
                                : const Icon(Icons.add),
                        enabled: !selected,
                        onTap: selected ? null : () => _addSymbol(symbol),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(),
            Text(AppStrings.probe.manualAddAddress),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _HssLabeledControl(
                  label: AppStrings.probe.variableName,
                  child: SecondaryDialogTextField(
                    key: const ValueKey('hss-name-field'),
                    controller: _name,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HssLabeledControl(
                  label: AppStrings.probe.addressHex,
                  child: SecondaryDialogTextField(
                    key: const ValueKey('hss-address-field'),
                    controller: _address,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: _HssLabeledControl(
                  label: AppStrings.plot.dataType,
                  child: SecondaryDialogDropdown<ProbeScalarType>(
                    key: const ValueKey('hss-type-dropdown'),
                    value: _type,
                    items: [
                      for (final type in ProbeScalarType.values)
                        DropdownMenuItem(value: type, child: Text(type.label)),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _type = value);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: kSecondaryDialogControlHeight,
                height: kSecondaryDialogControlHeight,
                child: IconButton(
                  tooltip: AppStrings.probe.addVariable,
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
          for (var index = 0; index < widget.vm.hssVariables.length; index++)
            ListTile(
              dense: true,
              title: Text(widget.vm.hssVariables[index].name),
              subtitle: Text(
                '0x${widget.vm.hssVariables[index].address.toRadixString(16)}  '
                '${widget.vm.hssVariables[index].type.byteSize} bytes',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 110,
                    child: SecondaryDialogDropdown<ProbeScalarType>(
                      value: widget.vm.hssVariables[index].type,
                      items: [
                        for (final type in ProbeScalarType.values)
                          DropdownMenuItem(
                            value: type,
                            child: Text(type.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        widget.vm.setHssVariableType(index, value);
                        setState(() {});
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: AppStrings.probe.removeVariable,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      widget.vm.removeHssVariable(index);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HssLabeledControl extends StatelessWidget {
  const _HssLabeledControl({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
