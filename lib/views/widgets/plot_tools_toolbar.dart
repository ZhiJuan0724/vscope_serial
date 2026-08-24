import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'common_widgets.dart';

/// 单个「交互工具」按钮的完整配置。
///
/// 串口绘图页与探针绘图页的工具栏交互工具按钮簇共用同一套渲染，仅数据源与
/// 形态不同。每个工具用一份配置描述：按钮形态（图标 / 图标+文字）、选中态、
/// 可用态、回调，以及折叠到“更多”菜单后的展示文案。
///
/// 字段约定：
/// - [visible] 为 false 时该工具被隐藏（后端不支持的功能），不渲染、不占位。
/// - [onPressed] 为 null 时按钮禁用（灰显），等价于 enabled=false。
/// - [label] 为 null 时渲染纯图标按钮，否则渲染图标+文字按钮。
/// - [toggle] 为 false 时渲染无选中态的普通图标按钮（撤回缩放、自适应等）。
class PlotToolConfig {
  const PlotToolConfig({
    this.key,
    required this.icon,
    required this.tooltip,
    required this.overflowLabel,
    this.label,
    this.visible = true,
    this.selected = false,
    this.activeColor,
    this.onPressed,
    this.overflowOnPressed,
    this.onSecondaryPressed,
    this.toggle = true,
  });

  /// 内联按钮的 Key（用于测试定位），不用于“更多”菜单项。
  final Key? key;

  /// 按钮图标。
  final Widget icon;

  /// 按钮悬停提示。
  final String tooltip;

  /// 折叠到“更多”菜单后显示的文案（可能与 tooltip/label 措辞不同）。
  final String overflowLabel;

  /// 文字按钮的标签；为 null 时使用纯图标形态。
  final String? label;

  /// 是否显示该工具；后端不支持的功能传 false 以隐藏按钮。
  final bool visible;

  /// 选中态（高亮）。
  final bool selected;

  /// 选中时的状态色；为 null 时使用主题主色。
  final Color? activeColor;

  /// 左键回调；为 null 时按钮禁用。
  final VoidCallback? onPressed;

  /// “更多”菜单里的左键回调，默认回退到 [onPressed]。
  ///
  /// 仅当内联按钮与折叠后的可用性不一致时才需要单独指定（如绘图页的“观察”
  /// 内联按钮始终可点击、折叠后无数据时禁用）。
  final VoidCallback? overflowOnPressed;

  /// 右键回调（内联按钮与“更多”菜单共用）；为 null 时不响应右键。
  final VoidCallback? onSecondaryPressed;

  /// 是否为带选中态的切换按钮；false 表示普通图标按钮。
  final bool toggle;

  /// 生成折叠到“更多”菜单后对应的操作项。
  ToolbarOverflowAction toOverflowAction() {
    return ToolbarOverflowAction(
      icon: icon,
      label: overflowLabel,
      selected: selected,
      onPressed: overflowOnPressed ?? onPressed,
      onSecondaryPressed: onSecondaryPressed,
    );
  }
}

/// 用 [PlotToolConfig] 渲染单个交互工具按钮。
///
/// 依据配置的 [PlotToolConfig.label] 与 [PlotToolConfig.toggle] 选择项目已有的
/// [ToolbarToggleTextButton] / [ToolbarToggleIconButton] / [ToolbarIconButton]
/// 基元，不新造按钮样式；右键行为通过外层 [Listener] 统一处理。
class PlotToolbarButton extends StatelessWidget {
  const PlotToolbarButton({super.key, required this.config});

  final PlotToolConfig config;

  @override
  Widget build(BuildContext context) {
    if (!config.visible) return const SizedBox.shrink();
    final inner = _buildInner();
    final secondary = config.onSecondaryPressed;
    if (secondary == null) {
      return KeyedSubtree(key: config.key, child: inner);
    }
    return Listener(
      key: config.key,
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) secondary();
      },
      child: inner,
    );
  }

  Widget _buildInner() {
    if (!config.toggle) {
      return ToolbarIconButton(
        icon: config.icon,
        tooltip: config.tooltip,
        onPressed: config.onPressed,
      );
    }
    final label = config.label;
    if (label == null) {
      return ToolbarToggleIconButton(
        icon: config.icon,
        tooltip: config.tooltip,
        selected: config.selected,
        activeColor: config.activeColor,
        onPressed: config.onPressed,
      );
    }
    return ToolbarToggleTextButton(
      icon: config.icon,
      label: label,
      tooltip: config.tooltip,
      selected: config.selected,
      activeColor: config.activeColor,
      onPressed: config.onPressed,
    );
  }
}

/// 把一串交互工具配置渲染为同一工具组内的按钮行。
///
/// 仅渲染 [PlotToolConfig.visible] 为 true 的工具，并按 [kToolbarItemSpacing]
/// 在按钮之间留出统一间距。
class PlotToolsToolbar extends StatelessWidget {
  const PlotToolsToolbar({super.key, required this.tools});

  final List<PlotToolConfig> tools;

  @override
  Widget build(BuildContext context) {
    final visibleTools = [
      for (final tool in tools)
        if (tool.visible) tool,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < visibleTools.length; index++) ...[
          if (index > 0) const SizedBox(width: kToolbarItemSpacing),
          PlotToolbarButton(config: visibleTools[index]),
        ],
      ],
    );
  }
}
