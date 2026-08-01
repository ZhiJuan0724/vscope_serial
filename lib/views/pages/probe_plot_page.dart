import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/constants/rtt_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../core/utils/plot_value_formatter.dart';
import '../../data/models/plot_lod_index.dart';
import '../../data/models/probe_plot_config.dart';
import '../../data/models/probe_connection_config.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/j_scope_rtt_parser.dart';
import '../../viewmodels/probe_plot_viewmodel.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_viewport.dart';
import '../widgets/app_icon.dart';
import '../widgets/common_widgets.dart';

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
  bool _cursorJumpDialogOpen = false;

  Future<void> _toggle(ProbePlotViewModel vm) async {
    try {
      vm.running ? await vm.stop() : await vm.start();
    } catch (error) {
      AppNotifications.show('探针绘图操作失败: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProbePlotViewModel>(
      builder:
          (context, vm, _) => Column(
            children: [
              UnifiedToolbar(
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
                              ? (vm.running ? '停止中' : '启动中')
                              : vm.running
                              ? '停止'
                              : '开始',
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
                              borderRadius: BorderRadius.all(
                                Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        segments: [
                          ButtonSegment(
                            value: ProbePlotMode.hss,
                            label: SizedBox(
                              width: 28,
                              child: Center(
                                child: Transform.translate(
                                  offset: Offset(0, -1),
                                  child: Text(
                                    'HSS',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ButtonSegment(
                            value: ProbePlotMode.rtt,
                            label: SizedBox(
                              width: 28,
                              child: Center(
                                child: Transform.translate(
                                  offset: Offset(0, -1),
                                  child: Text(
                                    'RTT',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        selected: {vm.mode},
                        onSelectionChanged:
                            vm.running
                                ? null
                                : (value) => unawaited(
                                  _changeMode(context, vm, value.first),
                                ),
                        showSelectedIcon: false,
                      ),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    child: ToolbarIconButton(
                      key: const ValueKey('probe-source-settings-button'),
                      icon: const Icon(Icons.settings),
                      tooltip: '${vm.mode.label} 数据配置',
                      onPressed:
                          vm.running ? null : () => _showConfig(context, vm),
                    ),
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.settings),
                        label: '${vm.mode.label} 数据配置',
                        onPressed:
                            vm.running ? null : () => _showConfig(context, vm),
                      ),
                    ],
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const AppIcon(AppIcons.plotCursor),
                        label: AppStrings.plot.verticalCursor,
                        selected: vm.vCursorEnabled,
                        onPressed:
                            vm.pointCount == 0
                                ? null
                                : () =>
                                    vm.setVCursorEnabled(!vm.vCursorEnabled),
                      ),
                    ],
                    child: Listener(
                      onPointerDown: (event) {
                        if (event.buttons == kSecondaryMouseButton &&
                            vm.maxJumpPacketIndex != null) {
                          unawaited(_showCursorJumpDialog(context, vm));
                        }
                      },
                      child: ToolbarToggleIconButton(
                        icon: const AppIcon(AppIcons.plotCursor),
                        tooltip: AppStrings.plot.verticalCursor,
                        selected: vm.vCursorEnabled,
                        activeColor: Colors.orange,
                        onPressed:
                            vm.pointCount == 0
                                ? null
                                : () =>
                                    vm.setVCursorEnabled(!vm.vCursorEnabled),
                      ),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.add_location_alt),
                        label: AppStrings.plot.observation,
                        selected: vm.observationPlacementActive,
                        onPressed:
                            vm.pointCount == 0
                                ? null
                                : () => _addObservation(vm),
                      ),
                    ],
                    child: Listener(
                      onPointerDown: (event) {
                        if (event.buttons == kSecondaryMouseButton) {
                          unawaited(_showObservationManager(context, vm));
                        }
                      },
                      child: ToolbarToggleIconButton(
                        icon: const Icon(Icons.add_location_alt),
                        tooltip:
                            vm.observationPlacementActive
                                ? AppStrings.plot.placeObservation
                                : AppStrings.plot.addObservation,
                        selected: vm.observationPlacementActive,
                        activeColor: Colors.amber,
                        onPressed:
                            vm.pointCount == 0
                                ? null
                                : () => _addObservation(vm),
                      ),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const AppIcon(AppIcons.plotMeasureXx),
                        label: AppStrings.plot.measureXx,
                        selected: vm.xMeasurementEnabled,
                        onPressed:
                            vm.pointCount == 0 ? null : vm.toggleXMeasurement,
                      ),
                    ],
                    child: Listener(
                      onPointerDown: (event) {
                        if (event.buttons == kSecondaryMouseButton) {
                          unawaited(
                            _showMeasurementSettings(context, vm, isX: true),
                          );
                        }
                      },
                      child: ToolbarToggleIconButton(
                        icon: const AppIcon(AppIcons.plotMeasureXx),
                        tooltip: AppStrings.plot.measureXxTooltip,
                        selected: vm.xMeasurementEnabled,
                        activeColor: Colors.blue,
                        onPressed:
                            vm.pointCount == 0 ? null : vm.toggleXMeasurement,
                      ),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const AppIcon(AppIcons.plotMeasureYy),
                        label: AppStrings.plot.measureYy,
                        selected: vm.yMeasurementEnabled,
                        onPressed:
                            vm.pointCount == 0 ? null : vm.toggleYMeasurement,
                      ),
                    ],
                    child: Listener(
                      onPointerDown: (event) {
                        if (event.buttons == kSecondaryMouseButton) {
                          unawaited(
                            _showMeasurementSettings(context, vm, isX: false),
                          );
                        }
                      },
                      child: ToolbarToggleIconButton(
                        icon: const AppIcon(AppIcons.plotMeasureYy),
                        tooltip: AppStrings.plot.measureYyTooltip,
                        selected: vm.yMeasurementEnabled,
                        activeColor: Colors.blue,
                        onPressed:
                            vm.pointCount == 0 ? null : vm.toggleYMeasurement,
                      ),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const AppIcon(AppIcons.plotFollow),
                        label: AppStrings.plot.follow,
                        selected: vm.follow,
                        onPressed: () => vm.setFollow(!vm.follow),
                      ),
                    ],
                    child: ToolbarToggleIconButton(
                      icon: const AppIcon(AppIcons.plotFollow),
                      tooltip: AppStrings.plot.followTooltip,
                      selected: vm.follow,
                      activeColor: Colors.orange,
                      onPressed: () => vm.setFollow(!vm.follow),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.list_alt),
                        label: AppStrings.plot.legend,
                        selected: _legendVisible,
                        onPressed:
                            () => setState(
                              () => _legendVisible = !_legendVisible,
                            ),
                      ),
                    ],
                    child: ToolbarToggleIconButton(
                      icon: const Icon(Icons.list_alt),
                      tooltip: AppStrings.plot.legend,
                      selected: _legendVisible,
                      activeColor: Colors.teal,
                      onPressed:
                          () =>
                              setState(() => _legendVisible = !_legendVisible),
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.format_list_numbered),
                        label: AppStrings.plot.liveValues,
                        selected: _liveValuesVisible,
                        onPressed:
                            () => setState(
                              () => _liveValuesVisible = !_liveValuesVisible,
                            ),
                      ),
                    ],
                    child: ToolbarToggleIconButton(
                      icon: const Icon(Icons.format_list_numbered),
                      tooltip: AppStrings.plot.liveValues,
                      selected: _liveValuesVisible,
                      activeColor: Colors.lightBlue,
                      onPressed:
                          () => setState(
                            () => _liveValuesVisible = !_liveValuesVisible,
                          ),
                    ),
                  ),
                ],
                trailingItems: [
                  for (final action in [
                    (AppIcons.plotZoomXIn, AppStrings.plot.zoomXIn, vm.zoomXIn),
                    (
                      AppIcons.plotZoomXOut,
                      AppStrings.plot.zoomXOut,
                      vm.zoomXOut,
                    ),
                    (AppIcons.plotZoomYIn, AppStrings.plot.zoomYIn, vm.zoomYIn),
                    (
                      AppIcons.plotZoomYOut,
                      AppStrings.plot.zoomYOut,
                      vm.zoomYOut,
                    ),
                  ])
                    ToolbarLayoutItem(
                      extent: kToolbarControlExtent,
                      overflowActions: [
                        ToolbarOverflowAction(
                          icon: AppIcon(action.$1),
                          label: action.$2,
                          onPressed: vm.pointCount == 0 ? null : action.$3,
                        ),
                      ],
                      child: ToolbarIconButton(
                        icon: AppIcon(action.$1),
                        tooltip: action.$2,
                        onPressed: vm.pointCount == 0 ? null : action.$3,
                      ),
                    ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.clear),
                        label: AppStrings.plot.clearData,
                        onPressed: vm.pointCount == 0 ? null : vm.clear,
                      ),
                    ],
                    child: ToolbarIconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: AppStrings.plot.clearData,
                      onPressed: vm.pointCount == 0 ? null : vm.clear,
                    ),
                  ),
                  ToolbarLayoutItem(
                    extent: kToolbarControlExtent,
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.tune),
                        label: '探针绘图设置',
                        onPressed: () => _showPlotSettings(context, vm),
                      ),
                    ],
                    child: ToolbarAdvancedSettingsButton(
                      tooltip: '探针绘图设置',
                      onPressed: () => _showPlotSettings(context, vm),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Row(
                  children: [
                    _buildChannelPanel(context, vm),
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
                                final plotSurface =
                                    vm.pointCount == 0
                                        ? const Center(child: Text('暂无探针采样数据'))
                                        : Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            for (final layer in [
                                              PlotPaintLayer.background,
                                              PlotPaintLayer.data,
                                              PlotPaintLayer.axis,
                                              PlotPaintLayer.overlay,
                                            ])
                                              CustomPaint(
                                                painter: PlotLayerPainter(
                                                  layer: layer,
                                                  viewport: renderViewport,
                                                  data: plotPoints,
                                                  dataRevision: vm.dataRevision,
                                                  viewportRevision:
                                                      vm.viewportRevision,
                                                  channelConfigRevision:
                                                      vm.channelConfigRevision,
                                                  overlayRevision:
                                                      vm.overlayRevision,
                                                  lodIndex: vm.lodIndex,
                                                  lodQuality: vm.lodQuality,
                                                  channels: vm.channels,
                                                  activeChannelCount:
                                                      vm.activeChannelCount,
                                                  showGrid: vm.showGrid,
                                                  gridDensity: vm.gridDensity,
                                                  backgroundStyle:
                                                      vm.backgroundStyle,
                                                  floatingPanelOpacity:
                                                      vm.floatingPanelOpacity,
                                                  cursor: vm.cursor,
                                                  xCursor1: vm.xCursor1,
                                                  xCursor2: vm.xCursor2,
                                                  yCursor1: vm.yCursor1,
                                                  yCursor2: vm.yCursor2,
                                                  xMeasurementLine1Color:
                                                      vm.xMeasurementLine1Color,
                                                  xMeasurementLine2Color:
                                                      vm.xMeasurementLine2Color,
                                                  yMeasurementLine1Color:
                                                      vm.yMeasurementLine1Color,
                                                  yMeasurementLine2Color:
                                                      vm.yMeasurementLine2Color,
                                                  xMeasurementLine1Opacity:
                                                      vm.xMeasurementLine1Opacity,
                                                  xMeasurementLine2Opacity:
                                                      vm.xMeasurementLine2Opacity,
                                                  yMeasurementLine1Opacity:
                                                      vm.yMeasurementLine1Opacity,
                                                  yMeasurementLine2Opacity:
                                                      vm.yMeasurementLine2Opacity,
                                                  plotFontSizeDelta:
                                                      vm.plotFontSizeDelta,
                                                  plotFontBold: vm.plotFontBold,
                                                ),
                                              ),
                                          ],
                                        );
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    PlotGestureHandler(
                                      viewport: renderViewport,
                                      channels: vm.channels,
                                      activeChannelCount: vm.activeChannelCount,
                                      data: plotPoints,
                                      vCursorEnabled: vm.vCursorEnabled,
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
                                        child: LayoutBuilder(
                                          builder:
                                              (
                                                context,
                                                overlayConstraints,
                                              ) => Stack(
                                                children:
                                                    _buildObservationWidgets(
                                                      context,
                                                      vm,
                                                      renderViewport,
                                                      Size(
                                                        overlayConstraints
                                                            .maxWidth,
                                                        overlayConstraints
                                                            .maxHeight,
                                                      ),
                                                    ),
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
                child: Text(
                  '${vm.running ? '运行中' : '已停止'}  ${vm.mode.label}  '
                  '点数 ${vm.pointCount}  实际 ${vm.actualRate.toStringAsFixed(1)} Hz  '
                  '内存 ${_formatBytes(vm.estimatedHistoryBytes)} / '
                  '${vm.historyMemoryLimitMiB} MiB'
                  '${vm.retentionLimitReached ? '  已达上限' : ''}',
                  style: kPageStatusBarTextStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
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
              title: const Text('切换探针绘图模式'),
              content: Text(
                '从 ${vm.mode.label} 切换到 ${mode.label} 将清空当前绘图数据，是否继续？',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('清空并切换'),
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
                  onLongPress: () => _renameChannel(context, vm, index),
                  child: CheckboxListTile(
                    dense: true,
                    value: channel.visible,
                    onChanged: (_) => vm.toggleChannel(index),
                    secondary: Container(
                      width: 10,
                      height: 10,
                      color: channel.color,
                    ),
                    title: Text(
                      channel.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
    return _ProbeDraggableInfoBox(
      key: const ValueKey('probe-plot-legend-box'),
      initialRight: 12,
      initialTop: 12,
      borderColor: Colors.teal.withValues(alpha: 0.55),
      opacity: vm.floatingPanelOpacity,
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 96, maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.plot.legend,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            for (final channel in visible)
              Padding(
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
                        channel.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveValuesBox(BuildContext context, ProbePlotViewModel vm) {
    final latest = vm.latestPoint;
    if (latest == null) return const SizedBox.shrink();
    return _ProbeDraggableInfoBox(
      key: const ValueKey('probe-plot-live-values-box'),
      initialRight: 12,
      initialTop: _legendVisible ? 150 : 12,
      borderColor: Colors.lightBlue.withValues(alpha: 0.55),
      opacity: vm.floatingPanelOpacity,
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.plot.liveValues,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            for (
              var index = 0;
              index < latest.values.length &&
                  index < vm.activeChannelCount &&
                  index < vm.channels.length;
              index++
            )
              if (vm.channels[index].visible)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: vm.channels[index].color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${vm.channels[index].alias}: '
                          '${formatPlotValue(latest.values[index])}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: vm.channels[index].color),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
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
            title: const Text('重命名通道'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '通道名称'),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('确定'),
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
            title: Text('${vm.mode.label} 数据配置'),
            content: SingleChildScrollView(child: _HssConfigContent(vm: vm)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('确定'),
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

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '$bytes B';
  }

  double _plotFontSize(ProbePlotViewModel vm, double base) {
    return (base + 1 + vm.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  Widget _buildMeasurementBox(BuildContext context, ProbePlotViewModel vm) {
    return _ProbeDraggableInfoBox(
      key: const ValueKey('probe-plot-measurement-box'),
      initialRight: 12,
      initialTop: 12,
      borderColor: Colors.blue.withValues(alpha: 0.55),
      opacity: vm.floatingPanelOpacity,
      fontSizeDelta: vm.plotFontSizeDelta,
      fontBold: vm.plotFontBold,
      child: Text(
        vm.measurementText!,
        style: TextStyle(
          fontFamily: 'SarasaUiSC',
          fontSize: _plotFontSize(vm, 12),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
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
                            ? const Center(child: Text('暂无观察'))
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
                                      hintText: '备注',
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
                                        tooltip: '定位',
                                        icon: const Icon(Icons.my_location),
                                        onPressed: () {
                                          vm.jumpToObservation(index);
                                          Navigator.pop(dialogContext);
                                        },
                                      ),
                                      IconButton(
                                        tooltip:
                                            observation.locked ? '解除锁定' : '锁定',
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
                                        tooltip: '删除',
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

  Future<Color?> _chooseMeasurementColor(BuildContext context, Color current) {
    final colors = <Color>[
      Colors.blue,
      Colors.lightBlue,
      Colors.cyan,
      Colors.teal,
      Colors.green,
      Colors.lime,
      Colors.amber,
      Colors.orange,
      Colors.red,
      Colors.pink,
      Colors.purple,
      Colors.white,
      Colors.black,
    ];
    return showDialog<Color>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('选择颜色'),
            content: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in colors)
                  InkWell(
                    onTap: () => Navigator.pop(dialogContext, color),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color:
                              color == current
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey,
                          width: color == current ? 3 : 1,
                        ),
                      ),
                    ),
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
    var line1Color =
        (isX ? vm.xMeasurementLine1Color : vm.yMeasurementLine1Color) ??
        (isX ? Colors.blue : Colors.red);
    var line2Color =
        (isX ? vm.xMeasurementLine2Color : vm.yMeasurementLine2Color) ??
        (isX ? Colors.lightBlue : Colors.purple);
    var line1Opacity =
        isX ? vm.xMeasurementLine1Opacity : vm.yMeasurementLine1Opacity;
    var line2Opacity =
        isX ? vm.xMeasurementLine2Opacity : vm.yMeasurementLine2Opacity;
    var snapEnabled = vm.yMeasurementSnapEnabled;

    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) {
              Widget lineEditor(
                String label,
                Color color,
                double opacity,
                ValueChanged<Color> onColor,
                ValueChanged<double> onOpacity,
              ) {
                return Row(
                  children: [
                    SizedBox(width: 34, child: Text(label)),
                    InkWell(
                      onTap: () async {
                        final selected = await _chooseMeasurementColor(
                          dialogContext,
                          color,
                        );
                        if (selected != null) {
                          setDialogState(() => onColor(selected));
                        }
                      },
                      child: Container(
                        width: 42,
                        height: 24,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey),
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Text('不透明度'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 82,
                      child: TextFormField(
                        initialValue: (opacity * 100).round().toString(),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: secondaryDialogFieldDecoration(
                          suffixText: '%',
                        ),
                        onChanged: (text) {
                          final value = int.tryParse(text);
                          if (value != null) {
                            onOpacity(value.clamp(0, 100) / 100);
                          }
                        },
                      ),
                    ),
                  ],
                );
              }

              return AlertDialog(
                title: Text(isX ? 'Delta X 设置' : 'Delta Y 设置'),
                content: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      lineEditor(
                        isX ? 'X1' : 'Y1',
                        line1Color,
                        line1Opacity,
                        (value) => line1Color = value,
                        (value) => line1Opacity = value,
                      ),
                      const SizedBox(height: 12),
                      lineEditor(
                        isX ? 'X2' : 'Y2',
                        line2Color,
                        line2Opacity,
                        (value) => line2Color = value,
                        (value) => line2Opacity = value,
                      ),
                      if (!isX) ...[
                        const Divider(height: 24),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(AppStrings.plot.measurementSnap),
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
    final interactionSectionKey = GlobalKey();
    final dataSectionKey = GlobalKey();

    void applyWindowPointLimit(StateSetter setDialogState) {
      final value = int.tryParse(windowController.text.trim());
      if (value != null) vm.setWindowPointLimit(value);
      windowController.text = vm.windowPointLimit.toString();
      setDialogState(() {});
    }

    void applyHistoryMemoryLimit(StateSetter setDialogState) {
      final value = int.tryParse(memoryController.text.trim());
      if (value != null) vm.setHistoryMemoryLimitMiB(value);
      memoryController.text = vm.historyMemoryLimitMiB.toString();
      setDialogState(() {});
    }

    void applyFloatingPanelOpacity(StateSetter setDialogState) {
      final percent = int.tryParse(opacityController.text.trim());
      if (percent != null) vm.setFloatingPanelOpacity(percent / 100);
      opacityController.text =
          (vm.floatingPanelOpacity * 100).round().toString();
      setDialogState(() {});
    }

    void applyFollowPosition(StateSetter setDialogState) {
      final percent = int.tryParse(followController.text.trim());
      if (percent != null) vm.setFollowPositionRatio(percent / 100);
      followController.text = (vm.followPositionRatio * 100).round().toString();
      setDialogState(() {});
    }

    Widget buildChoiceButton({
      required String label,
      required bool selected,
      required VoidCallback? onPressed,
    }) {
      return Expanded(
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor:
                selected ? Colors.blue.withValues(alpha: 0.2) : null,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: const Size(0, 32),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.blue : null,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(AppStrings.plot.advancedSettings),
            content: StatefulBuilder(
              builder: (context, setDialogState) {
                return SettingsNavigationView(
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
                      Row(
                        children: [
                          buildChoiceButton(
                            label: AppStrings.plot.plotBackgroundDark,
                            selected:
                                vm.backgroundStyle == PlotBackgroundStyle.dark,
                            onPressed: () {
                              vm.setBackgroundStyle(PlotBackgroundStyle.dark);
                              setDialogState(() {});
                            },
                          ),
                          const SizedBox(width: 8),
                          buildChoiceButton(
                            label: AppStrings.plot.plotBackgroundLight,
                            selected:
                                vm.backgroundStyle == PlotBackgroundStyle.light,
                            onPressed: () {
                              vm.setBackgroundStyle(PlotBackgroundStyle.light);
                              setDialogState(() {});
                            },
                          ),
                        ],
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
                            value: vm.showGrid,
                            onChanged: (value) {
                              vm.setShowGrid(value);
                              setDialogState(() {});
                            },
                          ),
                        ],
                      ),
                      if (vm.showGrid) ...[
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.plot.gridDensity,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            for (final option in GridDensity.values) ...[
                              if (option != GridDensity.values.first)
                                const SizedBox(width: 8),
                              buildChoiceButton(
                                label: switch (option) {
                                  GridDensity.sparse =>
                                    AppStrings.plot.densitySparse,
                                  GridDensity.normal =>
                                    AppStrings.plot.densityNormal,
                                  GridDensity.dense =>
                                    AppStrings.plot.densityDense,
                                },
                                selected: vm.gridDensity == option,
                                onPressed: () {
                                  vm.setGridDensity(option);
                                  setDialogState(() {});
                                },
                              ),
                            ],
                          ],
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
                              key: const ValueKey(
                                'probe-floating-panel-opacity-field',
                              ),
                              controller: opacityController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '%',
                              ),
                              onSubmitted:
                                  (_) =>
                                      applyFloatingPanelOpacity(setDialogState),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed:
                                () => applyFloatingPanelOpacity(setDialogState),
                            child: Text(AppStrings.common.apply),
                          ),
                        ],
                      ),
                      const Divider(),
                      Text(
                        key: performanceSectionKey,
                        AppStrings.plot.lodQuality,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      SegmentedButton<PlotLodQuality>(
                        key: const ValueKey('probe-plot-lod-quality-selector'),
                        expandedInsets: EdgeInsets.zero,
                        segments: [
                          ButtonSegment(
                            value: PlotLodQuality.performance,
                            label: Text(AppStrings.plot.lodQualityPerformance),
                          ),
                          ButtonSegment(
                            value: PlotLodQuality.balanced,
                            label: Text(AppStrings.plot.lodQualityBalanced),
                          ),
                          ButtonSegment(
                            value: PlotLodQuality.quality,
                            label: Text(AppStrings.plot.lodQualityQuality),
                          ),
                        ],
                        selected: {vm.lodQuality},
                        onSelectionChanged: (values) {
                          vm.setLodQuality(values.first);
                          setDialogState(() {});
                        },
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
                            vm.plotFontSizeDelta == 0
                                ? AppStrings.plot.defaultValue
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
                            AppStrings.plot.fontPreview,
                            style: TextStyle(
                              fontSize: _plotFontSize(vm, 14),
                              fontFamily: 'SarasaUiSC',
                              fontWeight:
                                  vm.plotFontBold
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
                        value: vm.plotFontSizeDelta.toDouble(),
                        min: -3,
                        max: 6,
                        divisions: 9,
                        label:
                            vm.plotFontSizeDelta == 0
                                ? AppStrings.plot.defaultValue
                                : vm.plotFontSizeDelta > 0
                                ? '+${vm.plotFontSizeDelta}'
                                : '${vm.plotFontSizeDelta}',
                        onChanged: (value) {
                          vm.setPlotFontSizeDelta(value.round());
                          setDialogState(() {});
                        },
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(AppStrings.plot.plotFontBold),
                        value: vm.plotFontBold,
                        onChanged: (value) {
                          vm.setPlotFontBold(value);
                          setDialogState(() {});
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
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              key: const ValueKey(
                                'probe-follow-position-field',
                              ),
                              controller: followController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '%',
                              ),
                              onSubmitted:
                                  (_) => applyFollowPosition(setDialogState),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed:
                                () => applyFollowPosition(setDialogState),
                            child: Text(AppStrings.common.apply),
                          ),
                        ],
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
                            value: vm.observationClickToPlace,
                            onChanged: (value) {
                              vm.setObservationClickToPlace(value);
                              setDialogState(() {});
                            },
                          ),
                        ],
                      ),
                      const Divider(),
                      Text(
                        key: dataSectionKey,
                        AppStrings.plot.plotHistoryMemoryLimit,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              key: const ValueKey(
                                'probe-history-memory-limit-field',
                              ),
                              controller: memoryController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: 'MiB',
                              ),
                              onSubmitted:
                                  (_) =>
                                      applyHistoryMemoryLimit(setDialogState),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed:
                                () => applyHistoryMemoryLimit(setDialogState),
                            child: Text(AppStrings.common.apply),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '范围：${ProbePlotViewModel.minHistoryMemoryLimitMiB}~'
                        '${ProbePlotViewModel.maxHistoryMemoryLimitMiB} MiB；'
                        '当前估算占用 ${_formatBytes(vm.estimatedHistoryBytes)}。'
                        '达到上限时停止采集并保留已有图像。',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('精确窗口点数上限', style: TextStyle(fontSize: 14)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: kSecondaryDialogFieldWidth,
                            child: TextField(
                              key: const ValueKey(
                                'probe-window-point-limit-field',
                              ),
                              controller: windowController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: secondaryDialogFieldDecoration(
                                suffixText: '点',
                              ),
                              onSubmitted:
                                  (_) => applyWindowPointLimit(setDialogState),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed:
                                () => applyWindowPointLimit(setDialogState),
                            child: Text(AppStrings.common.apply),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '范围：${ProbePlotViewModel.minWindowPointLimit}~'
                        '${ProbePlotViewModel.maxWindowPointLimit} 点；'
                        '仅限制主图保留的精确点窗口，LOD 历史继续保留。',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(AppStrings.common.close),
              ),
            ],
          ),
    );
    windowController.dispose();
    memoryController.dispose();
    opacityController.dispose();
    followController.dispose();
    settingsScrollController.dispose();
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
      setState(() => _error = '请输入有效的 RTT 控制块地址');
      return false;
    }
    if (_mode == RttControlBlockMode.range &&
        (start == null || start < 0 || end == null || end <= start)) {
      setState(() => _error = '搜索结束地址必须大于起始地址');
      return false;
    }
    if (pollingInterval == null ||
        pollingInterval < RttConfiguration.minPollingIntervalMs ||
        pollingInterval > RttConfiguration.maxPollingIntervalMs) {
      setState(
        () =>
            _error =
                'RTT 轮询间隔必须为 '
                '${RttConfiguration.minPollingIntervalMs}～'
                '${RttConfiguration.maxPollingIntervalMs} ms',
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
      title: const Text('RTT 数据配置'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoAnimDropdown<RttControlBlockMode>(
                key: const ValueKey('probe-rtt-control-block-mode'),
                value: _mode,
                hint: '控制块定位',
                decoration: secondaryDialogFieldDecoration(
                  labelText: 'RTT 控制块定位',
                ),
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
              const SizedBox(height: 6),
              Text(
                _mode.description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_mode == RttControlBlockMode.address) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('probe-rtt-control-block-address'),
                  controller: _address,
                  decoration: secondaryDialogFieldDecoration(
                    labelText: 'RTT 控制块地址',
                    hintText: '例如 0x20000410',
                  ),
                ),
              ],
              if (_mode == RttControlBlockMode.range) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _rangeStart,
                        decoration: secondaryDialogFieldDecoration(
                          labelText: '搜索起始地址',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _rangeEnd,
                        decoration: secondaryDialogFieldDecoration(
                          labelText: '搜索结束地址',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('probe-rtt-polling-interval'),
                controller: _pollingInterval,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: secondaryDialogFieldDecoration(
                  labelText: 'RTT 轮询间隔',
                  suffixText: 'ms',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '仅 OpenOCD RTT 绘图使用；HSS 不使用此参数。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Divider(height: 28),
              Row(
                children: [
                  const Text('RTT Up 通道'),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('probe-rtt-refresh-channels'),
                    tooltip: '重新识别 RTT Up 通道',
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
                DropdownButtonFormField<String>(
                  initialValue: selectedExists ? _channel.text : null,
                  decoration: secondaryDialogFieldDecoration(
                    labelText: 'RTT Up 通道',
                  ),
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
                )
              else
                TextField(
                  controller: _channel,
                  decoration: secondaryDialogFieldDecoration(
                    labelText: 'RTT Up 通道名称',
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _format,
                decoration: secondaryDialogFieldDecoration(
                  labelText: 'J-Scope 数据格式',
                ).copyWith(helperText: '通道名含 JScope_i4u4 时自动识别；普通名称请手动输入 i4u4'),
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
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
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
      setState(() => _errorText = '请输入整数包序号');
      return;
    }
    if (index < widget.minX || index > widget.maxX) {
      setState(() => _errorText = '包序号范围应为 ${widget.minX}-${widget.maxX}');
      return;
    }
    Navigator.of(context).pop(index);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳转到包序号 X'),
      content: SizedBox(
        width: 260,
        child: TextField(
          key: const ValueKey('probe-cursor-jump-input'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'X（包序号）',
            helperText: '范围: ${widget.minX}-${widget.maxX}',
            errorText: _errorText,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('跳转')),
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
        setState(() {
          _symbolSearch.clear();
        });
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
          const Text('HSS 使用 OpenOCD 运行态只读内存采样，不会暂停或复位目标。'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.vm.programPath.isEmpty
                      ? '未选择程序文件'
                      : widget.vm.programPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _chooseProgram,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择 ELF/AXF/OUT'),
              ),
            ],
          ),
          _HssLabeledControl(
            label: '采样率（1～5000 Hz）',
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
              label: '搜索 ELF 变量',
              child: SecondaryDialogTextField(
                key: const ValueKey('hss-symbol-search'),
                controller: _symbolSearch,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon:
                    _symbolSearch.text.isEmpty
                        ? null
                        : IconButton(
                          tooltip: '清空搜索',
                          onPressed: () {
                            setState(() => _symbolSearch.clear());
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '已识别 ${widget.vm.symbols.length} 个数据变量，单击即可加入 HSS 通道',
              style: TextStyle(fontSize: 11, color: Colors.grey),
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
                    return const Center(child: Text('没有匹配的变量'));
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
            const Text('手动添加地址'),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _HssLabeledControl(
                  label: '变量名称',
                  child: SecondaryDialogTextField(
                    key: const ValueKey('hss-name-field'),
                    controller: _name,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HssLabeledControl(
                  label: '地址（HEX）',
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
                  label: '数据类型',
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
                  tooltip: '添加变量',
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
                    tooltip: '移除变量',
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

class _ProbeDraggableInfoBox extends StatefulWidget {
  const _ProbeDraggableInfoBox({
    super.key,
    required this.initialRight,
    required this.initialTop,
    required this.borderColor,
    required this.opacity,
    required this.fontSizeDelta,
    required this.fontBold,
    required this.child,
  });

  final double initialRight;
  final double initialTop;
  final Color borderColor;
  final double opacity;
  final int fontSizeDelta;
  final bool fontBold;
  final Widget child;

  @override
  State<_ProbeDraggableInfoBox> createState() => _ProbeDraggableInfoBoxState();
}

class _ProbeDraggableInfoBoxState extends State<_ProbeDraggableInfoBox> {
  double? _right;
  double? _top;
  Offset? _dragStart;
  double? _dragStartRight;
  double? _dragStartTop;

  @override
  Widget build(BuildContext context) {
    final right = _right ?? widget.initialRight;
    final top = _top ?? widget.initialTop;
    return Positioned(
      right: right,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          _dragStart = details.globalPosition;
          _dragStartRight = right;
          _dragStartTop = top;
        },
        onPanUpdate: (details) {
          final start = _dragStart;
          if (start == null) return;
          setState(() {
            _right = (_dragStartRight! + start.dx - details.globalPosition.dx)
                .clamp(0, double.infinity);
            _top = (_dragStartTop! + details.globalPosition.dy - start.dy)
                .clamp(0, double.infinity);
          });
        },
        onPanEnd: (_) => _dragStart = null,
        onPanCancel: () => _dragStart = null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: widget.opacity),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: widget.borderColor),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: (13 + widget.fontSizeDelta).clamp(7, 25).toDouble(),
              fontWeight: widget.fontBold ? FontWeight.bold : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
