part of '../plot_page.dart';

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
