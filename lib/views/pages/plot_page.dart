import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/crc.dart';
import '../../core/utils/plot_value_formatter.dart';
import '../../core/utils/plot_performance_metrics.dart';
import '../../core/localization/app_strings.dart';
import '../../data/models/channel_config.dart';
import '../../data/models/math_channel_config.dart';
import '../../data/models/address_config_profile.dart';
import '../../data/models/parser_config.dart';
import '../../services/app_settings.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../dialogs/address_profile_dialog.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_viewport.dart';
import '../widgets/app_icon.dart';
import '../widgets/common_widgets.dart';
import '../widgets/plot_status_bar.dart';

part 'plot_page/plot_file_widgets.dart';
part 'plot_page/plot_channel_widgets.dart';
part 'plot_page/plot_parser_config_dialog.dart';
part 'plot_page/plot_overlay_widgets.dart';
part 'plot_page/plot_preset_selector_dialog.dart';

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
const double kMinChannelPanelWidth = 260;
const double kCompactChannelPanelWidth = 212;
const double kMaxChannelPanelWidth = 400;
const double kDefaultChannelPanelWidth = 260;
const double kCollapsedPanelWidth = 26;
const double kRProtocolAddressWidth = 108;
const double kRProtocolAddressMinWidth = 54;
const double kRProtocolAddressMaxWidth = 112;
const double kFixedFrameConfigLabelWidth = 72;
const double kDataTypeDropdownWidth = 148;
const double kChannelPanelHorizontalPadding = 6;
const double kChannelPanelListRightPadding = 12;

typedef _PlotToolbarSelection =
    ({
      bool isPlotting,
      bool isStopping,
      bool hasData,
      ParserType parserType,
      bool useRandomSource,
      double randomFrequency,
      bool canUndoZoom,
      bool vCursorEnabled,
      bool observationPlacementActive,
      bool boxZoomEnabled,
      bool xMeasurementEnabled,
      bool yMeasurementEnabled,
      bool statsToolbarEnabled,
      bool statsEnabled,
      bool statsRangeEnabled,
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
      String plotBackground,
      double floatingPanelOpacity,
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
  /// 面板是否折叠
  bool _isPanelCollapsed = false;

  /// 面板宽度（展开时）
  double _panelWidth = kDefaultChannelPanelWidth;

  /// 是否正在拖动调整宽度
  bool _isResizing = false;

  /// 是否显示悬浮图例
  bool _legendVisible = false;

  /// 是否显示最新通道值浮窗
  bool _liveValuesVisible = false;

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
      isStopping: vm.isStopping,
      hasData: vm.dataPoints.isNotEmpty,
      parserType: vm.parserType,
      useRandomSource: vm.useRandomSource,
      randomFrequency: vm.randomFrequency,
      canUndoZoom: vm.canUndoZoom,
      vCursorEnabled: vm.vCursorEnabled,
      observationPlacementActive: vm.observationPlacementActive,
      boxZoomEnabled: vm.boxZoomEnabled,
      xMeasurementEnabled: vm.xMeasurementEnabled,
      yMeasurementEnabled: vm.yMeasurementEnabled,
      statsToolbarEnabled: vm.statsToolbarEnabled,
      statsEnabled: vm.statsEnabled,
      statsRangeEnabled: vm.statsRangeEnabled,
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
      plotBackground: vm.plotBackground,
      floatingPanelOpacity: vm.floatingPanelOpacity,
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
          width: _panelWidth.clamp(minPanelWidth, kMaxChannelPanelWidth),
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

  double _minimumChannelPanelWidth(PlotViewModel vm) {
    if (vm.effectiveSendProtocolType == SendProtocolType.rProtocol) {
      return kCompactChannelPanelWidth;
    }
    if (vm.parserType != ParserType.zobow) return kMinChannelPanelWidth;
    final channelCount = vm.parserConfig.zobowChannelCount;
    final allShort = vm.parserConfig.zobowChannelIds
        .take(channelCount)
        .every((address) => (address & 0xFFFF0000) == 0);
    return allShort ? kCompactChannelPanelWidth : kMinChannelPanelWidth;
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
        if (i > 0) const SizedBox(width: 8),
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
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: _withToolbarSpacing([
                        // 文件工具组
                        _buildFileTools(context, vm),
                        // 清空 + 高级设置
                        _buildClearAndSettings(context, vm),
                      ]),
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

  /// 构建第二栏工具栏（光标+缩放）
  Widget _buildSecondaryToolbar(BuildContext context, PlotViewModel vm) {
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.secondaryToolbarBuild,
    );
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 光标和测量工具组
                  _buildCursorTools(context, vm),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _withToolbarSpacing([
                      // 缩放和框选工具组
                      _buildZoomTools(context, vm),
                      // 自适应工具组
                      _buildFitTools(context, vm),
                    ]),
                  ),
                ],
              ),
            ),
          );
        },
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
                  unawaited(vm.startPlotting());
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
            ? AppStrings.plot.stopping
            : vm.isPlotting
            ? AppStrings.plot.stop
            : AppStrings.plot.start,
        style: const TextStyle(fontFamily: 'SarasaUiSC'),
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
    final canChangeSource = !vm.isPlotting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          key: const ValueKey('plot-random-source-checkbox'),
          value: vm.useRandomSource,
          onChanged:
              canChangeSource ? (value) => vm.setUseRandomSource(value!) : null,
        ),
        Text(
          AppStrings.plot.randomSource,
          style: const TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
        ),
        Tooltip(
          message: AppStrings.plot.randomSourceFrequencyTooltip(
            vm.randomFrequency,
          ),
          child: InkWell(
            key: const ValueKey('plot-random-frequency-button'),
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

  /// 收发协议选择 + 配置按钮 + 地址配置文件选择
  Widget _buildParserSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration = !vm.isPlotting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          child: NoAnimDropdown<ParserType>(
            key: const ValueKey('plot-parser-selector'),
            value: vm.parserType,
            hint: AppStrings.plot.receiveProtocolHint,
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
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('plot-parser-config-button'),
          onPressed:
              canChangeConfiguration
                  ? () => _showParserConfigDialog(context, vm)
                  : null,
          icon: const Icon(Icons.settings, size: 18),
          tooltip: AppStrings.plot.parserConfig,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 112,
          child: NoAnimDropdown<SendProtocolType>(
            key: const ValueKey('plot-send-protocol-selector'),
            value:
                vm.parserType == ParserType.zobow
                    ? vm.effectiveSendProtocolType
                    : vm.sendProtocolType,
            hint: AppStrings.plot.sendProtocolHint,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              border: OutlineInputBorder(),
            ),
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
        ),
        IconButton(
          key: const ValueKey('send-protocol-config-button'),
          onPressed:
              canChangeConfiguration &&
                      vm.effectiveSendProtocolType == SendProtocolType.rProtocol
                  ? () => _showSendProtocolConfigDialog(context, vm)
                  : null,
          icon: const Icon(Icons.settings, size: 18),
          tooltip: AppStrings.plot.sendProtocolConfig,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        // Zobow模式下显示配置文件下拉框
        if (vm.parserType == ParserType.zobow) ...[
          const SizedBox(width: 8),
          _buildZobowProfileSelector(context, vm),
          // 新建配置按钮
          Tooltip(
            message: AppStrings.plot.createConfig,
            child: InkWell(
              key: const ValueKey('plot-create-zobow-profile-button'),
              onTap:
                  canChangeConfiguration
                      ? () => _showCreateZobowProfileDialog(context, vm)
                      : null,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  Icons.add,
                  size: 16,
                  color:
                      canChangeConfiguration
                          ? null
                          : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
          // 编辑配置按钮
          Tooltip(
            message: AppStrings.plot.editConfig,
            child: InkWell(
              key: const ValueKey('plot-edit-zobow-profile-button'),
              onTap:
                  canChangeConfiguration
                      ? () => _showEditZobowProfileDialog(context, vm)
                      : null,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  Icons.edit,
                  size: 16,
                  color:
                      canChangeConfiguration
                          ? null
                          : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
        ] else if (vm.sendProtocolType == SendProtocolType.rProtocol) ...[
          const SizedBox(width: 8),
          _buildRProfileSelector(context, vm),
          Tooltip(
            message: AppStrings.plot.createRProtocolConfig,
            child: InkWell(
              key: const ValueKey('plot-create-r-profile-button'),
              onTap:
                  canChangeConfiguration
                      ? () => _showCreateRProfileDialog(context, vm)
                      : null,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  Icons.add,
                  size: 16,
                  color:
                      canChangeConfiguration
                          ? null
                          : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
          Tooltip(
            message: AppStrings.plot.editRProtocolConfig,
            child: InkWell(
              key: const ValueKey('plot-edit-r-profile-button'),
              onTap:
                  canChangeConfiguration
                      ? () => _showEditRProfileDialog(context, vm)
                      : null,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  Icons.edit,
                  size: 16,
                  color:
                      canChangeConfiguration
                          ? null
                          : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRProfileSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration = !vm.isPlotting && !vm.isStopping;
    return SizedBox(
      width: 140,
      child: NoAnimDropdown<String?>(
        key: const ValueKey('plot-r-profile-selector'),
        value: vm.selectedRProfileId.isEmpty ? null : vm.selectedRProfileId,
        hint: AppStrings.plot.noConfig,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          border: OutlineInputBorder(),
        ),
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
      ),
    );
  }

  /// Zobow配置文件选择器
  Widget _buildZobowProfileSelector(BuildContext context, PlotViewModel vm) {
    final canChangeConfiguration = !vm.isPlotting && !vm.isStopping;
    return SizedBox(
      width: 140,
      child: NoAnimDropdown<String?>(
        key: const ValueKey('plot-zobow-profile-selector'),
        value:
            vm.selectedZobowProfileId.isEmpty
                ? null
                : vm.selectedZobowProfileId,
        hint: AppStrings.plot.noConfig,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          border: OutlineInputBorder(),
        ),
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
      ),
    );
  }

  /// 光标和测量工具组
  ///
  /// 顺序：垂直光标 | X-X | Y-Y | 跟随
  Widget _buildCursorTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        // 垂直光标开关
        Tooltip(
          message: AppStrings.plot.verticalCursor,
          child: TextButton.icon(
            onPressed: () => vm.setVCursorEnabled(!vm.vCursorEnabled),
            icon: AppIcon(
              AppIcons.plotCursor,
              color: vm.vCursorEnabled ? Colors.orange : null,
            ),
            label: Text(
              AppStrings.plot.cursor,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
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
        Tooltip(
          message:
              vm.observationPlacementActive
                  ? AppStrings.plot.placeObservation
                  : AppStrings.plot.addObservation,
          child: TextButton.icon(
            onPressed: () {
              if (vm.dataPoints.isEmpty) return;
              if (vm.observationClickToPlace) {
                vm.startObservationPlacement();
              } else {
                vm.addObservation();
              }
            },
            icon: Icon(
              Icons.add_location_alt,
              size: 18,
              color: vm.observationPlacementActive ? Colors.amber : null,
            ),
            label: Text(
              AppStrings.plot.observation,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
                color: vm.observationPlacementActive ? Colors.amber : null,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
              backgroundColor:
                  vm.observationPlacementActive
                      ? Colors.amber.withValues(alpha: 0.1)
                      : null,
            ),
          ),
        ),
        // X-X 测量
        Tooltip(
          message: AppStrings.plot.measureXxTooltip,
          child: TextButton.icon(
            onPressed: () => vm.toggleXMeasurement(),
            icon: AppIcon(
              AppIcons.plotMeasureXx,
              color: vm.xMeasurementEnabled ? Colors.blue : null,
            ),
            label: Text(
              AppStrings.plot.measureXx,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
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
          message: AppStrings.plot.measureYyTooltip,
          child: TextButton.icon(
            onPressed: () => vm.toggleYMeasurement(),
            icon: AppIcon(
              AppIcons.plotMeasureYy,
              color: vm.yMeasurementEnabled ? Colors.blue : null,
            ),
            label: Text(
              AppStrings.plot.measureYy,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
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
        if (vm.statsToolbarEnabled || vm.statsEnabled) ...[
          Tooltip(
            message: AppStrings.plot.statsTooltip,
            child: TextButton.icon(
              onPressed: () => vm.toggleStats(),
              icon: Icon(
                Icons.query_stats,
                size: 18,
                color: vm.statsEnabled ? Colors.blue : null,
              ),
              label: Text(
                AppStrings.plot.stats,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'SarasaUiSC',
                  color: vm.statsEnabled ? Colors.blue : null,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                backgroundColor:
                    vm.statsEnabled
                        ? Colors.blue.withValues(alpha: 0.15)
                        : null,
              ),
            ),
          ),
          Tooltip(
            message: AppStrings.plot.statsRangeTooltip,
            child: IconButton(
              onPressed: vm.statsEnabled ? () => vm.toggleStatsRange() : null,
              icon: Icon(
                Icons.swap_horiz,
                size: 18,
                color: vm.statsRangeEnabled ? Colors.blue : null,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              style: IconButton.styleFrom(
                backgroundColor:
                    vm.statsRangeEnabled
                        ? Colors.blue.withValues(alpha: 0.15)
                        : null,
              ),
            ),
          ),
        ],
        // 最新点跟随
        Tooltip(
          message: AppStrings.plot.followTooltip,
          child: TextButton.icon(
            onPressed: () => vm.setFollowEnabled(!vm.followEnabled),
            icon: AppIcon(
              AppIcons.plotFollow,
              color: vm.followEnabled ? Colors.orange : null,
            ),
            label: Text(
              AppStrings.plot.follow,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
                color: vm.followEnabled ? Colors.orange : null,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
              backgroundColor:
                  vm.followEnabled
                      ? Colors.orange.withValues(alpha: 0.1)
                      : null,
            ),
          ),
        ),
        Tooltip(
          message: AppStrings.plot.legend,
          child: TextButton.icon(
            onPressed: () => setState(() => _legendVisible = !_legendVisible),
            icon: Icon(
              Icons.list_alt,
              size: 18,
              color: _legendVisible ? Colors.teal : null,
            ),
            label: Text(
              AppStrings.plot.legend,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
                color: _legendVisible ? Colors.teal : null,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
              backgroundColor:
                  _legendVisible ? Colors.teal.withValues(alpha: 0.12) : null,
            ),
          ),
        ),
        Tooltip(
          message: AppStrings.plot.liveValues,
          child: TextButton.icon(
            onPressed:
                () => setState(() => _liveValuesVisible = !_liveValuesVisible),
            icon: Icon(
              Icons.format_list_numbered,
              size: 18,
              color: _liveValuesVisible ? Colors.lightBlue : null,
            ),
            label: Text(
              AppStrings.plot.liveValues,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'SarasaUiSC',
                color: _liveValuesVisible ? Colors.lightBlue : null,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 28),
              backgroundColor:
                  _liveValuesVisible
                      ? Colors.lightBlue.withValues(alpha: 0.12)
                      : null,
            ),
          ),
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
        // 撤回缩放
        Tooltip(
          message: AppStrings.plot.undoZoom,
          child: IconButton(
            onPressed: vm.canUndoZoom ? () => vm.undoZoom() : null,
            icon: const Icon(Icons.undo, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        // 框选放大
        Tooltip(
          message: AppStrings.plot.boxZoom,
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
        // X 轴放大
        Tooltip(
          message: AppStrings.plot.zoomXIn,
          child: IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomXIn(),
            icon: const AppIcon(AppIcons.plotZoomXIn),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        // X 轴缩小
        Tooltip(
          message: AppStrings.plot.zoomXOut,
          child: IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomXOut(),
            icon: const AppIcon(AppIcons.plotZoomXOut),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        // Y 轴放大
        Tooltip(
          message: AppStrings.plot.zoomYIn,
          child: IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomYIn(),
            icon: const AppIcon(AppIcons.plotZoomYIn),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        // Y 轴缩小
        Tooltip(
          message: AppStrings.plot.zoomYOut,
          child: IconButton(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.zoomYOut(),
            icon: const AppIcon(AppIcons.plotZoomYOut),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
      ]),
    );
  }

  /// 文件工具组
  ///
  /// 顺序：导入数据 | 导出数据
  Widget _buildFileTools(BuildContext context, PlotViewModel vm) {
    final fileOperationsEnabled = !vm.isPlotting && !vm.isStopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        Tooltip(
          message: AppStrings.plot.importDataTooltip,
          child: IconButton(
            key: const ValueKey('plot-import-data-button'),
            onPressed:
                fileOperationsEnabled
                    ? () => _importPlotData(context, vm)
                    : null,
            icon: const AppIcon(AppIcons.plotImport),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        Tooltip(
          message: AppStrings.plot.exportDataTooltip,
          child: IconButton(
            key: const ValueKey('plot-export-data-button'),
            onPressed:
                !fileOperationsEnabled || vm.dataPoints.isEmpty
                    ? null
                    : () => _exportPlotData(context, vm),
            icon: const Icon(Icons.save, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
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
        Tooltip(
          message: AppStrings.plot.fitYTooltip,
          child: IconButton(
            onPressed: () {
              if (vm.dataPoints.isEmpty) return;
              vm.fitYAxis();
            },
            icon: const AppIcon(AppIcons.plotFitY),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        Tooltip(
          message: AppStrings.plot.fitXTooltip,
          child: IconButton(
            onPressed: () {
              if (vm.dataPoints.isEmpty) return;
              vm.fitXAxis();
            },
            icon: const AppIcon(AppIcons.plotFitX),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        Tooltip(
          message: AppStrings.plot.fitAll,
          child: IconButton(
            onPressed: () {
              if (vm.dataPoints.isEmpty) return;
              vm.fitAll();
            },
            icon: const AppIcon(AppIcons.plotFitAll),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
      ]),
    );
  }

  /// 清空 + 高级设置
  Widget _buildClearAndSettings(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _withToolbarSpacing([
        IconButton(
          onPressed: vm.dataPoints.isEmpty ? null : () => vm.clearData(),
          icon: const Icon(Icons.clear, size: 18),
          tooltip: AppStrings.plot.clearData,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        Tooltip(
          message: AppStrings.common.advancedSettings,
          child: IconButton(
            onPressed: () => _showAdvancedSettingsDialog(context, vm),
            icon: const Icon(Icons.tune, size: 18),
            tooltip: AppStrings.common.advancedSettings,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
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
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.only(
              left: kChannelPanelHorizontalPadding,
              right:
                  kChannelPanelHorizontalPadding +
                  kChannelPanelListRightPadding,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                  right: kChannelPanelListRightPadding,
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
    if (vm.isPlotting || vm.isStopping) {
      vm.showStatusMessage(AppStrings.plot.resetAllChannelsStoppedOnly);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.resetAllChannelsTitle),
            content: SizedBox(
              width: 420,
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
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.plotAreaBuild,
    );
    if (vm.dataPoints.isEmpty) {
      return ColoredBox(
        key: const ValueKey('plot-empty-background'),
        color: _plotBackgroundColor(vm.plotBackground),
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
        final offsetAxisColumnWidths =
            PlotLayerPainter.calculateOffsetAxisColumnWidths(
              viewport: vm.viewport,
              channels: displayChannels,
              activeChannelCount: activeChannelCount,
              canvasHeight: constraints.maxHeight,
              gridDensity: gridDensity,
              plotFontSizeDelta: vm.plotFontSizeDelta.toDouble(),
              yValuesAreInteger: vm.displayYValuesAreInteger,
            );
        final renderViewport =
            vm.viewport.copy()
              ..setOffsetAxisColumnWidths(offsetAxisColumnWidths);

        PlotLayerPainter createPainter(PlotPaintLayer layer) {
          return PlotLayerPainter(
            layer: layer,
            viewport: renderViewport,
            data: displayDataPoints,
            dataRevision: vm.dataRevision,
            channelConfigRevision: vm.channelConfigRevision,
            viewportRevision: vm.viewportRevision,
            overlayRevision: vm.overlayRevision,
            lodIndex: vm.lodIndex,
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
          );
        }

        Widget buildLayer(PlotPaintLayer layer) {
          return RepaintBoundary(
            key: ValueKey<String>('plot-layer-${layer.name}'),
            child: CustomPaint(
              painter: createPainter(layer),
              size: Size.infinite,
            ),
          );
        }

        return Stack(
          children: [
            PlotGestureHandler(
              viewport: renderViewport,
              vCursorEnabled: vm.vCursorEnabled,
              boxZoomEnabled: vm.boxZoomEnabled,
              refreshFps: vm.effectiveRefreshFps,
              plotFontSizeDelta: vm.plotFontSizeDelta,
              channels: displayChannels,
              activeChannelCount: activeChannelCount,
              data: displayDataPoints,
              observations: vm.observations,
              onObservationDrag: (index, x) => vm.updateObservation(index, x),
              onObservationDelete: (index) => vm.removeObservation(index),
              observationPlacementActive: vm.observationPlacementActive,
              onObservationPlacementHover: vm.updateObservationPlacement,
              onObservationPlacementCommit: vm.commitObservationPlacement,
              onViewportChanged:
                  (viewport, {fromDrag = false}) =>
                      vm.updateViewport(viewport, fromDrag: fromDrag),
              onDragEnd: vm.saveDragViewport,
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
              onStatsX1Drag:
                  vm.statsRangeEnabled ? (x) => vm.setStatsX1(x) : null,
              onStatsX2Drag:
                  vm.statsRangeEnabled ? (x) => vm.setStatsX2(x) : null,
              // 通道偏移拖动回调
              onChannelOffsetDrag:
                  (index, yOffset) => vm.setChannelYOffset(index, yOffset),
              // 通道 Y 轴缩放回调（Shift+滚轮在偏置Y轴列上）
              onChannelYScaleZoom:
                  (index, scaleDelta) =>
                      vm.zoomChannelYScale(index, scaleDelta),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  buildLayer(PlotPaintLayer.background),
                  buildLayer(PlotPaintLayer.data),
                  buildLayer(PlotPaintLayer.axis),
                  buildLayer(PlotPaintLayer.overlay),
                ],
              ),
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
        );
      },
    );
  }

  double _plotFontSize(PlotViewModel vm, double base) {
    return (base + vm.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
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
    CursorState observation,
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
    final latestPoint =
        vm.displayDataPoints.isEmpty ? null : vm.displayDataPoints.last;
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
        14 + _measureFloatingTextWidth('$name: $value', fontSize: fontSize),
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
          ),
        ),
      );
    }

    return _DraggableInfoBox(
      initialRight: 16,
      initialTop: _legendVisible ? 240 : 96,
      backgroundColor: _floatingBoxBackgroundColor(vm),
      borderColor: Colors.lightBlue.withValues(alpha: 0.55),
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

    return _DraggableInfoBox(
      initialRight: 16,
      initialTop: 96,
      backgroundColor: _floatingBoxBackgroundColor(vm),
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
                  color: _floatingTextColor(vm),
                  fontSize: _plotFontSize(vm, 12),
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
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: AppStrings.plot.frequencyHz,
                    hintText: '1 ~ 100000',
                    suffixText: 'Hz',
                  ),
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
          ({onProgress}) => vm.exportToCsv(result, onProgress: onProgress),
    );
  }

  void _exportBin(BuildContext context, PlotViewModel vm) async {
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
          ({onProgress}) => vm.exportToBin(result, onProgress: onProgress),
    );
  }

  Future<void> _runExportWithProgress({
    required BuildContext context,
    required PlotViewModel vm,
    required String title,
    required Future<String?> Function({PlotExportProgressCallback? onProgress})
    exportFile,
  }) async {
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
            ),
      ).whenComplete(() => dialogClosed = true),
    );
    await _waitForImportDialogPresentation();

    final path = await exportFile(
      onProgress: (progress) => progressNotifier.value = progress,
    );
    if (context.mounted && !dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progressNotifier.dispose();
    if (!context.mounted) return;
    vm.showStatusMessage(
      path == null
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
    if (!vm.isPlotting && !vm.isStopping) return true;
    vm.showStatusMessage(AppStrings.plot.fileOperationDisabledWhilePlotting);
    return false;
  }

  void _importCsv(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.plot.chooseCsvFile,
      type: FileType.custom,
      allowedExtensions: ['csv'],
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
      type: FileType.custom,
      allowedExtensions: ['bin'],
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

  Future<void> _runImportWithProgress({
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

  Color _plotBackgroundColor(String background) {
    return switch (background) {
      'light' => const Color(0xFFF8FAFC),
      _ => const Color(0xFF1A1A2E),
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

  Widget _buildBackgroundButton(
    String label,
    String background,
    PlotViewModel vm,
    StateSetter setState,
  ) {
    final isSelected = vm.plotBackground == background;
    return Expanded(
      child: TextButton(
        onPressed: () {
          vm.setPlotBackground(background);
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
            color: _floatingTextColor(vm),
            fontSize: _plotFontSize(vm, 12),
            fontFamily: 'SarasaUiSC',
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

    return _DraggableInfoBox(
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
      return Text(
        text,
        style: TextStyle(
          color: _floatingTextColor(vm),
          fontSize: _plotFontSize(vm, 11),
          fontFamily: 'SarasaUiSC',
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
            color: _floatingTextColor(vm),
            fontSize: _plotFontSize(vm, 11),
            fontFamily: 'SarasaUiSC',
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
  /// 包含：网格开关、网格密度、刷新帧率、绘图窗口上限。
  void _showAdvancedSettingsDialog(BuildContext context, PlotViewModel vm) {
    final refreshFpsController = TextEditingController(
      text: vm.refreshFps.toString(),
    );
    final snapDiameterController = TextEditingController(
      text: vm.snapHighlightDiameter.toStringAsFixed(0),
    );
    final maxVisibleController = TextEditingController(
      text: _formatCompactCount(vm.maxVisiblePoints),
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

    void applyFloatingPanelOpacity(StateSetter setDialogState) {
      final percent = double.tryParse(
        floatingPanelOpacityController.text.trim(),
      );
      if (percent != null) {
        vm.setFloatingPanelOpacity(percent / 100);
      }
      floatingPanelOpacityController.text =
          (vm.floatingPanelOpacity * 100).round().toString();
      setDialogState(() {});
    }

    void applyFollowPosition(StateSetter setDialogState) {
      final percent = double.tryParse(followPositionController.text.trim());
      if (percent != null) {
        vm.setFollowPositionRatio(percent / 100);
      }
      followPositionController.text =
          (vm.followPositionRatio * 100).round().toString();
      setDialogState(() {});
    }

    void applyYFitRatio(StateSetter setDialogState) {
      final percent = double.tryParse(yFitDisplayRatioController.text.trim());
      if (percent != null) {
        vm.setYFitDisplayRatio(percent / 100);
      }
      yFitDisplayRatioController.text =
          (vm.yFitDisplayRatio * 100).round().toString();
      setDialogState(() {});
    }

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.advancedSettings),
            content: SizedBox(
              width: 420,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return Scrollbar(
                    controller: advancedSettingsScrollController,
                    child: SingleChildScrollView(
                      controller: advancedSettingsScrollController,
                      padding: const EdgeInsets.only(right: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppStrings.plot.plotBackground,
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _buildBackgroundButton(
                                AppStrings.plot.plotBackgroundDark,
                                'dark',
                                vm,
                                setState,
                              ),
                              const SizedBox(width: 8),
                              _buildBackgroundButton(
                                AppStrings.plot.plotBackgroundLight,
                                'light',
                                vm,
                                setState,
                              ),
                            ],
                          ),
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
                                      (_) =>
                                          applyFloatingPanelOpacity(setState),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed:
                                    () => applyFloatingPanelOpacity(setState),
                                child: Text(AppStrings.common.apply),
                              ),
                            ],
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
                            Text(
                              AppStrings.plot.gridDensity,
                              style: const TextStyle(fontSize: 14),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                _buildDensityButton(
                                  AppStrings.plot.densitySparse,
                                  'sparse',
                                  vm,
                                  setState,
                                ),
                                const SizedBox(width: 8),
                                _buildDensityButton(
                                  AppStrings.plot.densityNormal,
                                  'normal',
                                  vm,
                                  setState,
                                ),
                                const SizedBox(width: 8),
                                _buildDensityButton(
                                  AppStrings.plot.densityDense,
                                  'dense',
                                  vm,
                                  setState,
                                ),
                              ],
                            ),
                          ],
                          const Divider(),
                          // 刷新帧率
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
                                      vm.setRefreshFps(fps);
                                      refreshFpsController.text =
                                          vm.refreshFps.toString();
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
                                    vm.setRefreshFps(fps);
                                    refreshFpsController.text =
                                        vm.refreshFps.toString();
                                    setState(() {});
                                  }
                                },
                                child: Text(AppStrings.common.apply),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${(1000 / vm.refreshFps).round()}ms',
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
                              setState(() {});
                            },
                          ),
                          Text(
                            AppStrings.plot.plotFontSizeHelp,
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          const Divider(),
                          Text(
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
                                  onSubmitted:
                                      (_) => applyFollowPosition(setState),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: () => applyFollowPosition(setState),
                                child: Text(AppStrings.common.apply),
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
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: () => applyYFitRatio(setState),
                                child: Text(AppStrings.common.apply),
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
                                value: vm.statsToolbarEnabled,
                                onChanged: (value) {
                                  vm.setStatsToolbarEnabled(value);
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          const Divider(),
                          Row(
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
                                      AppStrings
                                          .plot
                                          .observationClickToPlaceHelp,
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
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          const Divider(),
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
                                value: vm.snapHighlightEnabled,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: (value) {
                                  vm.setSnapHighlightEnabled(value);
                                  setState(() {});
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
                                  enabled: vm.snapHighlightEnabled,
                                  decoration: secondaryDialogFieldDecoration(
                                    suffixText: AppStrings.plot.unitPixel,
                                  ),
                                  onSubmitted: (value) {
                                    final diameter = double.tryParse(value);
                                    if (diameter != null) {
                                      vm.setSnapHighlightDiameter(diameter);
                                      snapDiameterController.text = vm
                                          .snapHighlightDiameter
                                          .toStringAsFixed(0);
                                      setState(() {});
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed:
                                    vm.snapHighlightEnabled
                                        ? () {
                                          final diameter = double.tryParse(
                                            snapDiameterController.text,
                                          );
                                          if (diameter != null) {
                                            vm.setSnapHighlightDiameter(
                                              diameter,
                                            );
                                            snapDiameterController.text = vm
                                                .snapHighlightDiameter
                                                .toStringAsFixed(0);
                                            setState(() {});
                                          }
                                        }
                                        : null,
                                child: Text(AppStrings.common.apply),
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
                          SegmentedButton<String>(
                            segments: [
                              ButtonSegment<String>(
                                value: 'cursor',
                                label: Text(
                                  AppStrings.plot.snapHighlightColorCursor,
                                ),
                              ),
                              ButtonSegment<String>(
                                value: 'channel',
                                label: Text(
                                  AppStrings.plot.snapHighlightColorChannel,
                                ),
                              ),
                            ],
                            selected: {vm.snapHighlightColorMode},
                            onSelectionChanged:
                                vm.snapHighlightEnabled
                                    ? (values) {
                                      vm.setSnapHighlightColorMode(
                                        values.first,
                                      );
                                      setState(() {});
                                    }
                                    : null,
                          ),
                          const Divider(),
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
                                      vm.setMaxVisiblePoints(points);
                                      maxVisibleController
                                          .text = _formatCompactCount(
                                        vm.maxVisiblePoints,
                                      );
                                      setState(() {});
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: () {
                                  final points = _parseCompactCount(
                                    maxVisibleController.text,
                                  );
                                  if (points != null) {
                                    vm.setMaxVisiblePoints(points);
                                    maxVisibleController
                                        .text = _formatCompactCount(
                                      vm.maxVisiblePoints,
                                    );
                                    setState(() {});
                                  }
                                },
                                child: Text(AppStrings.common.apply),
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
                              current: _formatCompactCount(
                                vm.visiblePointCount,
                              ),
                            ),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          const Divider(),
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
                                      vm.setDiscardInitialPacketCount(count);
                                      discardInitialPacketController
                                          .text = _formatCompactCount(
                                        vm.discardInitialPacketCount,
                                      );
                                      setState(() {});
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: () {
                                  final count = _parseCompactCount(
                                    discardInitialPacketController.text,
                                  );
                                  if (count != null) {
                                    vm.setDiscardInitialPacketCount(count);
                                    discardInitialPacketController
                                        .text = _formatCompactCount(
                                      vm.discardInitialPacketCount,
                                    );
                                    setState(() {});
                                  }
                                },
                                child: Text(AppStrings.common.apply),
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
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.close),
              ),
            ],
          ),
    ).whenComplete(() {
      refreshFpsController.dispose();
      snapDiameterController.dispose();
      maxVisibleController.dispose();
      discardInitialPacketController.dispose();
      followPositionController.dispose();
      yFitDisplayRatioController.dispose();
      advancedSettingsScrollController.dispose();
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
    if (!vm.isPlotting && !vm.isStopping) return true;
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
