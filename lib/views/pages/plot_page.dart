import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/crc.dart';
import '../../data/models/channel_config.dart';
import '../../data/models/zobow_config_profile.dart';
import '../../data/models/parser_config.dart';
import '../../services/app_settings.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../dialogs/zobow_profile_dialog.dart';
import '../plot/plot_gesture_handler.dart';
import '../plot/plot_painter.dart';
import '../plot/plot_viewport.dart';
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
const double kMinChannelPanelWidth = 240;
const double kCompactChannelPanelWidth = 212;
const double kMaxChannelPanelWidth = 400;
const double kDefaultChannelPanelWidth = 240;
const double kCollapsedPanelWidth = 26;
const double kRProtocolAddressWidth = 86;
const double kFixedFrameConfigLabelWidth = 72;
const double kDataTypeDropdownWidth = 148;

InputDecoration _compactDropdownDecoration() {
  return const InputDecoration(
    isDense: true,
    border: OutlineInputBorder(),
    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
  );
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
      return kMinChannelPanelWidth;
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
                      children: [
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
                  // 缩放和框选工具组
                  _buildZoomTools(context, vm),
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
            ? '停止中'
            : vm.isPlotting
            ? '停止'
            : '开始',
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: vm.useRandomSource,
          onChanged: (value) => vm.setUseRandomSource(value!),
        ),
        const Text(
          '随机源',
          style: TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
        ),
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

  /// 收发协议选择 + 配置按钮 + 地址配置文件选择
  Widget _buildParserSelector(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          child: NoAnimDropdown<ParserType>(
            value: vm.parserType,
            hint: '接收协议',
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
        const SizedBox(width: 8),
        SizedBox(
          width: 112,
          child: NoAnimDropdown<SendProtocolType>(
            value: vm.effectiveSendProtocolType,
            hint: '发送协议',
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
                vm.parserType == ParserType.zobow
                    ? null
                    : (value) {
                      if (value != null) vm.setSendProtocolType(value);
                    },
          ),
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
        ] else if (vm.sendProtocolType == SendProtocolType.rProtocol) ...[
          const SizedBox(width: 8),
          _buildRProfileSelector(context, vm),
          Tooltip(
            message: '新建 r 协议配置',
            child: InkWell(
              onTap: () => _showCreateRProfileDialog(context, vm),
              child: const SizedBox(
                width: 28,
                height: 28,
                child: Icon(Icons.add, size: 16),
              ),
            ),
          ),
          Tooltip(
            message: '编辑 r 协议配置',
            child: InkWell(
              onTap: () => _showEditRProfileDialog(context, vm),
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

  Widget _buildRProfileSelector(BuildContext context, PlotViewModel vm) {
    return SizedBox(
      width: 140,
      child: NoAnimDropdown<String?>(
        value: vm.selectedRProfileId.isEmpty ? null : vm.selectedRProfileId,
        hint: '不使用配置',
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text(
              '不使用配置',
              style: TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
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
        onChanged: vm.selectRProfile,
      ),
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
            child: Text(
              '不使用配置',
              style: TextStyle(fontSize: 12, fontFamily: 'SarasaUiSC'),
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
        const SizedBox(width: 4),
        Tooltip(
          message: '添加观察',
          child: TextButton.icon(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.addObservation(),
            icon: const Icon(Icons.add_location_alt, size: 16),
            label: const Text(
              '观察',
              style: TextStyle(fontSize: 11, fontFamily: 'SarasaUiSC'),
            ),
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
                fontFamily: 'SarasaUiSC',
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
                fontFamily: 'SarasaUiSC',
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
                fontFamily: 'SarasaUiSC',
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
          child: TextButton.icon(
            onPressed: () => setState(() => _legendVisible = !_legendVisible),
            icon: Icon(
              Icons.list_alt,
              size: 16,
              color: _legendVisible ? Colors.teal : null,
            ),
            label: Text(
              '图例',
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
  /// 顺序：导入数据 | 导出数据
  Widget _buildFileTools(BuildContext context, PlotViewModel vm) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '导入 CSV/BIN/旧版 DAT',
          child: IconButton(
            onPressed: () => _importPlotData(context, vm),
            icon: const Icon(Icons.file_open, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ),
        Tooltip(
          message: '导出 CSV/BIN',
          child: IconButton(
            onPressed:
                vm.dataPoints.isEmpty
                    ? null
                    : () => _exportPlotData(context, vm),
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
          child: TextButton.icon(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitYAxis(),
            icon: const Icon(Icons.vertical_align_center, size: 16),
            label: const Text(
              'Y自适应',
              style: TextStyle(fontSize: 11, fontFamily: 'SarasaUiSC'),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
          ),
        ),
        Tooltip(
          message: 'X轴自适应',
          child: TextButton.icon(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitXAxis(),
            icon: const Icon(Icons.horizontal_rule, size: 16),
            label: const Text(
              'X自适应',
              style: TextStyle(fontSize: 11, fontFamily: 'SarasaUiSC'),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
          ),
        ),
        Tooltip(
          message: '全自适应',
          child: TextButton.icon(
            onPressed: vm.dataPoints.isEmpty ? null : () => vm.fitAll(),
            icon: const Icon(Icons.fit_screen, size: 16),
            label: const Text(
              '全自适应',
              style: TextStyle(fontSize: 11, fontFamily: 'SarasaUiSC'),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
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
            : vm.parserType == ParserType.fixedFrame
            ? vm.parserConfig.channelCount
            : vm.effectiveSendProtocolType == SendProtocolType.rProtocol
            ? math.max(vm.activeChannelCount, vm.rAddressDisplayCount)
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
    final activeChannelCount =
        vm.activeChannelCount > 0 ? vm.activeChannelCount : vm.channels.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridDensity = _parseGridDensity(vm.gridDensity);
        final offsetAxisColumnWidths =
            PlotPainter.calculateOffsetAxisColumnWidths(
              viewport: vm.viewport,
              channels: vm.channels,
              activeChannelCount: activeChannelCount,
              canvasHeight: constraints.maxHeight,
              gridDensity: gridDensity,
              plotFontSizeDelta: vm.plotFontSizeDelta.toDouble(),
            );
        final renderViewport =
            vm.viewport.copy()
              ..setOffsetAxisColumnWidths(offsetAxisColumnWidths);

        return Stack(
          children: [
            PlotGestureHandler(
              viewport: renderViewport,
              vCursorEnabled: vm.vCursorEnabled,
              boxZoomEnabled: vm.boxZoomEnabled,
              refreshFps: vm.refreshFps,
              plotFontSizeDelta: vm.plotFontSizeDelta,
              channels: vm.channels,
              activeChannelCount: activeChannelCount,
              data: vm.dataPoints,
              observations: vm.observations,
              onObservationDrag: (index, x) => vm.updateObservation(index, x),
              onObservationDelete: (index) => vm.removeObservation(index),
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
              child: CustomPaint(
                painter: PlotPainter(
                  viewport: renderViewport,
                  data: vm.dataPoints,
                  dataRevision: vm.dataRevision,
                  lodIndex: vm.lodIndex,
                  channels: vm.channels,
                  activeChannelCount: activeChannelCount,
                  showGrid: vm.showGrid,
                  gridDensity: gridDensity,
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
              color: Colors.white,
              fontSize: _plotFontSize(vm, 12),
              fontWeight: FontWeight.bold,
              fontFamily: 'SarasaUiSC',
            ),
          ),
        ],
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
              fontFamily: 'SarasaUiSC',
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
                child: const Text('CSV 文本'),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _PlotFileFormat.bin),
                child: const Text('BIN 二进制'),
              ),
              if (includeLegacyDat)
                SimpleDialogOption(
                  onPressed:
                      () => Navigator.pop(context, _PlotFileFormat.legacyDat),
                  child: const Text('旧版虚拟示波器 DAT'),
                ),
            ],
          ),
    );
  }

  void _exportPlotData(BuildContext context, PlotViewModel vm) async {
    final format = await _choosePlotFileFormat(context, '选择导出格式');
    if (format == null || !context.mounted) return;
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

  void _exportBin(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.saveFile(
      dialogTitle: '保存 BIN 文件',
      fileName: 'vscope_plot_${DateTime.now().millisecondsSinceEpoch}.bin',
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    if (result == null) return;

    final path = await vm.exportToBin(result);
    if (path != null && context.mounted) {
      vm.showStatusMessage('已导出: $path');
    }
  }

  void _importPlotData(BuildContext context, PlotViewModel vm) async {
    final format = await _choosePlotFileFormat(
      context,
      '选择导入格式',
      includeLegacyDat: true,
    );
    if (format == null || !context.mounted) return;
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
    if (!context.mounted) return;

    await _runImportWithProgress(
      context: context,
      vm: vm,
      filePath: filePath,
      title: '导入 CSV',
      importFile: vm.importFromCsv,
      successMessage: 'CSV 导入成功',
    );
  }

  void _importBin(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择 BIN 文件',
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
      title: '导入 BIN',
      importFile: vm.importFromBin,
      successMessage: 'BIN 导入成功',
    );
  }

  void _importLegacyDat(BuildContext context, PlotViewModel vm) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择旧版虚拟示波器 DAT 文件',
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
      title: '导入旧版 DAT',
      importFile: vm.importFromLegacyDat,
      successMessage: '旧版 DAT 导入成功',
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
      const PlotImportProgress(stage: '准备导入', current: 0, total: 0),
    );
    var dialogClosed = false;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => _PlotImportProgressDialog(
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
      vm.showStatusMessage('导入失败: $error');
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
            color: Colors.white,
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
      text: vm.maxVisiblePoints.toString(),
    );
    final discardInitialPacketController = TextEditingController(
      text: vm.discardInitialPacketCount.toString(),
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
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: refreshFpsController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  suffixText: 'fps',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
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
                              child: const Text('应用'),
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
                        const Text(
                          '范围: 30~60 fps，默认 60 fps\n值越高绘图越流畅，但可能降低数据接收速率',
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
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '吸附点高亮',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                            Switch(
                              value: vm.snapHighlightEnabled,
                              onChanged: (value) {
                                vm.setSnapHighlightEnabled(value);
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: snapDiameterController,
                                keyboardType: TextInputType.number,
                                enabled: vm.snapHighlightEnabled,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  suffixText: 'px',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
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
                                          vm.setSnapHighlightDiameter(diameter);
                                          snapDiameterController.text = vm
                                              .snapHighlightDiameter
                                              .toStringAsFixed(0);
                                          setState(() {});
                                        }
                                      }
                                      : null,
                              child: const Text('应用'),
                            ),
                          ],
                        ),
                        const Text(
                          '范围: 6~12 px，默认 8 px。仅显示当前窗口内的吸附点',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const Divider(),
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
                        const Text('丢弃包数', style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: discardInitialPacketController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
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
                                  final count = int.tryParse(value);
                                  if (count != null) {
                                    vm.setDiscardInitialPacketCount(count);
                                    discardInitialPacketController.text =
                                        vm.discardInitialPacketCount.toString();
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () {
                                final count = int.tryParse(
                                  discardInitialPacketController.text,
                                );
                                if (count != null) {
                                  vm.setDiscardInitialPacketCount(count);
                                  discardInitialPacketController.text =
                                      vm.discardInitialPacketCount.toString();
                                  setState(() {});
                                }
                              },
                              child: const Text('应用'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '范围: 0~${PlotViewModel.maxDiscardInitialPacketCount} 包，默认 0 包。每次开始绘图时丢弃前 N 个成功解析的数据包，不影响文件导入。',
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
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
    ).whenComplete(() {
      refreshFpsController.dispose();
      snapDiameterController.dispose();
      maxVisibleController.dispose();
      discardInitialPacketController.dispose();
    });
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

  void _showCreateRProfileDialog(BuildContext context, PlotViewModel vm) {
    showDialog(
      context: context,
      builder:
          (context) => ZobowProfileDialog(
            vm: vm,
            protocolType: AddressProfileProtocolType.rProtocol,
          ),
    );
  }

  void _showEditRProfileDialog(BuildContext context, PlotViewModel vm) {
    final profile = vm.selectedRProfile;
    if (profile == null) {
      vm.showStatusMessage('请先选择一个 r 协议配置文件');
      return;
    }
    showDialog(
      context: context,
      builder:
          (context) => ZobowProfileDialog(
            vm: vm,
            profile: profile,
            protocolType: AddressProfileProtocolType.rProtocol,
          ),
    );
  }
}
