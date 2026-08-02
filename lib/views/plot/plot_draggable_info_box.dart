import 'package:flutter/material.dart';

/// 串口绘图与探针绘图共用的可拖动信息浮窗。
class PlotDraggableInfoBox extends StatefulWidget {
  const PlotDraggableInfoBox({
    super.key,
    required this.initialRight,
    required this.initialTop,
    required this.backgroundColor,
    required this.borderColor,
    required this.child,
    this.onPositionChanged,
    this.fontSizeDelta,
    this.fontBold,
  });

  final double initialRight;
  final double initialTop;
  final Color backgroundColor;
  final Color borderColor;
  final void Function(double right, double top)? onPositionChanged;
  final int? fontSizeDelta;
  final bool? fontBold;
  final Widget child;

  @override
  State<PlotDraggableInfoBox> createState() => _PlotDraggableInfoBoxState();
}

class _PlotDraggableInfoBoxState extends State<PlotDraggableInfoBox> {
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
        onPanEnd: (_) => _finishDrag(),
        onPanCancel: _finishDrag,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: widget.borderColor),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize:
                  widget.fontSizeDelta == null
                      ? null
                      : (13 + widget.fontSizeDelta!).clamp(7, 25).toDouble(),
              fontWeight: widget.fontBold == true ? FontWeight.bold : null,
            ),
            child: IntrinsicHeight(child: widget.child),
          ),
        ),
      ),
    );
  }

  void _finishDrag() {
    _dragStart = null;
    final right = _right;
    final top = _top;
    if (right != null && top != null) {
      widget.onPositionChanged?.call(right, top);
    }
  }
}
