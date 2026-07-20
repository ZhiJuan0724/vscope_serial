import 'package:flutter/material.dart';

import 'plot_painter.dart';

/// 只订阅冻结渲染快照的四层绘图组件。
///
/// 页面手势和浮层不会进入该组件；各层依靠自身 revision 独立判断重绘。
class PlotLayerStack extends StatelessWidget {
  const PlotLayerStack({required this.snapshot, super.key});

  final PlotRenderSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final layer in PlotPaintLayer.values)
          RepaintBoundary(
            key: ValueKey<String>('plot-layer-${layer.name}'),
            child: CustomPaint(
              painter: PlotLayerPainter.fromSnapshot(
                layer: layer,
                snapshot: snapshot,
              ),
              size: Size.infinite,
            ),
          ),
      ],
    );
  }
}
