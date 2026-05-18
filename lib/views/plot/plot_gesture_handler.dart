import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'plot_painter.dart';
import 'plot_viewport.dart';

/// 绘图手势处理器
/// 
/// 处理鼠标滚轮缩放、拖拽平移、框选放大、垂直光标悬停。
/// 
/// 拖动使用 Listener 的原始指针事件（onPointerDown/Move/Up）而非 GestureDetector 的 pan，
/// 避免 GestureDetector 在快速移动时合并/丢帧导致拖动距离丢失的问题。
class PlotGestureHandler extends StatefulWidget {
  final PlotViewport viewport;
  final void Function(PlotViewport viewport) onViewportChanged;
  final void Function(CursorState? cursor) onCursorChanged;
  final CursorMode cursorMode;
  final bool vCursorEnabled;
  final bool boxZoomEnabled;
  final Widget child;

  const PlotGestureHandler({
    super.key,
    required this.viewport,
    required this.onViewportChanged,
    required this.onCursorChanged,
    this.cursorMode = CursorMode.none,
    this.vCursorEnabled = false,
    this.boxZoomEnabled = false,
    required this.child,
  });

  @override
  State<PlotGestureHandler> createState() => _PlotGestureHandlerState();
}

class _PlotGestureHandlerState extends State<PlotGestureHandler> {
  bool _isDragging = false;
  bool _isBoxSelecting = false;
  Offset? _lastPosition;
  Offset? _boxStart;
  Offset? _boxEnd;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _handlePointerSignal,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      child: MouseRegion(
        onHover: _handleHover,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: _handleDoubleTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_isBoxSelecting && _boxStart != null && _boxEnd != null)
                CustomPaint(
                  painter: _BoxSelectionPainter(
                    start: _boxStart!,
                    end: _boxEnd!,
                  ),
                  size: Size.infinite,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
      final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;

      final size = context.size ?? Size.zero;
      if (size.isEmpty) return;

      final localPosition = event.localPosition;
      final zoomFactor = event.scrollDelta.dy > 0 ? 1.1 : 0.9;

      // 判断鼠标位置：在 Y 轴区域（左侧边距）还是 X 轴区域（底部边距）或绘图区
      final inYAxisArea = localPosition.dx < widget.viewport.marginLeft;
      final inXAxisArea = localPosition.dy > size.height - widget.viewport.marginBottom;

      var newViewport = widget.viewport;

      // Shift + 滚轮：根据鼠标位置决定缩放轴
      if (isShiftPressed) {
        if (inYAxisArea) {
          // 鼠标在 Y 轴区域 -> 缩放 Y 轴
          final centerY = widget.viewport.screenToDataY(localPosition.dy, size.height);
          newViewport = newViewport.zoomY(zoomFactor, centerY);
        } else if (inXAxisArea) {
          // 鼠标在 X 轴区域 -> 缩放 X 轴
          final centerX = widget.viewport.screenToDataX(localPosition.dx, size.width);
          newViewport = newViewport.zoomX(zoomFactor, centerX);
        } else {
          // 鼠标在绘图区 -> 同时缩放 X 和 Y
          final centerX = widget.viewport.screenToDataX(localPosition.dx, size.width);
          final centerY = widget.viewport.screenToDataY(localPosition.dy, size.height);
          newViewport = newViewport.zoomX(zoomFactor, centerX);
          newViewport = newViewport.zoomY(zoomFactor, centerY);
        }
      }
      // Ctrl + 滚轮 = 缩放 X 轴
      else if (isCtrlPressed) {
        final centerX = widget.viewport.screenToDataX(localPosition.dx, size.width);
        newViewport = newViewport.zoomX(zoomFactor, centerX);
      }
      // 普通滚轮 = X 轴缩放
      else {
        final centerX = widget.viewport.screenToDataX(localPosition.dx, size.width);
        newViewport = newViewport.zoomX(zoomFactor, centerX);
      }

      widget.onViewportChanged(newViewport);
    }
  }

  void _handleHover(PointerHoverEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    final x = widget.viewport.screenToDataX(event.localPosition.dx, size.width);
    final y = widget.viewport.screenToDataY(event.localPosition.dy, size.height);

    // 单垂直光标优先（通过开关控制）
    if (widget.vCursorEnabled) {
      widget.onCursorChanged(CursorState(
        x: x,
        y: y,
        mode: CursorMode.follow,
        screenPosition: event.localPosition,
      ));
      return;
    }

    switch (widget.cursorMode) {
      case CursorMode.xCursor:
        // x-x 光标：点击放置第一条线，再次点击放置第二条线
        break;
      case CursorMode.yCursor:
        // y-y 光标
        break;
      case CursorMode.none:
      case CursorMode.follow:
        // 不处理
        break;
    }
  }

  // ===== 原始指针事件处理拖动 =====
  // 使用 Listener 而非 GestureDetector，避免 pan 事件在快速移动时被合并/丢帧
  
  void _handlePointerDown(PointerDownEvent event) {
    // 只处理鼠标左键（kPrimaryButton）
    if (event.buttons != kPrimaryButton) return;

    if (widget.boxZoomEnabled) {
      _isBoxSelecting = true;
      _boxStart = event.localPosition;
      _boxEnd = event.localPosition;
    } else {
      _isDragging = true;
      _lastPosition = event.localPosition;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    if (_isBoxSelecting) {
      setState(() {
        _boxEnd = event.localPosition;
      });
    } else if (_isDragging && _lastPosition != null) {
      final dx = event.localPosition.dx - _lastPosition!.dx;
      final dy = event.localPosition.dy - _lastPosition!.dy;
      _lastPosition = event.localPosition;

      // 实时更新视口
      var newViewport = widget.viewport.panX(dx, size.width);
      newViewport = newViewport.panY(dy, size.height);
      widget.onViewportChanged(newViewport);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_isBoxSelecting && _boxStart != null && _boxEnd != null) {
      final size = context.size ?? Size.zero;
      if (size.isEmpty) return;

      // 计算框选区域的数据坐标
      final x1 = widget.viewport.screenToDataX(
        _boxStart!.dx.clamp(
          PlotViewport().marginLeft,
          size.width - PlotViewport().marginRight,
        ),
        size.width,
      );
      final x2 = widget.viewport.screenToDataX(
        _boxEnd!.dx.clamp(
          PlotViewport().marginLeft,
          size.width - PlotViewport().marginRight,
        ),
        size.width,
      );
      final y1 = widget.viewport.screenToDataY(
        _boxStart!.dy.clamp(
          PlotViewport().marginTop,
          size.height - PlotViewport().marginBottom,
        ),
        size.height,
      );
      final y2 = widget.viewport.screenToDataY(
        _boxEnd!.dy.clamp(
          PlotViewport().marginTop,
          size.height - PlotViewport().marginBottom,
        ),
        size.height,
      );

      // 放大到框选区域
      final newViewport = widget.viewport.zoomTo(
        x1 < x2 ? x1 : x2,
        x1 < x2 ? x2 : x1,
        y1 < y2 ? y1 : y2,
        y1 < y2 ? y2 : y1,
      );

      widget.onViewportChanged(newViewport);
    }

    setState(() {
      _isDragging = false;
      _isBoxSelecting = false;
      _lastPosition = null;
      _boxStart = null;
      _boxEnd = null;
    });
  }

  void _handleDoubleTap() {
    final newViewport = widget.viewport.reset();
    widget.onViewportChanged(newViewport);
  }
}

/// 框选区域绘制
class _BoxSelectionPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  _BoxSelectionPainter({required this.start, required this.end});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);

    // 填充
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill,
    );

    // 边框
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
