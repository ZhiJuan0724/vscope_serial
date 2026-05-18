/// 绘图视口管理
/// 
/// 管理可见区域和坐标转换。所有修改操作（pan/zoom/reset等）均返回新的实例，
/// 保持不可变语义。这样 PlotPainter 的 shouldRepaint 可以通过引用比较
/// 准确判断视口是否变化，避免原地修改导致的重绘失效问题。
class PlotViewport {
  /// X 轴最小值（数据点序号）
  double xMin;

  /// X 轴最大值
  double xMax;

  /// Y 轴最小值（全局）
  double yMin;

  /// Y 轴最大值（全局）
  double yMax;

  /// 是否自动缩放 Y 轴
  bool autoScaleY;

  /// 绘图区域边距
  final double marginLeft = 60;
  final double marginRight = 20;
  final double marginTop = 20;
  final double marginBottom = 40;

  /// X 轴缩放限制
  static const double minXRange = 10;
  static const double maxXRange = 600000;

  PlotViewport({
    this.xMin = 0,
    this.xMax = 1000,
    this.yMin = 0,
    this.yMax = 32768,
    this.autoScaleY = false,
  });

  /// X 轴宽度
  double get xRange => xMax - xMin;

  /// Y 轴高度
  double get yRange => yMax - yMin;

  /// 有效绘图区域宽度
  double plotWidth(double canvasWidth) => canvasWidth - marginLeft - marginRight;

  /// 有效绘图区域高度
  double plotHeight(double canvasHeight) => canvasHeight - marginTop - marginBottom;

  /// 数据 X → 屏幕 X
  double dataToScreenX(double x, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (xRange <= 0) return marginLeft;
    return marginLeft + (x - xMin) / xRange * w;
  }

  /// 数据 Y → 屏幕 Y（Y 轴向下为正，需要翻转）
  double dataToScreenY(double y, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (yRange <= 0) return marginTop + h;
    return marginTop + h - (y - yMin) / yRange * h;
  }

  /// 屏幕 X → 数据 X
  double screenToDataX(double sx, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (w <= 0) return xMin;
    return xMin + (sx - marginLeft) / w * xRange;
  }

  /// 屏幕 Y → 数据 Y
  double screenToDataY(double sy, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (h <= 0) return yMin;
    return yMin + (marginTop + h - sy) / h * yRange;
  }

  /// 判断数据点是否在可见范围内
  bool isVisibleX(double x) => x >= xMin && x <= xMax;

  /// 缩放 X 轴（以中心点为基准），返回新的视口
  PlotViewport zoomX(double factor, double centerX) {
    final oldRange = xRange;
    var newRange = oldRange * factor;

    // 限制 X 轴范围
    if (newRange < minXRange) newRange = minXRange;
    if (newRange > maxXRange) newRange = maxXRange;

    final ratio = (centerX - xMin) / oldRange;
    return copyWith(
      xMin: centerX - ratio * newRange,
      xMax: centerX + (1 - ratio) * newRange,
    );
  }

  /// 缩放 Y 轴，返回新的视口
  PlotViewport zoomY(double factor, double centerY) {
    final oldRange = yRange;
    final newRange = oldRange * factor;
    final ratio = (centerY - yMin) / oldRange;
    return copyWith(
      yMin: centerY - ratio * newRange,
      yMax: centerY + (1 - ratio) * newRange,
    );
  }

  /// 平移 X 轴，返回新的视口
  PlotViewport panX(double deltaX, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (w <= 0) return copy();
    final dx = deltaX / w * xRange;
    return copyWith(
      xMin: xMin - dx,
      xMax: xMax - dx,
    );
  }

  /// 平移 Y 轴，返回新的视口
  PlotViewport panY(double deltaY, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (h <= 0) return copy();
    final dy = deltaY / h * yRange;
    return copyWith(
      yMin: yMin + dy,
      yMax: yMax + dy,
    );
  }

  /// 重置为默认视图，返回新的视口
  PlotViewport reset() {
    return PlotViewport(
      xMin: 0,
      xMax: 1000,
      yMin: 0,
      yMax: 32768,
      autoScaleY: autoScaleY,
    );
  }

  /// 缩放到指定范围，返回新的视口
  PlotViewport zoomTo(double x1, double x2, double y1, double y2) {
    var newXRange = (x2 - x1).abs();
    if (newXRange < minXRange) newXRange = minXRange;
    if (newXRange > maxXRange) newXRange = maxXRange;

    return copyWith(
      xMin: x1 < x2 ? x1 : x2,
      xMax: (x1 < x2 ? x1 : x2) + newXRange,
      yMin: y1 < y2 ? y1 : y2,
      yMax: y1 < y2 ? y2 : y1,
    );
  }

  /// 限制 X 轴范围，返回新的视口
  PlotViewport clampX(double minAllowed, double maxAllowed) {
    double newXMin = xMin;
    double newXMax = xMax;
    if (newXMin < minAllowed) {
      final diff = minAllowed - newXMin;
      newXMin += diff;
      newXMax += diff;
    }
    if (newXMax > maxAllowed) {
      final diff = newXMax - maxAllowed;
      newXMin -= diff;
      newXMax -= diff;
    }
    if (newXMin < minAllowed) newXMin = minAllowed;
    if (newXMax > maxAllowed) newXMax = maxAllowed;
    return copyWith(xMin: newXMin, xMax: newXMax);
  }

  PlotViewport copyWith({
    double? xMin,
    double? xMax,
    double? yMin,
    double? yMax,
    bool? autoScaleY,
  }) {
    return PlotViewport(
      xMin: xMin ?? this.xMin,
      xMax: xMax ?? this.xMax,
      yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax,
      autoScaleY: autoScaleY ?? this.autoScaleY,
    );
  }

  PlotViewport copy() {
    final vp = PlotViewport(
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      autoScaleY: autoScaleY,
    );
    return vp;
  }
}
