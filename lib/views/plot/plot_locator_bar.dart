import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'plot_viewport.dart';

/// 用于在完整数据范围中快速定位当前主图 X 视口的紧凑定位条。
class PlotLocatorBar extends StatefulWidget {
  final int pointCount;
  final PlotViewport viewport;
  final VoidCallback onDragEnd;
  final void Function(double centerX, {required bool fromDrag}) onNavigate;

  const PlotLocatorBar({
    super.key,
    required this.pointCount,
    required this.viewport,
    required this.onDragEnd,
    required this.onNavigate,
  });

  @override
  State<PlotLocatorBar> createState() => _PlotLocatorBarState();
}

class _PlotLocatorBarState extends State<PlotLocatorBar> {
  bool _draggingFrame = false;

  double _dataX(double screenX, double width) {
    final maxX = math.max(1, widget.pointCount - 1).toDouble();
    return (screenX / width * maxX).clamp(0.0, maxX);
  }

  bool _isInFrame(Offset localPosition, double width) {
    final maxX = math.max(1, widget.pointCount - 1).toDouble();
    final left = widget.viewport.xMin.clamp(0.0, maxX) / maxX * width;
    final right = widget.viewport.xMax.clamp(0.0, maxX) / maxX * width;
    return localPosition.dx >= left && localPosition.dx <= right;
  }

  void _finishDrag() {
    if (!_draggingFrame) return;
    widget.onDragEnd();
    setState(() => _draggingFrame = false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return MouseRegion(
          cursor:
              _draggingFrame
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp:
                (details) => widget.onNavigate(
                  _dataX(details.localPosition.dx, constraints.maxWidth),
                  fromDrag: false,
                ),
            onPanStart: (details) {
              final isInFrame = _isInFrame(
                details.localPosition,
                constraints.maxWidth,
              );
              if (_draggingFrame != isInFrame) {
                setState(() => _draggingFrame = isInFrame);
              }
            },
            onPanUpdate: (details) {
              if (!_draggingFrame) return;
              widget.onNavigate(
                _dataX(details.localPosition.dx, constraints.maxWidth),
                fromDrag: true,
              );
            },
            onPanEnd: (_) => _finishDrag(),
            onPanCancel: () {
              if (_draggingFrame) setState(() => _draggingFrame = false);
            },
            child: SizedBox.expand(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: PlotLocatorBarPainter(
                    pointCount: widget.pointCount,
                    xMin: widget.viewport.xMin,
                    xMax: widget.viewport.xMax,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class PlotLocatorBarPainter extends CustomPainter {
  final int pointCount;
  final double xMin;
  final double xMax;

  PlotLocatorBarPainter({
    required this.pointCount,
    required this.xMin,
    required this.xMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFFF4F6F8));
    if (size.width <= 1 || size.height <= 1) return;

    final railY = size.height / 2;
    canvas.drawLine(
      Offset(0, railY),
      Offset(size.width, railY),
      Paint()
        ..color = const Color(0xFFC8CED6)
        ..strokeWidth = 2,
    );

    if (pointCount > 1) {
      final maxX = math.max(1, pointCount - 1).toDouble();
      final left = xMin.clamp(0.0, maxX) / maxX * size.width;
      final right = xMax.clamp(0.0, maxX) / maxX * size.width;
      final frame = Rect.fromLTRB(
        left,
        5,
        math.max(left + 8, right),
        size.height - 5,
      );
      canvas.drawRect(
        frame,
        Paint()..color = const Color(0xFF3F6EAA).withValues(alpha: 0.16),
      );
      canvas.drawRect(
        frame,
        Paint()
          ..color = const Color(0xFF2E609E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFFB7BDC7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant PlotLocatorBarPainter oldDelegate) {
    return oldDelegate.pointCount != pointCount ||
        oldDelegate.xMin != xMin ||
        oldDelegate.xMax != xMax;
  }
}
