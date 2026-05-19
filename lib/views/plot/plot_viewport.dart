/// 绘图视口管理
///
/// 管理可见的数据区域和屏幕/数据坐标转换。
///
/// 设计原则：
/// - 所有修改操作（pan/zoom/reset 等）均返回新的实例，保持不可变语义
/// - [PlotPainter.shouldRepaint] 可通过引用比较准确判断视口是否变化
/// - 避免原地修改导致的重绘失效问题
class PlotViewport {
  /// X 轴最小值（数据点序号）
  double xMin;

  /// X 轴最大值（数据点序号）
  double xMax;

  /// Y 轴最小值（数据坐标）
  double yMin;

  /// Y 轴最大值（数据坐标）
  double yMax;

  /// 是否自动缩放 Y 轴（预留功能）
  bool autoScaleY;

  /// 绘图区域左边距（留给 Y 轴刻度）
  final double marginLeft = 60;
  /// 绘图区域右边距
  final double marginRight = 20;
  /// 绘图区域上边距
  final double marginTop = 20;
  /// 绘图区域下边距（留给 X 轴刻度）
  final double marginBottom = 40;

  /// X 轴最小显示范围
  static const double minXRange = 10;
  /// X 轴最大显示范围
  static const double maxXRange = 600000;
  /// Y 轴最小显示范围
  static const double minYRange = 1;
  /// Y 轴最大显示范围
  static const double maxYRange = 1000000000;

  /// 创建视口，使用默认值（X: 0~1000, Y: 0~32768）
  PlotViewport({
    this.xMin = 0,
    this.xMax = 1000,
    this.yMin = 0,
    this.yMax = 32768,
    this.autoScaleY = false,
  });

  /// X 轴显示范围宽度
  double get xRange => xMax - xMin;

  /// Y 轴显示范围高度
  double get yRange => yMax - yMin;

  /// 有效绘图区域宽度（去除边距）
  double plotWidth(double canvasWidth) => canvasWidth - marginLeft - marginRight;

  /// 有效绘图区域高度（去除边距）
  double plotHeight(double canvasHeight) => canvasHeight - marginTop - marginBottom;

  /// 数据 X 坐标 → 屏幕 X 坐标
  double dataToScreenX(double x, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (xRange <= 0) return marginLeft;
    return marginLeft + (x - xMin) / xRange * w;
  }

  /// 数据 Y 坐标 → 屏幕 Y 坐标（Y 轴向下为正，需要翻转）
  double dataToScreenY(double y, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (yRange <= 0) return marginTop + h;
    return marginTop + h - (y - yMin) / yRange * h;
  }

  /// 屏幕 X 坐标 → 数据 X 坐标
  double screenToDataX(double sx, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (w <= 0) return xMin;
    return xMin + (sx - marginLeft) / w * xRange;
  }

  /// 屏幕 Y 坐标 → 数据 Y 坐标
  double screenToDataY(double sy, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (h <= 0) return yMin;
    return yMin + (marginTop + h - sy) / h * yRange;
  }

  /// 判断 X 坐标是否在可见范围内
  bool isVisibleX(double x) => x >= xMin && x <= xMax;

  /// 以指定中心点缩放 X 轴，返回新的视口
  ///
  /// [factor] < 1 为放大，> 1 为缩小。结果受 [minXRange] 和 [maxXRange] 限制。
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

  /// 以指定中心点缩放 Y 轴，返回新的视口
  ///
  /// [factor] < 1 为放大，> 1 为缩小。结果受 [minYRange] 和 [maxYRange] 限制。
  PlotViewport zoomY(double factor, double centerY) {
    final oldRange = yRange;
    var newRange = oldRange * factor;

    // 限制 Y 轴范围
    if (newRange < minYRange) newRange = minYRange;
    if (newRange > maxYRange) newRange = maxYRange;

    final ratio = (centerY - yMin) / oldRange;
    return copyWith(
      yMin: centerY - ratio * newRange,
      yMax: centerY + (1 - ratio) * newRange,
    );
  }

  /// 水平平移 X 轴，返回新的视口
  ///
  /// [deltaX] 为屏幕像素位移，正数向右平移（数据向左移动）。
  PlotViewport panX(double deltaX, double canvasWidth) {
    final w = plotWidth(canvasWidth);
    if (w <= 0) return copy();
    final dx = deltaX / w * xRange;
    return copyWith(
      xMin: xMin - dx,
      xMax: xMax - dx,
    );
  }

  /// 垂直平移 Y 轴，返回新的视口
  ///
  /// [deltaY] 为屏幕像素位移，正数向下平移（数据向上移动）。
  PlotViewport panY(double deltaY, double canvasHeight) {
    final h = plotHeight(canvasHeight);
    if (h <= 0) return copy();
    final dy = deltaY / h * yRange;
    return copyWith(
      yMin: yMin + dy,
      yMax: yMax + dy,
    );
  }

  /// 重置为默认视图（X: 0~1000, Y: 0~32768），返回新的视口
  PlotViewport reset() {
    return PlotViewport(
      xMin: 0,
      xMax: 1000,
      yMin: 0,
      yMax: 32768,
      autoScaleY: autoScaleY,
    );
  }

  /// 缩放到指定的数据范围，返回新的视口
  ///
  /// 用于框选放大功能。X 轴范围受 [minXRange] 和 [maxXRange] 限制。
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

  /// 将 X 轴限制在允许范围内，返回新的视口
  ///
  /// 如果视口超出边界，整体平移使其回到边界内。
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

  /// 复制视口并修改指定属性，返回新的实例
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

  /// 创建视口的深拷贝
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
