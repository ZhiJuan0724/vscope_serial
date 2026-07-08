part of '../plot_page.dart';

/// 绘图区域上的可拖拽信息浮层和观察点浮层。
class _DraggableInfoBox extends StatefulWidget {
  final double initialRight;
  final double initialTop;
  final Color backgroundColor;
  final Color borderColor;
  final void Function(double right, double top)? onPositionChanged;
  final Widget child;

  const _DraggableInfoBox({
    super.key,
    required this.initialRight,
    required this.initialTop,
    required this.backgroundColor,
    required this.borderColor,
    this.onPositionChanged,
    required this.child,
  });

  @override
  State<_DraggableInfoBox> createState() => _DraggableInfoBoxState();
}

class _DraggableObservationBox extends StatefulWidget {
  final double initialLeft;
  final double initialTop;
  final Widget child;

  const _DraggableObservationBox({
    super.key,
    required this.initialLeft,
    required this.initialTop,
    required this.child,
  });

  @override
  State<_DraggableObservationBox> createState() =>
      _DraggableObservationBoxState();
}

class _DraggableObservationBoxState extends State<_DraggableObservationBox> {
  double? _left;
  double? _top;
  bool _isDragging = false;
  Offset? _dragStart;
  double? _dragStartLeft;
  double? _dragStartTop;

  @override
  Widget build(BuildContext context) {
    final left = _left ?? widget.initialLeft;
    final top = _top ?? widget.initialTop;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          _isDragging = true;
          _dragStart = details.globalPosition;
          _dragStartLeft = left;
          _dragStartTop = top;
        },
        onPanUpdate: (details) {
          if (!_isDragging || _dragStart == null) return;
          final dx = details.globalPosition.dx - _dragStart!.dx;
          final dy = details.globalPosition.dy - _dragStart!.dy;
          setState(() {
            _left = (_dragStartLeft! + dx).clamp(0.0, double.infinity);
            _top = (_dragStartTop! + dy).clamp(0.0, double.infinity);
          });
        },
        onPanEnd: (_) => _isDragging = false,
        onPanCancel: () => _isDragging = false,
        child: widget.child,
      ),
    );
  }
}

/// [_DraggableInfoBox] 的状态类
class _DraggableInfoBoxState extends State<_DraggableInfoBox> {
  /// 当前右边距（null 时使用初始值）
  double? _right;

  /// 当前上边距（null 时使用初始值）
  double? _top;

  /// 是否正在拖动
  bool _isDragging = false;

  /// 拖动起始指针位置
  Offset? _dragStart;

  /// 拖动起始右边距
  double? _dragStartRight;

  /// 拖动起始上边距
  double? _dragStartTop;

  @override
  Widget build(BuildContext context) {
    final right = _right ?? widget.initialRight;
    final top = _top ?? widget.initialTop;

    return Positioned(
      right: right,
      top: top,
      child: GestureDetector(
        onPanStart: (details) {
          _isDragging = true;
          _dragStart = details.globalPosition;
          _dragStartRight = right;
          _dragStartTop = top;
        },
        onPanUpdate: (details) {
          if (!_isDragging || _dragStart == null) return;
          final dx = _dragStart!.dx - details.globalPosition.dx;
          final dy = details.globalPosition.dy - _dragStart!.dy;
          setState(() {
            _right = (_dragStartRight! + dx).clamp(0.0, double.infinity);
            _top = (_dragStartTop! + dy).clamp(0.0, double.infinity);
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
          child: IntrinsicHeight(child: widget.child),
        ),
      ),
    );
  }

  void _finishDrag() {
    _isDragging = false;
    final right = _right;
    final top = _top;
    if (right != null && top != null) {
      widget.onPositionChanged?.call(right, top);
    }
  }
}
