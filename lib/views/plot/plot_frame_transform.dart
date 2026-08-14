import 'dart:ui';

import 'plot_viewport.dart';

/// 一帧绘图唯一使用的坐标描述。
///
/// Canvas、D3D11、坐标轴以及交互叠加层都必须从同一个实例换算坐标，
/// 避免逻辑像素、物理像素和动态边距分别计算后产生偏移。
class PlotFrameTransform {
  const PlotFrameTransform({
    required this.frameId,
    required this.dataRevision,
    required this.geometryGeneration,
    required this.viewport,
    required this.logicalSize,
    required this.devicePixelRatio,
  });

  final int frameId;
  final int dataRevision;
  final int geometryGeneration;
  final PlotViewport viewport;
  final Size logicalSize;
  final double devicePixelRatio;

  int get textureWidth => (logicalSize.width * devicePixelRatio).ceil();
  int get textureHeight => (logicalSize.height * devicePixelRatio).ceil();

  Rect get logicalPlotRect => Rect.fromLTRB(
    viewport.marginLeft,
    viewport.marginTop,
    logicalSize.width - viewport.marginRight,
    logicalSize.height - viewport.marginBottom,
  );

  Rect get physicalPlotRect => Rect.fromLTRB(
    logicalPlotRect.left * devicePixelRatio,
    logicalPlotRect.top * devicePixelRatio,
    logicalPlotRect.right * devicePixelRatio,
    logicalPlotRect.bottom * devicePixelRatio,
  );

  double dataToLogicalX(double value) =>
      viewport.dataToScreenX(value, logicalSize.width);

  double dataToLogicalY(double value) =>
      viewport.dataToScreenY(value, logicalSize.height);

  double logicalToDataX(double value) =>
      viewport.screenToDataX(value, logicalSize.width);

  double logicalToDataY(double value) =>
      viewport.screenToDataY(value, logicalSize.height);

  double dataToPhysicalX(double value) =>
      dataToLogicalX(value) * devicePixelRatio;

  double dataToPhysicalY(double value) =>
      dataToLogicalY(value) * devicePixelRatio;

  /// 原生着色器使用的 `screenX = dataX * scale + offset`。
  (double, double) get physicalXTransform {
    final plotWidth = logicalPlotRect.width * devicePixelRatio;
    final scale = plotWidth / viewport.xRange;
    return (scale, physicalPlotRect.left - viewport.xMin * scale);
  }

  /// 原生着色器使用的 `screenY = displayY * scale + offset`。
  (double, double) get physicalYTransform {
    final plotHeight = logicalPlotRect.height * devicePixelRatio;
    final scale = -plotHeight / viewport.yRange;
    return (scale, physicalPlotRect.bottom - viewport.yMin * scale);
  }
}
