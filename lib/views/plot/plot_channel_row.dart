import 'package:flutter/material.dart';

import '../../core/localization/app_strings.dart';

/// 通道行渲染所需的最小状态（已由页面预解析后传入）。
///
/// 串口绘图页与探针绘图页的通道模型字段语义相同（`visible`/`color`/`alias`），
/// 只是名称回退规则、可见性控件和附加列不同。这里只承载通道行真正需要的
/// 最小状态，避免共享组件依赖任一 ViewModel 的具体字段。
@immutable
class PlotChannelRowData {
  const PlotChannelRowData({
    required this.name,
    required this.color,
    required this.visible,
  });

  /// 通道显示名（页面已解析出最终文案，例如「别名空则回退 ChN」）。
  final String name;

  /// 通道颜色。
  final Color color;

  /// 通道是否可见。
  final bool visible;
}

/// 通道面板控制器最小接口。
///
/// 只覆盖「通道行渲染 + 可见性切换」所需的部分。数学通道、偏移、类型编辑、
/// 地址/预设等两页差异较大的能力不在本接口范围内，仍由各页外壳处理。
///
/// 两页的 ViewModel 都持有同构的 `ChannelConfig` 列表，可通过一个视图层
/// 适配器实现本接口。由于串口绘图页的通道列表是「普通通道 + 数学通道」
/// 异构列表（无法用单一 `rowData(index)` 表达），本切片中页面直接用
/// [PlotChannelRowData] + `onToggleVisible` 回调的形式喂给共享行；本接口
/// 作为后续统一通道模型时的正式契约保留。
abstract interface class PlotChannelPanelController {
  /// 需要渲染的通道数量。
  int get channelCount;

  /// 第 [index] 个通道的预解析行数据。
  PlotChannelRowData rowData(int index);

  /// 切换第 [index] 个通道的可见性。
  void toggleChannelVisible(int index);
}

/// 通道颜色块（10×10）。两页通道行共用同一视觉。
class PlotChannelColorBlock extends StatelessWidget {
  const PlotChannelColorBlock({
    super.key,
    required this.color,
    this.borderRadius = 2.0,
  });

  final Color color;

  /// 圆角半径；串口绘图页为 2，探针绘图页为 0（原直角方块）。
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// 通道可见性「眼睛」开关（抽取自串口绘图页的 `_ChannelVisibilityButton`）。
class PlotChannelVisibilityButton extends StatelessWidget {
  const PlotChannelVisibilityButton({
    super.key,
    required this.visible,
    this.tooltip,
    required this.onToggle,
  });

  final bool visible;
  final String? tooltip;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          tooltip ??
          (visible ? AppStrings.plot.hideChannel : AppStrings.plot.showChannel),
      child: SizedBox(
        width: 22,
        height: 24,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onToggle,
            child: Icon(
              visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18,
              color:
                  visible
                      ? colorScheme.onSurface.withValues(alpha: 0.82)
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

/// 串口绘图页与探针绘图页共用的「通道行内容」。
///
/// 只负责渲染一行通道的**内容**（颜色块 + 名称 + 可选尾随列 + 可见性开关），
/// 不含列表滚动、折叠、容器边框/内边距等页面级外壳——这些仍由两页各自的
/// 面板保留，以保持既有视觉与交互完全一致。
///
/// 两页的实质差异通过可选参数保留：
/// - 可见性控件：串口绘图页用「眼睛」图标，探针绘图页用复选框
///   （通过 [visibilityBuilder] 覆盖）。
/// - 名称隐藏态样式：串口绘图页灰显+删除线，探针绘图页保持原色
///   （通过 [dimNameWhenHidden] 关闭）。
/// - 附加列（偏移开关等）通过 [trailing] 传入。
/// - 名称控件（双击内联编辑 + 地址等）通过 [nameWidget] 覆盖。
class PlotChannelRow extends StatelessWidget {
  const PlotChannelRow({
    super.key,
    required this.data,
    required this.onToggleVisible,
    this.nameWidget,
    this.nameTooltip,
    this.trailing = const <Widget>[],
    this.visibilityBuilder,
    this.dimNameWhenHidden = true,
    this.colorBlockRadius = 2.0,
  });

  /// 通道行的预解析最小数据。
  final PlotChannelRowData data;

  /// 可见性切换回调。
  final VoidCallback onToggleVisible;

  /// 自定义名称控件；为 null 时使用内置名称文本（含隐藏态样式与省略号）。
  ///
  /// 串口绘图页的普通通道行传入「双击内联编辑 + 地址 + 预设」组合控件。
  final Widget? nameWidget;

  /// 名称的无条件悬浮提示；为 null 时不包裹 [Tooltip]。
  ///
  /// 数学通道行用它显示表达式。
  final String? nameTooltip;

  /// 名称与可见性开关之间的附加列（如偏移开关）。
  final List<Widget> trailing;

  /// 自定义可见性控件；为 null 时使用 [PlotChannelVisibilityButton]。
  ///
  /// 探针绘图页用它保留复选框交互。
  final Widget Function(bool visible, VoidCallback onToggle)? visibilityBuilder;

  /// 通道隐藏时名称是否灰显+删除线。串口绘图页为 true，探针绘图页为 false。
  final bool dimNameWhenHidden;

  /// 颜色块圆角半径。
  final double colorBlockRadius;

  @override
  Widget build(BuildContext context) {
    final name = nameWidget ?? _buildName(context);
    return Row(
      children: [
        PlotChannelColorBlock(
          color: data.color,
          borderRadius: colorBlockRadius,
        ),
        const SizedBox(width: 4),
        Expanded(
          child:
              nameTooltip == null
                  ? name
                  : Tooltip(message: nameTooltip, child: name),
        ),
        ...trailing,
        const SizedBox(width: 5),
        _buildVisibility(context),
      ],
    );
  }

  Widget _buildName(BuildContext context) {
    final style = TextStyle(
      fontSize: 14,
      color: dimNameWhenHidden && !data.visible ? Colors.grey : null,
      decoration:
          dimNameWhenHidden && !data.visible
              ? TextDecoration.lineThrough
              : null,
    );
    return Text(
      data.name,
      style: style,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
  }

  Widget _buildVisibility(BuildContext context) {
    final builder = visibilityBuilder;
    if (builder != null) return builder(data.visible, onToggleVisible);
    return PlotChannelVisibilityButton(
      visible: data.visible,
      onToggle: onToggleVisible,
    );
  }
}
