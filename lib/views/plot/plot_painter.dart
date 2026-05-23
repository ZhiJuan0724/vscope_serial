import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/plot_data.dart';
import 'plot_viewport.dart';

/// 垂直光标状态（鼠标悬停跟随）
class CursorState {
  /// 光标 X 位置（数据坐标）
  final double x;

  /// 光标 Y 位置（数据坐标）
  final double? y;

  /// 鼠标屏幕位置（用于显示tooltip）
  final Offset? screenPosition;

  /// 各通道在光标X位置的Y值
  final List<double>? channelValues;

  /// 该X位置是否有实际数据
  final bool hasData;

  CursorState({
    required this.x,
    this.y,
    this.screenPosition,
    this.channelValues,
    this.hasData = true,
  });
}

/// 网格密度枚举
///
/// - [sparse]: 每 160px 一条线（最稀疏）
/// - [normal]: 每 80px 一条线（默认）
/// - [dense]: 每 40px 一条线（最密集）
enum GridDensity { sparse, normal, dense }

/// 绘图 CustomPainter
///
/// 接收视口、数据、通道配置等参数，在 [paint] 方法中完成所有绘制。
/// [shouldRepaint] 通过比较视口、数据长度、光标等关键属性判断是否需要重绘。
class PlotPainter extends CustomPainter {
  /// 当前绘图视口
  final PlotViewport viewport;

  /// 数据点列表
  final List<PlotDataPoint> data;

  /// 数据版本，窗口长度不变但内容滚动时也会变化
  final int dataRevision;

  /// 通道配置列表
  final List<ChannelConfig> channels;

  /// 是否显示网格
  final bool showGrid;

  /// 网格密度
  final GridDensity gridDensity;

  /// 垂直光标状态（鼠标悬停跟随）
  final CursorState? cursor;

  /// X-X 测量第一条线位置
  final double? xCursor1;

  /// X-X 测量第二条线位置
  final double? xCursor2;

  /// Y-Y 测量第一条线位置
  final double? yCursor1;

  /// Y-Y 测量第二条线位置
  final double? yCursor2;

  /// 统计测量开关
  final bool statsEnabled;

  /// 统计范围开关
  final bool statsRangeEnabled;

  /// 统计范围左边界
  final double? statsX1;

  /// 统计范围右边界
  final double? statsX2;

  /// 抗锯齿开关
  final bool antiAliasEnabled;

  PlotPainter({
    required this.viewport,
    required this.data,
    this.dataRevision = 0,
    required this.channels,
    this.showGrid = true,
    this.gridDensity = GridDensity.normal,
    this.cursor,
    this.xCursor1,
    this.xCursor2,
    this.yCursor1,
    this.yCursor2,
    this.statsEnabled = false,
    this.statsRangeEnabled = false,
    this.statsX1,
    this.statsX2,
    this.antiAliasEnabled = true,
  });

  /// 判断两个视口是否相等（用于重绘判断）
  bool _viewportEquals(PlotViewport a, PlotViewport b) {
    return a.xMin == b.xMin &&
        a.xMax == b.xMax &&
        a.yMin == b.yMin &&
        a.yMax == b.yMax;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制层次：背景 → 网格 → 数据 → 坐标轴 → 光标 → 统计范围
    _drawBackground(canvas, size);

    if (showGrid) {
      _drawGrid(canvas, size);
    }

    _drawChannels(canvas, size);
    _drawAxes(canvas, size);

    // 通道偏移基准线和标签（绘制在数据层之上，坐标轴之下）
    _drawChannelOffsetBaselines(canvas, size);

    // 垂直光标（鼠标悬停跟随）
    _drawCursor(canvas, size);

    // X-X 测量线（独立绘制，不依赖 cursor）
    if (xCursor1 != null || xCursor2 != null) {
      _drawXMeasurement(
        canvas,
        size,
        xCursor1,
        xCursor2,
        viewport.plotHeight(size.height),
      );
    }

    // Y-Y 测量线（独立绘制，不依赖 cursor）
    if (yCursor1 != null || yCursor2 != null) {
      _drawYMeasurement(
        canvas,
        size,
        yCursor1,
        yCursor2,
        viewport.plotWidth(size.width),
      );
    }

    // 统计范围框（独立绘制）
    if (statsEnabled &&
        statsRangeEnabled &&
        statsX1 != null &&
        statsX2 != null) {
      _drawStatsRange(canvas, size);
    }
  }

  /// 绘制深色背景
  void _drawBackground(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = const Color(0xFF1A1A2E)
          ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  /// 绘制网格线和 Y=0 基准线
  void _drawGrid(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = const Color(0xFF2D2D44)
          ..strokeWidth = 0.5
          ..style = PaintingStyle.stroke
          ..isAntiAlias = antiAliasEnabled;

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    // 计算网格间距
    final xGridCount = _calculateGridCount(plotW, 80);
    final yGridCount = _calculateGridCount(plotH, 60);

    // 批量绘制网格线：先收集所有线，用 drawRawPoints 或 Path 优化
    final gridPath = Path();

    // 垂直网格线
    for (int i = 0; i <= xGridCount; i++) {
      final x = PlotViewport().marginLeft + plotW * i / xGridCount;
      gridPath.moveTo(x, PlotViewport().marginTop);
      gridPath.lineTo(x, PlotViewport().marginTop + plotH);
    }

    // 水平网格线
    for (int i = 0; i <= yGridCount; i++) {
      final y = PlotViewport().marginTop + plotH * i / yGridCount;
      gridPath.moveTo(PlotViewport().marginLeft, y);
      gridPath.lineTo(PlotViewport().marginLeft + plotW, y);
    }

    canvas.drawPath(gridPath, paint);
  }

  /// 根据网格密度计算网格间距（像素）
  double _getGridSpacing() {
    return switch (gridDensity) {
      GridDensity.sparse => 160, // 稀疏: 每160px一条线
      GridDensity.normal => 80, // 普通: 每80px一条线
      GridDensity.dense => 40, // 密集: 每40px一条线
    };
  }

  int _calculateGridCount(double length, double minSpacing) {
    final densitySpacing = _getGridSpacing();
    final effectiveSpacing =
        minSpacing > densitySpacing ? minSpacing : densitySpacing;
    final count = (length / effectiveSpacing).floor();
    if (count < 2) return 2;
    if (count > 50) return 50; // 密集模式上限更高
    return count;
  }

  /// 缓存的可见数据范围，避免每帧重复二分查找
  _Range? _cachedVisibleRange;

  /// 缓存视口引用，用于判断缓存是否有效
  PlotViewport? _cachedViewport;

  /// 绘制所有可见通道的数据波形
  ///
  /// 1. 获取可见范围内的数据索引（带缓存）
  /// 2. 根据像素宽度计算降采样步长
  /// 3. 逐通道批量绘制（Path + 点）
  void _drawChannels(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    // 找到可见范围内的数据索引（缓存）
    final visibleIndices = _getVisibleRange();
    if (visibleIndices.start >= visibleIndices.end) return;

    // 降采样：缩小时按像素桶保留 min/max，避免构建超长 Path。
    final plotW = viewport.plotWidth(size.width);
    final dataCount = visibleIndices.end - visibleIndices.start;
    final useMinMaxBuckets = dataCount > plotW * 2;

    // 批量绘制：先收集所有通道的 Path，减少 Canvas 状态切换
    for (int ch = 0; ch < channels.length; ch++) {
      final channel = channels[ch];
      if (!channel.visible) continue;
      if (ch >= data.first.values.length) continue;

      _drawChannelOptimized(
        canvas,
        size,
        ch,
        channel,
        visibleIndices,
        useMinMaxBuckets,
      );
    }
  }

  /// 获取可见数据范围（带缓存）
  _Range _getVisibleRange() {
    if (_cachedVisibleRange != null &&
        _cachedViewport != null &&
        _viewportEquals(_cachedViewport!, viewport)) {
      return _cachedVisibleRange!;
    }
    _cachedVisibleRange = _findVisibleRange();
    _cachedViewport = viewport.copy();
    return _cachedVisibleRange!;
  }

  /// 优化绘制单个通道的数据
  ///
  /// - 预分配固定大小点列表，避免动态扩容
  /// - Y 值限制在绘图区域内
  /// - 根据配置绘制连线和/或点
  void _drawChannelOptimized(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    bool useMinMaxBuckets,
  ) {
    final visibleCount = visibleRange.end - visibleRange.start;
    if (channel.showLine && visibleCount > 1) {
      final linePaint =
          Paint()
            ..color = channel.color
            ..strokeWidth = channel.lineWidth
            ..style = PaintingStyle.stroke
            ..isAntiAlias = antiAliasEnabled;

      if (useMinMaxBuckets) {
        _drawChannelMinMaxBuckets(
          canvas,
          size,
          channelIndex,
          channel,
          visibleRange,
          linePaint,
        );
      } else {
        _drawChannelRawPath(
          canvas,
          size,
          channelIndex,
          channel,
          visibleRange,
          linePaint,
        );
      }
    }

    final plotW = viewport.plotWidth(size.width);
    final hidePointsForDenseLine =
        channel.showLine && visibleCount > math.max(1, plotW).round();
    if (!hidePointsForDenseLine) {
      final pointPaint =
          Paint()
            ..color = channel.color
            ..style = PaintingStyle.fill;

      _drawChannelPoints(
        canvas,
        size,
        channelIndex,
        channel,
        visibleRange,
        pointPaint,
      );
    }
  }

  void _drawChannelRawPath(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    Paint paint,
  ) {
    final path = Path();
    var hasPoint = false;
    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    for (int i = visibleRange.start; i < visibleRange.end; i++) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;
      final x = viewport.dataToScreenX(point.index.toDouble(), size.width);
      final y = _screenY(
        point,
        channelIndex,
        channel,
        size.height,
      ).clamp(marginTop, marginBottom);
      if (hasPoint) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        hasPoint = true;
      }
    }

    if (hasPoint) {
      canvas.drawPath(path, paint);
    }
  }

  void _drawChannelMinMaxBuckets(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    Paint paint,
  ) {
    final plotW = viewport.plotWidth(size.width);
    final dataCount = visibleRange.end - visibleRange.start;
    if (dataCount <= 0 || plotW <= 0) return;

    final bucketCount = math.min(plotW.ceil(), dataCount);
    final rawPoints = Float32List(bucketCount * 8);
    var rawIndex = 0;
    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    for (int bucket = 0; bucket < bucketCount; bucket++) {
      final start = visibleRange.start + (bucket * dataCount ~/ bucketCount);
      var end = visibleRange.start + ((bucket + 1) * dataCount ~/ bucketCount);
      if (end <= start) end = start + 1;

      _BucketPoint? firstPoint;
      _BucketPoint? lastPoint;
      _BucketPoint? minPoint;
      _BucketPoint? maxPoint;
      for (int i = start; i < end && i < visibleRange.end; i++) {
        final point = data[i];
        if (channelIndex >= point.values.length) continue;
        final x = viewport.dataToScreenX(point.index.toDouble(), size.width);
        final y = _screenY(
          point,
          channelIndex,
          channel,
          size.height,
        ).clamp(marginTop, marginBottom);

        final bucketPoint = _BucketPoint(point.index, x, y);
        firstPoint ??= bucketPoint;
        lastPoint = bucketPoint;
        if (minPoint == null || y < minPoint.y) minPoint = bucketPoint;
        if (maxPoint == null || y > maxPoint.y) maxPoint = bucketPoint;
      }

      if (firstPoint == null || lastPoint == null) continue;
      final ordered = <_BucketPoint>[
        firstPoint,
        if (minPoint != null) minPoint,
        if (maxPoint != null) maxPoint,
        lastPoint,
      ]..sort((a, b) => a.index.compareTo(b.index));

      var previousIndex = -1;
      for (final point in ordered) {
        if (point.index == previousIndex) continue;
        rawPoints[rawIndex++] = point.x;
        rawPoints[rawIndex++] = point.y;
        previousIndex = point.index;
      }
    }

    if (rawIndex >= 4) {
      canvas.drawRawPoints(
        ui.PointMode.polygon,
        Float32List.sublistView(rawPoints, 0, rawIndex),
        paint,
      );
    }
  }

  void _drawChannelPoints(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    Paint paint,
  ) {
    final plotW = viewport.plotWidth(size.width);
    final dataCount = visibleRange.end - visibleRange.start;
    final step = dataCount > plotW * 2 ? (dataCount / (plotW * 2)).ceil() : 1;
    final rawPoints = Float32List(((dataCount / step).ceil() + 1) * 2);
    var rawIndex = 0;
    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    for (int i = visibleRange.start; i < visibleRange.end; i += step) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;
      rawPoints[rawIndex++] = viewport.dataToScreenX(
        point.index.toDouble(),
        size.width,
      );
      rawPoints[rawIndex++] = _screenY(
        point,
        channelIndex,
        channel,
        size.height,
      ).clamp(marginTop, marginBottom);
    }

    if (rawIndex > 0) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.sublistView(rawPoints, 0, rawIndex),
        paint..strokeWidth = channel.pointSize,
      );
    }
  }

  double _screenY(
    PlotDataPoint point,
    int channelIndex,
    ChannelConfig channel,
    double height,
  ) {
    return viewport.dataToScreenY(
      point.values[channelIndex] * channel.yScale + channel.yOffset,
      height,
    );
  }

  /// 绘制坐标轴、刻度线和刻度值
  void _drawAxes(Canvas canvas, Size size) {
    final axisPaint =
        Paint()
          ..color = const Color(0xFF8888AA)
          ..strokeWidth = 1.0;

    final textStyle = const TextStyle(
      color: Color(0xFF8888AA),
      fontSize: 12,
      fontFamily: 'monospace',
    );

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    // X 轴
    canvas.drawLine(
      Offset(
        PlotViewport().marginLeft,
        size.height - PlotViewport().marginBottom,
      ),
      Offset(
        size.width - PlotViewport().marginRight,
        size.height - PlotViewport().marginBottom,
      ),
      axisPaint,
    );

    // Y 轴
    canvas.drawLine(
      Offset(PlotViewport().marginLeft, PlotViewport().marginTop),
      Offset(
        PlotViewport().marginLeft,
        size.height - PlotViewport().marginBottom,
      ),
      axisPaint,
    );

    // X 轴刻度
    final xGridCount = _calculateGridCount(plotW, 80);
    for (int i = 0; i <= xGridCount; i++) {
      final xRatio = i / xGridCount;
      final x = PlotViewport().marginLeft + plotW * xRatio;
      final xValue = viewport.xMin + viewport.xRange * xRatio;

      // 刻度线
      canvas.drawLine(
        Offset(x, size.height - PlotViewport().marginBottom),
        Offset(x, size.height - PlotViewport().marginBottom + 5),
        axisPaint,
      );

      // 刻度值
      _drawText(
        canvas,
        _formatNumber(xValue, false),
        Offset(x, size.height - PlotViewport().marginBottom + 8),
        textStyle,
        alignCenter: true,
      );
    }

    // Y 轴刻度（使用 nice number 取整）
    final yGridCount = _calculateGridCount(plotH, 60);
    final roughStep = viewport.yRange / yGridCount;
    final integerYValues = _visibleYValuesAreInteger();
    final step = _niceNumber(
      integerYValues ? math.max(1.0, roughStep) : roughStep,
      true,
    );
    final Set<double> drawnValues = {};
    if (step > 0) {
      final startValue = (viewport.yMin / step).floor() * step;
      for (
        double value = startValue;
        value <= viewport.yMax + step * 0.5;
        value += step
      ) {
        if (value < viewport.yMin || value > viewport.yMax) continue;

        final y = viewport.dataToScreenY(value, size.height);
        if (y < PlotViewport().marginTop ||
            y > PlotViewport().marginTop + plotH) {
          continue;
        }

        drawnValues.add(value);

        // 刻度线
        canvas.drawLine(
          Offset(PlotViewport().marginLeft - 5, y),
          Offset(PlotViewport().marginLeft, y),
          axisPaint,
        );

        // 刻度值
        _drawText(
          canvas,
          _formatNumber(value, true),
          Offset(PlotViewport().marginLeft - 8, y),
          textStyle,
          alignRight: true,
          alignVerticalCenter: true,
        );
      }
    }

    // 常驻 Y=0 刻度（如果 0 在可见范围内且尚未绘制）
    if (viewport.yMin <= 0 &&
        viewport.yMax >= 0 &&
        !drawnValues.contains(0.0)) {
      final zeroY = viewport.dataToScreenY(0, size.height);
      if (zeroY >= PlotViewport().marginTop &&
          zeroY <= PlotViewport().marginTop + plotH) {
        // 刻度线（稍长，突出显示）
        canvas.drawLine(
          Offset(PlotViewport().marginLeft - 8, zeroY),
          Offset(PlotViewport().marginLeft, zeroY),
          axisPaint,
        );

        // 刻度值：Y=0（加粗）
        final zeroTextStyle = const TextStyle(
          color: Color(0xFFCCCCDD),
          fontSize: 12,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
        );
        _drawText(
          canvas,
          '0',
          Offset(PlotViewport().marginLeft - 8, zeroY),
          zeroTextStyle,
          alignRight: true,
          alignVerticalCenter: true,
        );
      }
    }
  }

  /// 绘制通道偏移基准线、标签和独立 Y 轴
  ///
  /// 为每个开启偏移功能的可见通道：
  /// - 绘制水平虚线表示该通道的 Y=0 位置
  /// - 在左侧绘制可拖动标签（通道颜色背景 + 名称）
  /// - 在右侧绘制独立的 Y 轴刻度（颜色与通道一致，密度受全局网格设置影响）
  /// - 多通道时分多列显示，每列向右偏移 [PlotViewport.offsetAxisColumnWidth]
  void _drawChannelOffsetBaselines(Canvas canvas, Size size) {
    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);
    final left = PlotViewport().marginLeft;
    final right = left + plotW;

    // 收集所有可见且开启偏移的通道，分配列索引
    final offsetChannels = <ChannelConfig>[];
    for (final ch in channels) {
      if (ch.visible && ch.offsetEnabled) {
        offsetChannels.add(ch);
      }
    }

    for (int colIndex = 0; colIndex < offsetChannels.length; colIndex++) {
      final ch = offsetChannels[colIndex];

      // 该通道 Y=0 的屏幕位置（数据值 0 经过 yScale 和 yOffset 后的位置）
      final zeroDataY = 0.0 * ch.yScale + ch.yOffset;
      final zeroY = viewport.dataToScreenY(zeroDataY, size.height);

      // 标签和基准线只在 Y=0 位置在绘图区域内时绘制
      final labelVisible =
          zeroY >= PlotViewport().marginTop &&
          zeroY <= PlotViewport().marginTop + plotH;

      if (labelVisible) {
        // 绘制水平虚线（通道颜色，半透明）
        final dashPaint =
            Paint()
              ..color = ch.color.withValues(alpha: 0.4)
              ..strokeWidth = 1.0;

        const dashLen = 6.0;
        const gapLen = 4.0;
        var x = left;
        while (x < right) {
          final endX = (x + dashLen).clamp(left, right);
          canvas.drawLine(Offset(x, zeroY), Offset(endX, zeroY), dashPaint);
          x += dashLen + gapLen;
        }

        // 绘制左侧标签。完整通道名称放到图例中，这里只保留短编号。
        final displayName = 'Ch${ch.index}';
        final labelStyle = TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        );

        // 标签背景
        const labelPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 1);
        final textSpan = TextSpan(text: displayName, style: labelStyle);
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        final labelW = textPainter.width + labelPadding.horizontal;
        final labelH = textPainter.height + labelPadding.vertical;
        final labelX = left - labelW - 2;
        final labelY = zeroY - labelH / 2;

        // 标签背景圆角矩形
        final bgRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(labelX, labelY, labelW, labelH),
          const Radius.circular(2),
        );
        canvas.drawRRect(bgRect, Paint()..color = ch.color);

        // 标签文字
        textPainter.paint(
          canvas,
          Offset(labelX + labelPadding.left, labelY + labelPadding.top),
        );
      }

      // 绘制右侧独立 Y 轴刻度（多列，每列向右偏移）—— 始终绘制，不依赖标签可见性
      final axisX = right + colIndex * PlotViewport.offsetAxisColumnWidth;
      _drawChannelYAxis(canvas, size, ch, axisX);
    }
  }

  /// 绘制单个通道的独立 Y 轴刻度
  ///
  /// 在绘图区右侧绘制该通道的 Y 轴刻度线和刻度值，
  /// 刻度密度受全局网格设置影响，刻度值取整为 nice number。
  void _drawChannelYAxis(
    Canvas canvas,
    Size size,
    ChannelConfig ch,
    double axisX,
  ) {
    final plotH = viewport.plotHeight(size.height);
    final top = PlotViewport().marginTop;
    final bottom = top + plotH;

    // 计算 nice number 步长
    final yRange = viewport.yRange;
    final yGridCount = _calculateGridCount(plotH, 60);
    final roughStep = yRange / yGridCount;
    final step = _niceNumber(roughStep, true);
    if (step <= 0) return;

    final tickPaint =
        Paint()
          ..color = ch.color.withValues(alpha: 0.6)
          ..strokeWidth = 0.5;

    final textStyle = TextStyle(
      color: ch.color,
      fontSize: 11,
      fontFamily: 'monospace',
    );

    // 第一个刻度值：从 yMin 向上取整到 step 的倍数
    final startValue = (viewport.yMin / step).floor() * step;
    final Set<double> drawnValues = {};

    for (
      double value = startValue;
      value <= viewport.yMax + step * 0.5;
      value += step
    ) {
      if (value < viewport.yMin || value > viewport.yMax) continue;

      // 该刻度值对应的屏幕 Y（数据坐标 → 屏幕坐标）
      final y = viewport.dataToScreenY(value, size.height);
      if (y < top || y > bottom) continue;

      drawnValues.add(value);

      // 还原为原始数据值：(显示值 - yOffset) / yScale
      final originalValue = (value - ch.yOffset) / ch.yScale;

      // 刻度线（向右伸出）
      canvas.drawLine(Offset(axisX, y), Offset(axisX + 5, y), tickPaint);

      // 刻度值
      _drawText(
        canvas,
        _formatNumber(originalValue, true),
        Offset(axisX + 7, y),
        textStyle,
        alignVerticalCenter: true,
      );
    }

    // 常驻 Y=0 刻度（强制绘制，即使 0 不在 nice number 序列中）
    // 注意：这里判断的是"显示值"0（即数据值 y=0 在视口坐标系中的位置）
    // 而不是原始数据值 0，因为偏置通道的刻度显示的是视口坐标系中的值
    final zeroScreenY = viewport.dataToScreenY(0, size.height);
    if (zeroScreenY >= top &&
        zeroScreenY <= bottom &&
        !drawnValues.contains(0.0)) {
      // 还原为原始数据值
      final originalZeroValue = (0.0 - ch.yOffset) / ch.yScale;

      // 刻度线（稍长，突出显示）
      canvas.drawLine(
        Offset(axisX, zeroScreenY),
        Offset(axisX + 8, zeroScreenY),
        tickPaint,
      );

      // 刻度值（加粗）
      final zeroTextStyle = TextStyle(
        color: ch.color,
        fontSize: 11,
        fontFamily: 'monospace',
        fontWeight: FontWeight.bold,
      );
      _drawText(
        canvas,
        _formatNumber(originalZeroValue, true),
        Offset(axisX + 10, zeroScreenY),
        zeroTextStyle,
        alignVerticalCenter: true,
      );
    }

    // 绘制轴线
    final axisPaint =
        Paint()
          ..color = ch.color.withValues(alpha: 0.3)
          ..strokeWidth = 1.0;
    canvas.drawLine(Offset(axisX, top), Offset(axisX, bottom), axisPaint);
  }

  /// 绘制垂直光标（鼠标悬停跟随）
  void _drawCursor(Canvas canvas, Size size) {
    if (cursor == null) return;

    final cursorPaint =
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;

    final sx = viewport.dataToScreenX(cursor!.x, size.width);
    canvas.drawLine(
      Offset(sx, PlotViewport().marginTop),
      Offset(sx, size.height - PlotViewport().marginBottom),
      cursorPaint,
    );
    _drawCursorTooltip(canvas, size, sx);
  }

  /// 绘制垂直光标旁的各通道 Y 值 tooltip
  ///
  /// - 无数据（hasData=false）时整个 tooltip 不显示
  /// - 只显示有数据且 visible 的通道，不显示 "ChX: --"
  /// - 字体已放大以便阅读
  void _drawCursorTooltip(Canvas canvas, Size size, double sx) {
    if (cursor?.screenPosition == null) return;

    final screenPos = cursor!.screenPosition!;
    final hasData = cursor!.hasData;

    // 无数据时不显示tooltip
    if (!hasData) return;

    // 获取通道值（如果有数据）
    List<double>? values = cursor?.channelValues;

    // 确定要显示的通道数：只显示有数据且可见的通道
    const valueStyle = TextStyle(fontSize: 12, fontFamily: 'monospace');
    final rows = <_CursorValueRow>[];
    if (values != null && values.isNotEmpty) {
      // 只统计有数据且visible的通道数
      for (int i = 0; i < values.length && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        final displayName =
            channels[i].alias.isNotEmpty ? channels[i].alias : 'Ch$i';
        rows.add(
          _CursorValueRow(
            index: i,
            text: '$displayName: ${_formatExactNumber(values[i])}',
          ),
        );
      }
    }

    if (rows.isEmpty) return;

    // 计算tooltip尺寸
    const lineHeight = 20.0;
    const padding = 8.0;
    final maxLabelWidth = rows.fold<double>(120, (width, row) {
      return math.max(width, _measureTextWidth(row.text, valueStyle));
    });
    final tooltipWidth = math.min(size.width - 10, maxLabelWidth + padding * 2);
    final tooltipHeight = rows.length * lineHeight + padding * 2 + 22;

    // tooltip位置（在鼠标右侧，如果超出边界则在左侧）
    var tooltipX = screenPos.dx + 18;
    var tooltipY = screenPos.dy + 18;

    // 边界检查
    if (tooltipX + tooltipWidth > size.width - 5) {
      tooltipX = screenPos.dx - tooltipWidth - 10;
    }
    if (tooltipY + tooltipHeight > size.height - 5) {
      tooltipY = screenPos.dy - tooltipHeight - 10;
    }
    tooltipX = tooltipX.clamp(5.0, size.width - tooltipWidth - 5);
    tooltipY = tooltipY.clamp(5.0, size.height - tooltipHeight - 5);

    // 绘制背景
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tooltipX, tooltipY, tooltipWidth, tooltipHeight),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = const Color(0xEE1A1A2E)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = const Color(0xFF8888AA)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // 绘制标题（X值）
    final headerStyle = const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );
    _drawText(
      canvas,
      'X: ${cursor!.x.toInt()}',
      Offset(tooltipX + padding, tooltipY + padding),
      headerStyle,
    );

    // 绘制分隔线（往下移，给标题更多空间）
    canvas.drawLine(
      Offset(tooltipX + padding, tooltipY + padding + 17),
      Offset(tooltipX + tooltipWidth - padding, tooltipY + padding + 17),
      Paint()
        ..color = const Color(0xFF8888AA)
        ..strokeWidth = 0.5,
    );

    // 绘制各通道值（只显示有数据且visible的通道）
    int row = 0;
    for (final rowValue in rows) {
      // 只显示有数据值的通道，跳过数据范围外的
      final y = tooltipY + padding + 22 + row * lineHeight;
      final color = channels[rowValue.index].color;

      // 颜色指示点
      canvas.drawCircle(
        Offset(tooltipX + padding + 4, y + 5),
        3,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );

      // 通道名和值（优先显示别名）
      final rowStyle = TextStyle(
        color: color,
        fontSize: 12,
        fontFamily: 'monospace',
      );
      _drawText(
        canvas,
        rowValue.text,
        Offset(tooltipX + padding + 12, y),
        rowStyle,
      );

      row++;
    }
  }

  /// 绘制文本，支持水平居中、右对齐、垂直居中
  void _drawText(
    Canvas canvas,
    String text,
    Offset position,
    TextStyle style, {
    bool alignCenter = false,
    bool alignRight = false,
    bool alignVerticalCenter = false,
  }) {
    final textSpan = TextSpan(text: text, style: style);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    var dx = position.dx;
    if (alignCenter) {
      dx -= textPainter.width / 2;
    } else if (alignRight) {
      dx -= textPainter.width;
    }

    var dy = position.dy;
    if (alignVerticalCenter) {
      // 让文字几何中心与 position.dy 对齐
      dy -= textPainter.height / 2;
    }

    textPainter.paint(canvas, Offset(dx, dy));
  }

  double _measureTextWidth(String text, TextStyle style) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return textPainter.width + 12;
  }

  /// 将值取整到 "好看" 的数字（1, 2, 5, 10, 20, 50, 100...）
  double _niceNumber(double value, bool round) {
    if (value <= 0) return 0;
    final exponent = (math.log(value) / math.ln10).floor();
    final fraction = value / math.pow(10, exponent);

    double niceFraction;
    if (round) {
      if (fraction < 1.5) {
        niceFraction = 1;
      } else if (fraction < 3) {
        niceFraction = 2;
      } else if (fraction < 7) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    } else {
      if (fraction <= 1) {
        niceFraction = 1;
      } else if (fraction <= 2) {
        niceFraction = 2;
      } else if (fraction <= 5) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    }
    return niceFraction * math.pow(10, exponent);
  }

  /// 格式化刻度数值
  ///
  /// - X 轴：始终显示整数
  /// - Y 轴：绝对值>1000或接近整数时显示整数，否则保留合适精度
  String _formatNumber(double value, bool isY) {
    // X 轴：全局不显示小数
    if (!isY) {
      return value.toInt().toString();
    }

    final absValue = value.abs();

    // 整数直接显示
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    // 根据大小决定精度
    if (absValue >= 100) {
      return value.toStringAsFixed(0);
    }
    if (absValue >= 1) {
      return value.toStringAsFixed(1);
    }
    if (absValue >= 0.01) {
      return value.toStringAsFixed(2);
    }
    return value.toStringAsFixed(3);
  }

  String _formatExactNumber(double value) {
    if (!value.isFinite) return value.toString();
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  bool _visibleYValuesAreInteger() {
    var hasValue = false;
    for (final point in data) {
      if (point.index < viewport.xMin || point.index > viewport.xMax) continue;
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        final channel = channels[i];
        if (!channel.visible) continue;
        final value = point.values[i] * channel.yScale + channel.yOffset;
        hasValue = true;
        if ((value - value.roundToDouble()).abs() > 1e-9) {
          return false;
        }
      }
    }
    return hasValue;
  }

  // ========== X-X / Y-Y 测量绘制 ==========
  /// 绘制 X-X 测量两条垂直线及标签
  void _drawXMeasurement(
    Canvas canvas,
    Size size,
    double? x1,
    double? x2,
    double plotH,
  ) {
    if (x1 == null && x2 == null) return;

    final line1Paint =
        Paint()
          ..color = Colors.cyan
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
    final line2Paint =
        Paint()
          ..color = Colors.yellow
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;

    // 第一条线
    if (x1 != null) {
      final sx1 = viewport.dataToScreenX(x1, size.width);
      if (sx1 >= PlotViewport().marginLeft &&
          sx1 <= size.width - PlotViewport().marginRight) {
        canvas.drawLine(
          Offset(sx1, PlotViewport().marginTop),
          Offset(sx1, PlotViewport().marginTop + plotH),
          line1Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'X1',
          sx1,
          PlotViewport().marginTop + 10,
          Colors.cyan,
        );
      }
    }

    // 第二条线
    if (x2 != null) {
      final sx2 = viewport.dataToScreenX(x2, size.width);
      if (sx2 >= PlotViewport().marginLeft &&
          sx2 <= size.width - PlotViewport().marginRight) {
        canvas.drawLine(
          Offset(sx2, PlotViewport().marginTop),
          Offset(sx2, PlotViewport().marginTop + plotH),
          line2Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'X2',
          sx2,
          PlotViewport().marginTop + 10,
          Colors.yellow,
        );
      }
    }
  }

  /// 绘制 Y-Y 测量两条水平线及标签
  void _drawYMeasurement(
    Canvas canvas,
    Size size,
    double? y1,
    double? y2,
    double plotW,
  ) {
    if (y1 == null && y2 == null) return;

    final line1Paint =
        Paint()
          ..color = Colors.cyan
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
    final line2Paint =
        Paint()
          ..color = Colors.yellow
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;

    // 第一条线
    if (y1 != null) {
      final sy1 = viewport.dataToScreenY(y1, size.height);
      if (sy1 >= PlotViewport().marginTop &&
          sy1 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, sy1),
          Offset(PlotViewport().marginLeft + plotW, sy1),
          line1Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'Y1',
          PlotViewport().marginLeft + 10,
          sy1,
          Colors.cyan,
        );
      }
    }

    // 第二条线
    if (y2 != null) {
      final sy2 = viewport.dataToScreenY(y2, size.height);
      if (sy2 >= PlotViewport().marginTop &&
          sy2 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, sy2),
          Offset(PlotViewport().marginLeft + plotW, sy2),
          line2Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'Y2',
          PlotViewport().marginLeft + 10,
          sy2,
          Colors.yellow,
        );
      }
    }
  }

  /// 绘制测量线标签（带背景框）
  void _drawMeasurementLabel(
    Canvas canvas,
    String label,
    double x,
    double y,
    Color color,
  ) {
    final textStyle = TextStyle(
      color: color,
      fontSize: 10,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );
    final textSpan = TextSpan(text: label, style: textStyle);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // 背景
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        x - textPainter.width / 2 - 3,
        y - textPainter.height / 2 - 2,
        textPainter.width + 6,
        textPainter.height + 4,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = const Color(0xDD1A1A2E)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = color
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    textPainter.paint(
      canvas,
      Offset(x - textPainter.width / 2, y - textPainter.height / 2),
    );
  }

  /// 通过二分查找确定可见范围内的数据索引
  ///
  /// 数据按 index 递增排序，使用二分查找定位起始和结束位置。
  _Range _findVisibleRange() {
    int start = 0;
    int end = data.length;

    // 二分查找起始位置
    int left = 0, right = data.length - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (data[mid].index < viewport.xMin) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    start = left.clamp(0, data.length);

    // 二分查找结束位置
    left = 0;
    right = data.length - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (data[mid].index <= viewport.xMax) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    end = left.clamp(0, data.length);

    return _Range(start, end);
  }

  /// 绘制统计测量范围框（半透明高亮区域 + 虚线边界 + S1/S2 标签）
  void _drawStatsRange(Canvas canvas, Size size) {
    final sx1 = viewport
        .dataToScreenX(statsX1!, size.width)
        .clamp(
          PlotViewport().marginLeft,
          size.width - PlotViewport().marginRight,
        );
    final sx2 = viewport
        .dataToScreenX(statsX2!, size.width)
        .clamp(
          PlotViewport().marginLeft,
          size.width - PlotViewport().marginRight,
        );

    if ((sx2 - sx1).abs() < 2) return;

    final left = sx1 < sx2 ? sx1 : sx2;
    final right = sx1 < sx2 ? sx2 : sx1;

    final rect = Rect.fromLTRB(
      left,
      PlotViewport().marginTop,
      right,
      size.height - PlotViewport().marginBottom,
    );

    // 半透明填充
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.green.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );

    // 左右边界虚线
    final borderPaint =
        Paint()
          ..color = Colors.green.withValues(alpha: 0.5)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;

    // 左边界
    _drawDashedLine(
      canvas,
      Offset(left, PlotViewport().marginTop),
      Offset(left, size.height - PlotViewport().marginBottom),
      borderPaint,
    );
    // 右边界
    _drawDashedLine(
      canvas,
      Offset(right, PlotViewport().marginTop),
      Offset(right, size.height - PlotViewport().marginBottom),
      borderPaint,
    );

    // 绘制 S1/S2 标签（底部，带背景框）
    _drawMeasurementLabel(
      canvas,
      'S1',
      left,
      size.height - PlotViewport().marginBottom - 10,
      Colors.green,
    );
    _drawMeasurementLabel(
      canvas,
      'S2',
      right,
      size.height - PlotViewport().marginBottom - 10,
      Colors.green,
    );
  }

  /// 绘制虚线（5px 实线 + 3px 间隙）
  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    const dashLength = 5.0;
    const gapLength = 3.0;
    final dashCount = (distance / (dashLength + gapLength)).floor();

    for (int i = 0; i < dashCount; i++) {
      final t1 = i * (dashLength + gapLength) / distance;
      final t2 = (i * (dashLength + gapLength) + dashLength) / distance;
      canvas.drawLine(
        Offset(start.dx + dx * t1, start.dy + dy * t1),
        Offset(
          start.dx + dx * t2.clamp(0.0, 1.0),
          start.dy + dy * t2.clamp(0.0, 1.0),
        ),
        paint,
      );
    }
  }

  /// 判断是否需要重绘
  ///
  /// 比较视口、数据长度、光标、网格、统计范围等关键属性。
  @override
  bool shouldRepaint(covariant PlotPainter oldDelegate) {
    final viewportChanged = !_viewportEquals(oldDelegate.viewport, viewport);
    final dataChanged = oldDelegate.data.length != data.length;
    final dataRevisionChanged = oldDelegate.dataRevision != dataRevision;
    final result =
        viewportChanged ||
        dataChanged ||
        dataRevisionChanged ||
        oldDelegate.cursor != cursor ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.statsEnabled != statsEnabled ||
        oldDelegate.statsRangeEnabled != statsRangeEnabled ||
        oldDelegate.statsX1 != statsX1 ||
        oldDelegate.statsX2 != statsX2;
    final cursorChanged =
        oldDelegate.cursor != cursor ||
        oldDelegate.xCursor1 != xCursor1 ||
        oldDelegate.xCursor2 != xCursor2 ||
        oldDelegate.yCursor1 != yCursor1 ||
        oldDelegate.yCursor2 != yCursor2;
    return result || cursorChanged;
  }
}

/// 数据索引范围
///
/// [start] 包含，[end] 不包含（左闭右开）。
class _Range {
  final int start;
  final int end;
  _Range(this.start, this.end);
}

class _BucketPoint {
  final int index;
  final double x;
  final double y;

  const _BucketPoint(this.index, this.x, this.y);
}

class _CursorValueRow {
  final int index;
  final String text;

  const _CursorValueRow({required this.index, required this.text});
}
