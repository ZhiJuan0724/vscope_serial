import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'plot_viewport.dart';

/// 定位条两端为选区描边预留的可视空间。
const double kPlotLocatorHorizontalPadding = 6;

double _locatorTrackInset(double width) {
  return math.min(kPlotLocatorHorizontalPadding, math.max(0, (width - 1) / 2));
}

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
    final inset = _locatorTrackInset(width);
    final trackWidth = math.max(1.0, width - inset * 2);
    return ((screenX - inset) / trackWidth * maxX).clamp(0.0, maxX);
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
                  : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp:
                (details) => widget.onNavigate(
                  _dataX(details.localPosition.dx, constraints.maxWidth),
                  fromDrag: false,
                ),
            onPanStart: (details) {
              // 整条轨道都是拖动热区，避免数据量很大时窗口块
              // 缩成几个像素后难以准确按中。
              if (!_draggingFrame) setState(() => _draggingFrame = true);
              widget.onNavigate(
                _dataX(details.localPosition.dx, constraints.maxWidth),
                fromDrag: true,
              );
            },
            onPanUpdate: (details) {
              if (!_draggingFrame) return;
              widget.onNavigate(
                _dataX(details.localPosition.dx, constraints.maxWidth),
                fromDrag: true,
              );
            },
            onPanEnd: (_) => _finishDrag(),
            onPanCancel: _finishDrag,
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
    final trackInset = _locatorTrackInset(size.width);
    final trackRight = size.width - trackInset;
    canvas.drawLine(
      Offset(trackInset, railY),
      Offset(trackRight, railY),
      Paint()
        ..color = const Color(0xFFC8CED6)
        ..strokeWidth = 2,
    );

    final frame = frameRectForSize(size);
    if (frame != null) {
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

  /// 计算完整位于有效轨道内的视口框，确保两端描边不会被裁切。
  @visibleForTesting
  Rect? frameRectForSize(Size size) {
    if (pointCount <= 1 || size.width <= 1 || size.height <= 1) return null;

    final maxX = math.max(1, pointCount - 1).toDouble();
    final trackInset = _locatorTrackInset(size.width);
    final trackRight = size.width - trackInset;
    final trackWidth = math.max(1.0, trackRight - trackInset);
    final mappedLeft = trackInset + xMin.clamp(0.0, maxX) / maxX * trackWidth;
    final mappedRight = trackInset + xMax.clamp(0.0, maxX) / maxX * trackWidth;
    final minimumWidth = math.min(8.0, trackWidth);
    final desiredLeft = math.min(mappedLeft, mappedRight);
    final desiredRight = math.max(mappedLeft, mappedRight);

    if (desiredRight - desiredLeft >= minimumWidth) {
      return Rect.fromLTRB(desiredLeft, 5, desiredRight, size.height - 5);
    }

    final center = (desiredLeft + desiredRight) / 2;
    final left =
        (center - minimumWidth / 2)
            .clamp(trackInset, trackRight - minimumWidth)
            .toDouble();
    return Rect.fromLTRB(left, 5, left + minimumWidth, size.height - 5);
  }

  @override
  bool shouldRepaint(covariant PlotLocatorBarPainter oldDelegate) {
    return oldDelegate.pointCount != pointCount ||
        oldDelegate.xMin != xMin ||
        oldDelegate.xMax != xMax;
  }
}
