import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/app_logger.dart';
import 'plot_painter.dart';
import 'plot_viewport.dart';

/// 绘图手势处理器
///
/// 负责处理绘图区域的所有用户交互：
/// - **鼠标滚轮缩放**：普通滚轮缩放 X 轴，Shift+滚轮根据鼠标位置缩放 X/Y 轴
/// - **拖拽平移**：鼠标左键拖动平移视口
/// - **框选放大**：开启框选模式后，鼠标左键拖拽框选区域并放大
/// - **垂直光标悬停**：鼠标移动时更新垂直光标位置
/// - **测量线拖动**：点击并拖动 X-X/Y-Y 测量线标签或统计范围标签
///
/// 拖动使用 [Listener] 的原始指针事件（onPointerDown/Move/Up）而非 [GestureDetector] 的 pan，
/// 避免 GestureDetector 在快速移动时合并/丢帧导致拖动距离丢失的问题。
class PlotGestureHandler extends StatefulWidget {
  /// 当前绘图视口
  final PlotViewport viewport;
  /// 视口变化回调（缩放、平移、框选放大）
  ///
  /// [fromDrag] 为 true 时表示来自用户拖动，回调方可据此优化通知策略。
  final void Function(PlotViewport viewport, {bool fromDrag}) onViewportChanged;
  /// 拖动结束回调
  ///
  /// 平移拖动结束时调用，用于保存视口配置和历史记录。
  final VoidCallback? onDragEnd;
  /// 光标变化回调（悬停、测量线拖动）
  final void Function(CursorState? cursor) onCursorChanged;
  /// 单垂直光标开关
  final bool vCursorEnabled;
  /// 框选放大模式开关
  final bool boxZoomEnabled;
  /// 子组件（通常是 CustomPaint）
  final Widget child;
  /// X-X 测量第一条线位置（用于拖动检测）
  final double? xCursor1;
  /// X-X 测量第二条线位置
  final double? xCursor2;
  /// Y-Y 测量第一条线位置
  final double? yCursor1;
  /// Y-Y 测量第二条线位置
  final double? yCursor2;
  /// 统计范围左边界
  final double? statsX1;
  /// 统计范围右边界
  final double? statsX2;
  /// X1 测量线拖动回调
  final void Function(double x)? onXCursor1Drag;
  /// X2 测量线拖动回调
  final void Function(double x)? onXCursor2Drag;
  /// Y1 测量线拖动回调
  final void Function(double y)? onYCursor1Drag;
  /// Y2 测量线拖动回调
  final void Function(double y)? onYCursor2Drag;
  /// S1 统计范围拖动回调
  final void Function(double x)? onStatsX1Drag;
  /// S2 统计范围拖动回调
  final void Function(double x)? onStatsX2Drag;
  /// 目标刷新帧率（fps），与高级设置中的绘图刷新帧率同步
  final int refreshFps;

  const PlotGestureHandler({
    super.key,
    required this.viewport,
    required this.onViewportChanged,
    required this.onCursorChanged,
    this.vCursorEnabled = false,
    this.boxZoomEnabled = false,
    this.onDragEnd,
    required this.child,
    this.xCursor1,
    this.xCursor2,
    this.yCursor1,
    this.yCursor2,
    this.statsX1,
    this.statsX2,
    this.onXCursor1Drag,
    this.onXCursor2Drag,
    this.onYCursor1Drag,
    this.onYCursor2Drag,
    this.onStatsX1Drag,
    this.onStatsX2Drag,
    this.refreshFps = 30,
  });

  @override
  State<PlotGestureHandler> createState() => _PlotGestureHandlerState();
}

/// 测量线拖动目标枚举
///
/// 标识当前正在拖动的测量线或统计范围边界。
enum _DragTarget { none, xCursor1, xCursor2, yCursor1, yCursor2, statsX1, statsX2 }

/// [PlotGestureHandler] 的状态类
///
/// 管理拖动状态、框选状态、测量线拖动目标等。
class _PlotGestureHandlerState extends State<PlotGestureHandler> {
  /// 是否正在拖拽平移
  bool _isDragging = false;
  /// 是否正在框选
  bool _isBoxSelecting = false;
  /// 上次指针位置（用于计算拖拽 delta）
  Offset? _lastPosition;
  /// 框选起始位置
  Offset? _boxStart;
  /// 框选结束位置
  Offset? _boxEnd;
  /// 当前拖动的测量线目标
  _DragTarget _dragTarget = _DragTarget.none;

  /// 拖动期间的本地视口副本
  ///
  /// 避免在快速拖动时依赖 widget.viewport 的实时更新。
  PlotViewport? _dragViewport;

  /// 上次通知 UI 重绘的视口（用于节流）
  PlotViewport? _lastNotifiedViewport;
  /// 上次通知时间戳
  int _lastNotifyTime = 0;
  /// 目标刷新帧率（fps），由外部传入，与高级设置同步
  int _targetFps = 30;

  /// 标签尺寸（与 PlotPainter 中一致，用于命中检测）
  static const double _labelWidth = 28;
  static const double _labelHeight = 20;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: _handleHover,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
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
    );
  }

  /// 处理指针信号（鼠标滚轮缩放）
  ///
  /// - 普通滚轮：以鼠标位置为中心缩放 X 轴
  /// - Shift+滚轮：根据鼠标所在区域（Y轴区/X轴区/绘图区）缩放对应轴
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
      // final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;

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
      // 普通滚轮 = X 轴缩放
      else {
        final centerX = widget.viewport.screenToDataX(localPosition.dx, size.width);
        newViewport = newViewport.zoomX(zoomFactor, centerX);
      }

      widget.onViewportChanged(newViewport, fromDrag: false);
    }
  }

  /// 处理鼠标悬停（更新垂直光标）
  ///
  /// 当 [vCursorEnabled] 开启时，将鼠标位置转换为数据坐标并回调。
  void _handleHover(PointerHoverEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    final x = widget.viewport.screenToDataX(event.localPosition.dx, size.width);
    final y = widget.viewport.screenToDataY(event.localPosition.dy, size.height);

    // 单垂直光标优先（通过开关控制）
    if (widget.vCursorEnabled) {
      // 使用 WidgetsBinding 避免在指针事件回调中直接触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onCursorChanged(CursorState(
          x: x,
          y: y,
          mode: CursorMode.follow,
          screenPosition: event.localPosition,
        ));
      });
      return;
    }


  }

  // ===== 原始指针事件处理拖动 =====
  // 使用 Listener 而非 GestureDetector，避免 pan 事件在快速移动时被合并/丢帧

  /// 处理指针按下（开始拖动或框选）
  ///
  /// 优先检测是否点击在测量标签上（开始测量线拖动），
  /// 否则根据框选模式开始框选或平移。
  void _handlePointerDown(PointerDownEvent event) {
    // 只处理鼠标左键（kPrimaryButton）
    if (event.buttons != kPrimaryButton) return;

    // 检测是否点击在测量标签上
    final dragTarget = _hitTestMeasurementLabel(event.localPosition);
    if (dragTarget != _DragTarget.none) {
      _dragTarget = dragTarget;
      _isDragging = true;
      _lastPosition = event.localPosition;
      AppLogger().trace('测量拖动开始: target=$_dragTarget, pos=${event.localPosition}', category: 'GESTURE');
      return;
    }

    if (widget.boxZoomEnabled) {
      _isBoxSelecting = true;
      _boxStart = event.localPosition;
      _boxEnd = event.localPosition;
      AppLogger().trace('框选开始: pos=${event.localPosition}', category: 'GESTURE');
    } else {
      _isDragging = true;
      _lastPosition = event.localPosition;
      _dragViewport = widget.viewport.copy();
      _lastNotifiedViewport = _dragViewport!.copy();
      _lastNotifyTime = DateTime.now().millisecondsSinceEpoch;
      _targetFps = widget.refreshFps.clamp(10, 60);
      AppLogger().trace('平移拖动开始: pos=${event.localPosition}, viewport xMin=${_dragViewport!.xMin}, targetFps=$_targetFps', category: 'GESTURE');
    }
  }

  /// 检测点击位置是否在测量标签上
  ///
  /// 直接检查各测量线位置是否存在，不再依赖 cursorMode，
  /// 支持 X-X 和 Y-Y 同时开启的情况。
  /// 检测顺序：X-X 标签（顶部）→ Y-Y 标签（左侧）→ 统计范围标签（底部）。
  _DragTarget _hitTestMeasurementLabel(Offset pos) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return _DragTarget.none;

    // X-X 测量：检测 X1/X2 标签（标签在测量线顶部）
    if (widget.xCursor1 != null || widget.xCursor2 != null) {
      final topY = PlotViewport().marginTop + 10;
      if ((pos.dy - topY).abs() < _labelHeight / 2 + 6) {
        if (widget.xCursor1 != null) {
          final sx1 = widget.viewport.dataToScreenX(widget.xCursor1!, size.width);
          if ((pos.dx - sx1).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.xCursor1;
          }
        }
        if (widget.xCursor2 != null) {
          final sx2 = widget.viewport.dataToScreenX(widget.xCursor2!, size.width);
          if ((pos.dx - sx2).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.xCursor2;
          }
        }
      }
    }

    // Y-Y 测量：检测 Y1/Y2 标签（标签在测量线左侧）
    if (widget.yCursor1 != null || widget.yCursor2 != null) {
      final leftX = PlotViewport().marginLeft + 10;
      if ((pos.dx - leftX).abs() < _labelWidth / 2 + 6) {
        if (widget.yCursor1 != null) {
          final sy1 = widget.viewport.dataToScreenY(widget.yCursor1!, size.height);
          if ((pos.dy - sy1).abs() < _labelHeight / 2 + 6) {
            return _DragTarget.yCursor1;
          }
        }
        if (widget.yCursor2 != null) {
          final sy2 = widget.viewport.dataToScreenY(widget.yCursor2!, size.height);
          if ((pos.dy - sy2).abs() < _labelHeight / 2 + 6) {
            return _DragTarget.yCursor2;
          }
        }
      }
    }

    // 统计范围：检测 S1/S2 标签（标签在底部）
    if (widget.statsX1 != null || widget.statsX2 != null) {
      final bottomY = size.height - PlotViewport().marginBottom - 10;
      if ((pos.dy - bottomY).abs() < _labelHeight / 2 + 6) {
        if (widget.statsX1 != null) {
          final sx1 = widget.viewport.dataToScreenX(widget.statsX1!, size.width);
          if ((pos.dx - sx1).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.statsX1;
          }
        }
        if (widget.statsX2 != null) {
          final sx2 = widget.viewport.dataToScreenX(widget.statsX2!, size.width);
          if ((pos.dx - sx2).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.statsX2;
          }
        }
      }
    }

    return _DragTarget.none;
  }

  /// 处理指针移动（拖拽平移、框选、测量线拖动）
  void _handlePointerMove(PointerMoveEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    if (_isBoxSelecting) {
      _boxEnd = event.localPosition;
      if (mounted) setState(() {});
    } else if (_isDragging && _lastPosition != null) {
      // 拖动测量标签
      if (_dragTarget != _DragTarget.none) {
        _handleMeasurementDrag(event.localPosition, size);
        _lastPosition = event.localPosition;
        return;
      }

      final dx = event.localPosition.dx - _lastPosition!.dx;
      final dy = event.localPosition.dy - _lastPosition!.dy;
      _lastPosition = event.localPosition;

      // 使用本地视口副本进行累积平移，避免依赖 widget.viewport 的实时更新
      _dragViewport = _dragViewport!.panX(dx, size.width);
      _dragViewport = _dragViewport!.panY(dy, size.height);

      // 节流：根据目标帧率计算间隔，与高级设置同步
      final notifyIntervalMs = (1000 / _targetFps).round();
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - _lastNotifyTime;
      final viewportChanged = _lastNotifiedViewport == null ||
          (_lastNotifiedViewport!.xMin - _dragViewport!.xMin).abs() > 1.0 ||
          (_lastNotifiedViewport!.yMin - _dragViewport!.yMin).abs() > 1.0;

      if (elapsed >= notifyIntervalMs && viewportChanged) {
        _lastNotifiedViewport = _dragViewport!.copy();
        _lastNotifyTime = now;
        AppLogger().trace('平移拖动通知: dx=$dx,dy=$dy | viewport xMin=${_dragViewport!.xMin.toStringAsFixed(1)} | elapsed=${elapsed}ms', category: 'GESTURE');
        widget.onViewportChanged(_dragViewport!, fromDrag: true);
      }
    }
  }

  /// 处理测量线拖动，根据 [_dragTarget] 将屏幕坐标转换为数据坐标并回调
  ///
  /// X 轴测量线和统计范围线吸附到整数（数据点索引），Y 轴保留原始精度。
  void _handleMeasurementDrag(Offset pos, Size size) {
    switch (_dragTarget) {
      case _DragTarget.xCursor1:
        if (widget.onXCursor1Drag != null && widget.xCursor1 != null) {
          final x = widget.viewport.screenToDataX(
            pos.dx.clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight),
            size.width,
          );
          widget.onXCursor1Drag!(x.round().toDouble());
        }
        break;
      case _DragTarget.xCursor2:
        if (widget.onXCursor2Drag != null && widget.xCursor2 != null) {
          final x = widget.viewport.screenToDataX(
            pos.dx.clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight),
            size.width,
          );
          widget.onXCursor2Drag!(x.round().toDouble());
        }
        break;
      case _DragTarget.yCursor1:
        if (widget.onYCursor1Drag != null && widget.yCursor1 != null) {
          final y = widget.viewport.screenToDataY(
            pos.dy.clamp(PlotViewport().marginTop, size.height - PlotViewport().marginBottom),
            size.height,
          );
          // Y-Y 不吸附，保留原始精度
          widget.onYCursor1Drag!(y);
        }
        break;
      case _DragTarget.yCursor2:
        if (widget.onYCursor2Drag != null && widget.yCursor2 != null) {
          final y = widget.viewport.screenToDataY(
            pos.dy.clamp(PlotViewport().marginTop, size.height - PlotViewport().marginBottom),
            size.height,
          );
          // Y-Y 不吸附，保留原始精度
          widget.onYCursor2Drag!(y);
        }
        break;
      case _DragTarget.statsX1:
        if (widget.onStatsX1Drag != null && widget.statsX1 != null) {
          final x = widget.viewport.screenToDataX(
            pos.dx.clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight),
            size.width,
          );
          widget.onStatsX1Drag!(x.round().toDouble());
        }
        break;
      case _DragTarget.statsX2:
        if (widget.onStatsX2Drag != null && widget.statsX2 != null) {
          final x = widget.viewport.screenToDataX(
            pos.dx.clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight),
            size.width,
          );
          widget.onStatsX2Drag!(x.round().toDouble());
        }
        break;
      case _DragTarget.none:
        break;
    }
  }

  /// 处理指针抬起（结束框选并应用放大，或结束拖动）
  ///
  /// 框选结束时，将框选区域转换为数据坐标并回调 [onViewportChanged]。
  void _handlePointerUp(PointerUpEvent event) {
    AppLogger().trace('拖动结束: box=$_isBoxSelecting, drag=$_isDragging, target=$_dragTarget', category: 'GESTURE');

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

      widget.onViewportChanged(newViewport, fromDrag: false);
    }

    if (_isDragging && _dragTarget == _DragTarget.none && _dragViewport != null) {
      // 平移拖动结束，确保最终视口被应用并保存
      widget.onViewportChanged(_dragViewport!, fromDrag: true);
      widget.onDragEnd?.call();
    }
    _isDragging = false;
    _isBoxSelecting = false;
    _lastPosition = null;
    _boxStart = null;
    _boxEnd = null;
    _dragTarget = _DragTarget.none;
    _dragViewport = null;
    _lastNotifiedViewport = null;
    if (mounted) setState(() {});
  }

}

/// 框选区域绘制器
///
/// 在框选过程中实时绘制半透明蓝色矩形，显示当前框选范围。
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
