import 'package:flutter/material.dart';

import '../../core/localization/app_strings.dart';

/// 实时值框中的单条通道数据（通道名 + 当前值 + 颜色）。
class PlotLiveValueEntry {
  const PlotLiveValueEntry({
    required this.color,
    required this.name,
    required this.value,
  });

  final Color color;

  /// 通道显示名（由调用方按各自规则解析好，例如别名空时是否回退 ChN）。
  final String name;

  /// 已格式化的当前值文本（由调用方用 [formatPlotValue] 之类格式化好）。
  final String value;
}

/// 串口绘图页与探针绘图页共用的「实时值框」内容。
///
/// 只负责渲染实时值的**内容**（标题 + 每个可见通道的颜色块与「名称: 值」），
/// 不包含拖拽定位、背景色、字号缩放、宽度测量等页面级浮窗外观——这些仍由
/// 两页各自的 `PlotDraggableInfoBox` 包裹，以保持既有视觉与交互完全一致。
///
/// 两页的差异通过 [rowBuilder]（名称/值的文本排版）与 [rowPadding]、
/// [emptyText] 等参数保留，不在共享组件内强行统一。
class PlotLiveValuesBox extends StatelessWidget {
  const PlotLiveValuesBox({
    super.key,
    required this.entries,
    this.title,
    this.titleStyle,
    this.rowPadding = const EdgeInsets.symmetric(vertical: 1),
    this.rowBuilder,
    this.emptyText,
    this.emptyTextStyle,
  });

  /// 已过滤为可见的通道值列表（按显示顺序）。
  final List<PlotLiveValueEntry> entries;

  /// 标题文案，默认 [AppStrings.plot.liveValues]（「实时值」）。
  final String? title;

  /// 标题文本样式，默认加粗。
  final TextStyle? titleStyle;

  /// 每行通道值的垂直内边距；串口绘图页为 1，探针绘图页为 2。
  final EdgeInsetsGeometry rowPadding;

  /// 单行「名称: 值」的渲染回调。两页排版不同：
  /// 串口绘图页把名称与值拆成两个 Text（名称过长时省略、值始终完整显示），
  /// 探针绘图页把整行合成一个 Text（整行过长时省略）。
  /// 为 null 时使用探针绘图页的整行省略排版。
  final Widget Function(PlotLiveValueEntry entry)? rowBuilder;

  /// 无可见通道时的占位文案（串口绘图页为「无显示通道」）；null 则不显示。
  final String? emptyText;

  /// 占位文案文本样式。
  final TextStyle? emptyTextStyle;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Text(
        title ?? AppStrings.plot.liveValues,
        style: titleStyle ?? const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
    ];
    if (entries.isEmpty && emptyText != null) {
      children.add(Text(emptyText!, style: emptyTextStyle));
    } else {
      for (final entry in entries) {
        children.add(
          Padding(
            padding: rowPadding,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: entry.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                _buildRow(entry),
              ],
            ),
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildRow(PlotLiveValueEntry entry) {
    final builder = rowBuilder;
    if (builder != null) return builder(entry);
    return Flexible(
      child: Text(
        '${entry.name}: ${entry.value}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: entry.color),
      ),
    );
  }
}
