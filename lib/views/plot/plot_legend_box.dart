import 'package:flutter/material.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/channel_config.dart';

/// 串口绘图页与探针绘图页共用的「图例框」内容。
///
/// 只负责渲染图例的**内容**（标题 + 每个可见通道的颜色块与名称），
/// 不包含拖拽定位、背景色、字号缩放等页面级浮窗外观——这些仍由两页
/// 各自的 [PlotDraggableInfoBox] 包裹，以保持既有视觉与交互完全一致。
///
/// 两页的唯一实质性差异（名称回退规则、是否限单行）通过 [nameFor] 与
/// [nameMaxLines] 显式传入，避免在共享组件内强行统一。
class PlotLegendBox extends StatelessWidget {
  const PlotLegendBox({
    super.key,
    required this.channels,
    this.title,
    this.titleStyle,
    this.nameStyle,
    this.nameFor,
    this.nameMaxLines,
  });

  /// 已过滤为可见的通道列表（按显示顺序）。
  final List<ChannelConfig> channels;

  /// 标题文案，默认 [AppStrings.plot.legend]（「图例」）。
  final String? title;

  /// 标题文本样式，默认加粗。
  final TextStyle? titleStyle;

  /// 通道名称文本样式；为 null 时继承外层 [DefaultTextStyle]。
  final TextStyle? nameStyle;

  /// 通道显示名解析规则；默认直接取 `alias`（与探针绘图页一致）。
  /// 串口绘图页传入「别名空则回退为 ChN」的规则。
  final String Function(ChannelConfig channel)? nameFor;

  /// 通道名称最大行数；null 表示不限制（串口绘图页），探针绘图页传 1。
  final int? nameMaxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title ?? AppStrings.plot.legend,
          style: titleStyle ?? const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        for (final channel in channels)
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
                    _nameOf(channel),
                    maxLines: nameMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: nameStyle,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _nameOf(ChannelConfig channel) {
    final resolver = nameFor;
    if (resolver != null) return resolver(channel);
    return channel.alias;
  }
}
