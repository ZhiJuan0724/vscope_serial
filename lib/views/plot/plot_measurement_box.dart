import 'package:flutter/material.dart';

/// 串口绘图页与探针绘图页共用的「测量信息框」内容（Delta X/Y 等测量文本）。
///
/// 只负责渲染测量文本本体（SarasaUiSC 字体 + 统一字号），
/// 不包含拖拽定位、背景色、字号缩放等页面级浮窗外观——这些仍由两页各自的
/// `PlotDraggableInfoBox` 包裹。串口绘图页的统计列（stats）与该文本并列显示，
/// 仍由其页内的组合信息框自行编排，不在本组件内处理。
///
/// 两页的差异（颜色/字重/行高/是否启用等宽数字）通过可选参数保留。
class PlotMeasurementBox extends StatelessWidget {
  const PlotMeasurementBox({
    super.key,
    required this.text,
    required this.fontSize,
    this.color,
    this.fontWeight,
    this.height,
    this.tabularFigures = false,
  });

  /// 测量文本（多行，含 X1/X2/ΔX、Y1/Y2/ΔY 等）。
  final String text;

  /// 字号（两页均用各自 `_plotFontSize(vm, 12)` 计算后传入）。
  final double fontSize;

  /// 文本颜色；null 表示继承外层 [DefaultTextStyle]。
  final Color? color;

  /// 字重；null 表示继承外层 [DefaultTextStyle]。
  final FontWeight? fontWeight;

  /// 行高；null 表示默认。
  final double? height;

  /// 是否启用等宽数字（探针绘图页开启）。
  final bool tabularFigures;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'SarasaUiSC',
        fontSize: fontSize,
        color: color,
        fontWeight: fontWeight,
        height: height,
        fontFeatures:
            tabularFigures ? const [FontFeature.tabularFigures()] : null,
      ),
    );
  }
}
