import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/plot_data.dart';
import 'plot_viewport.dart';

/// 光标状态
class CursorState {
  /// 光标 X 位置（数据坐标）
  final double x;

  /// 光标 Y 位置（数据坐标）
  final double? y;

  /// 光标模式
  final CursorMode mode;

  /// x-x 光标的第二条线位置
  final double? xCursor2;

  /// y-y 光标的第二条线位置
  final double? yCursor2;

  /// 鼠标屏幕位置（用于显示tooltip）
  final Offset? screenPosition;

  /// 各通道在光标X位置的Y值
  final List<double>? channelValues;

  /// 该X位置是否有实际数据
  final bool hasData;

  CursorState({
    required this.x,
    this.y,
    required this.mode,
    this.xCursor2,
    this.yCursor2,
    this.screenPosition,
    this.channelValues,
    this.hasData = true,
  });

  /// 计算 deltaX（x-x 光标）
  double? get deltaX => xCursor2 != null ? (xCursor2! - x).abs() : null;

  /// 计算 deltaY（y-y 光标）
  double? get deltaY => yCursor2 != null && y != null ? (yCursor2! - y!).abs() : null;
}

enum CursorMode { none, follow, xCursor, yCursor }

/**
 * 网格密度枚举
 *
 * - [sparse]: 每 160px 一条线（最稀疏）
 * - [normal]: 每 80px 一条线（默认）
 * - [dense]: 每 40px 一条线（最密集）
 */
enum GridDensity { sparse, normal, dense }

/**
 * 绘图 CustomPainter
 *
 * 接收视口、数据、通道配置等参数，在 [paint] 方法中完成所有绘制。
 * [shouldRepaint] 通过比较视口、数据长度、光标等关键属性判断是否需要重绘。
 */
class PlotPainter extends CustomPainter {
  /// 当前绘图视口
  final PlotViewport viewport;
  /// 数据点列表
  final List<PlotDataPoint> data;
  /// 通道配置列表
  final List<ChannelConfig> channels;
  /// 是否显示网格
  final bool showGrid;
  /// 网格密度
  final GridDensity gridDensity;
  /// 光标状态
  final CursorState? cursor;
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
    required this.channels,
    this.showGrid = true,
    this.gridDensity = GridDensity.normal,
    this.cursor,
    this.statsEnabled = false,
    this.statsRangeEnabled = false,
    this.statsX1,
    this.statsX2,
    this.antiAliasEnabled = true,
  });

  /// 判断两个视口是否相等（用于重绘判断）
  bool _viewportEquals(PlotViewport a, PlotViewport b) {
    return a.xMin == b.xMin && a.xMax == b.xMax && a.yMin == b.yMin && a.yMax == b.yMax;
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
    _drawCursor(canvas, size);

    if (statsEnabled && statsRangeEnabled && statsX1 != null && statsX2 != null) {
      _drawStatsRange(canvas, size);
    }
  }

  /// 绘制深色背景
  void _drawBackground(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  /// 绘制网格线和 Y=0 基准线
  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2D2D44)
      ..strokeWidth = 0.5
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

    // Y=0 基准线（高亮显示）
    if (viewport.yMin <= 0 && viewport.yMax >= 0) {
      final zeroY = viewport.dataToScreenY(0, size.height);
      // 确保在绘图区域内
      if (zeroY >= PlotViewport().marginTop && zeroY <= PlotViewport().marginTop + plotH) {
        final zeroPaint = Paint()
          ..color = const Color(0xFF666688)
          ..strokeWidth = 1.5;
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, zeroY),
          Offset(PlotViewport().marginLeft + plotW, zeroY),
          zeroPaint,
        );
      }
    }
  }

  /// 根据网格密度计算网格间距（像素）
  double _getGridSpacing() {
    return switch (gridDensity) {
      GridDensity.sparse => 160,  // 稀疏: 每160px一条线
      GridDensity.normal => 80,   // 普通: 每80px一条线
      GridDensity.dense => 40,    // 密集: 每40px一条线
    };
  }

  int _calculateGridCount(double length, double minSpacing) {
    final densitySpacing = _getGridSpacing();
    final effectiveSpacing = minSpacing > densitySpacing ? minSpacing : densitySpacing;
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

    // 降采样：根据像素宽度决定采样步长
    final plotW = viewport.plotWidth(size.width);
    final dataCount = visibleIndices.end - visibleIndices.start;
    final step = dataCount > plotW * 2 ? (dataCount / (plotW * 2)).ceil() : 1;

    // 批量绘制：先收集所有通道的 Path，减少 Canvas 状态切换
    for (int ch = 0; ch < channels.length; ch++) {
      final channel = channels[ch];
      if (!channel.visible) continue;
      if (ch >= data.first.values.length) continue;

      _drawChannelOptimized(canvas, size, ch, channel, visibleIndices, step);
    }
  }

  /// 获取可见数据范围（带缓存）
  _Range _getVisibleRange() {
    if (_cachedVisibleRange != null && _cachedViewport != null &&
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
    int step,
  ) {
    // 预分配固定大小列表，避免动态扩容
    final maxPoints = ((visibleRange.end - visibleRange.start) / step).ceil() + 1;
    final points = List<Offset?>.filled(maxPoints, null);
    var count = 0;

    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    for (int i = visibleRange.start; i < visibleRange.end; i += step) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;

      final x = viewport.dataToScreenX(point.index.toDouble(), size.width);
      var y = viewport.dataToScreenY(
        point.values[channelIndex] * channel.yScale + channel.yOffset,
        size.height,
      );

      // 限制在绘图区域内
      if (y < marginTop) y = marginTop;
      if (y > marginBottom) y = marginBottom;

      points[count++] = Offset(x, y);
    }

    if (count == 0) return;

    // 绘制连线（根据设置决定是否开启抗锯齿）
    if (channel.showLine && count > 1) {
      final linePaint = Paint()
        ..color = channel.color
        ..strokeWidth = channel.lineWidth
        ..style = PaintingStyle.stroke
        ..isAntiAlias = antiAliasEnabled;

      final path = Path();
      final first = points[0]!;
      path.moveTo(first.dx, first.dy);
      for (int i = 1; i < count; i++) {
        final p = points[i]!;
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, linePaint);
    }

    // 绘制点（只在需要时）
    final shouldShowPoints = channel.showPoint ||
        count < 100 ||
        (!channel.showLine && channel.visible);
    if (shouldShowPoints) {
      final pointPaint = Paint()
        ..color = channel.color
        ..style = PaintingStyle.fill;

      for (int i = 0; i < count; i++) {
        final p = points[i]!;
        canvas.drawCircle(p, channel.pointSize, pointPaint);
      }
    }
  }

  /// 绘制坐标轴、刻度线和刻度值
  void _drawAxes(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = const Color(0xFF8888AA)
      ..strokeWidth = 1.0;

    final textStyle = const TextStyle(
      color: Color(0xFF8888AA),
      fontSize: 10,
      fontFamily: 'monospace',
    );

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    // X 轴
    canvas.drawLine(
      Offset(PlotViewport().marginLeft, size.height - PlotViewport().marginBottom),
      Offset(size.width - PlotViewport().marginRight, size.height - PlotViewport().marginBottom),
      axisPaint,
    );

    // Y 轴
    canvas.drawLine(
      Offset(PlotViewport().marginLeft, PlotViewport().marginTop),
      Offset(PlotViewport().marginLeft, size.height - PlotViewport().marginBottom),
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

    // Y 轴刻度
    final yGridCount = _calculateGridCount(plotH, 60);
    for (int i = 0; i <= yGridCount; i++) {
      final yRatio = i / yGridCount;
      final y = PlotViewport().marginTop + plotH * (1 - yRatio);
      final yValue = viewport.yMin + viewport.yRange * yRatio;

      // 刻度线
      canvas.drawLine(
        Offset(PlotViewport().marginLeft - 5, y),
        Offset(PlotViewport().marginLeft, y),
        axisPaint,
      );

      // 刻度值
      _drawText(
        canvas,
        _formatNumber(yValue, true),
        Offset(PlotViewport().marginLeft - 8, y),
        textStyle,
        alignRight: true,
      );
    }

    // Y=0 轴线（始终明显显示，如果在可见范围内）
    if (viewport.yMin <= 0 && viewport.yMax >= 0) {
      final zeroY = viewport.dataToScreenY(0, size.height);
      if (zeroY >= PlotViewport().marginTop && zeroY <= PlotViewport().marginTop + plotH) {
        // 轴线：白色半透明，较粗
        final zeroAxisPaint = Paint()
          ..color = const Color(0x99FFFFFF)
          ..strokeWidth = 2.0;
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, zeroY),
          Offset(PlotViewport().marginLeft + plotW, zeroY),
          zeroAxisPaint,
        );

        // 刻度值：Y=0
        final zeroTextStyle = const TextStyle(
          color: Color(0xFFCCCCDD),
          fontSize: 10,
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

  /// 绘制光标（垂直跟随 / X-X / Y-Y 测量）
  void _drawCursor(Canvas canvas, Size size) {
    if (cursor == null) return;

    final cursorPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    // follow 模式：垂直光标 + tooltip
    if (cursor!.mode == CursorMode.follow) {
      final sx = viewport.dataToScreenX(cursor!.x, size.width);
      canvas.drawLine(
        Offset(sx, PlotViewport().marginTop),
        Offset(sx, size.height - PlotViewport().marginBottom),
        cursorPaint,
      );
      _drawCursorTooltip(canvas, size, sx);
    }

    // X-X 测量：两条垂直线（独立于 mode，直接判断 xCursor2 是否存在）
    if (cursor!.xCursor2 != null) {
      _drawXMeasurement(canvas, size, plotH);
    }

    // Y-Y 测量：两条水平线（独立于 mode，直接判断 yCursor2 是否存在）
    if (cursor!.yCursor2 != null) {
      _drawYMeasurement(canvas, size, plotW);
    }
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
    final int displayChannelCount;
    if (values != null && values.isNotEmpty) {
      // 只统计有数据且visible的通道数
      int count = 0;
      for (int i = 0; i < values.length && i < channels.length; i++) {
        if (channels[i].visible) count++;
      }
      displayChannelCount = count;
    } else {
      displayChannelCount = 0;
    }

    if (displayChannelCount == 0) return;

    // 计算tooltip尺寸
    const lineHeight = 20.0;
    const padding = 8.0;
    const maxLabelWidth = 120.0;
    final tooltipWidth = maxLabelWidth + padding * 2;
    final tooltipHeight = displayChannelCount * lineHeight + padding * 2 + 22;

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
    for (int i = 0; i < channels.length; i++) {
      if (!channels[i].visible) continue;
      // 只显示有数据值的通道，跳过数据范围外的
      if (values == null || i >= values.length) continue;

      final y = tooltipY + padding + 22 + row * lineHeight;
      final color = channels[i].color;

      // 颜色指示点
      canvas.drawCircle(
        Offset(tooltipX + padding + 4, y + 5),
        3,
        Paint()..color = color..style = PaintingStyle.fill,
      );

      // 通道名和值
      final valueText = 'Ch$i: ${values[i].toStringAsFixed(2)}';

      final valueStyle = TextStyle(
        color: color,
        fontSize: 12,
        fontFamily: 'monospace',
      );
      _drawText(
        canvas,
        valueText,
        Offset(tooltipX + padding + 12, y),
        valueStyle,
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
      dy -= textPainter.height / 2;
    }

    textPainter.paint(canvas, Offset(dx, dy));
  }

  /// 格式化刻度数值
  ///
  /// - X 轴：始终显示整数
  /// - Y 轴：绝对值>1000或接近整数时显示整数，否则保留2位小数
  String _formatNumber(double value, bool isY) {
    // Y 轴：如果全是整数则不显示小数
    // X 轴：全局不显示小数
    if (!isY) {
      return value.toInt().toString();
    }

    // 检查是否接近整数
    if (value.abs() > 1000) {
      return value.toInt().toString();
    }
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  // ========== X-X / Y-Y 测量绘制 ==========
  /// 绘制 X-X 测量两条垂直线及标签
  void _drawXMeasurement(Canvas canvas, Size size, double plotH) {
    final line1Paint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final line2Paint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // 第一条线
    final sx1 = viewport.dataToScreenX(cursor!.x, size.width);
    if (sx1 >= PlotViewport().marginLeft && sx1 <= size.width - PlotViewport().marginRight) {
      canvas.drawLine(
        Offset(sx1, PlotViewport().marginTop),
        Offset(sx1, PlotViewport().marginTop + plotH),
        line1Paint,
      );
      // 标签背景
      _drawMeasurementLabel(canvas, 'X1', sx1, PlotViewport().marginTop + 10, Colors.cyan);
    }

    // 第二条线
    if (cursor!.xCursor2 != null) {
      final sx2 = viewport.dataToScreenX(cursor!.xCursor2!, size.width);
      if (sx2 >= PlotViewport().marginLeft && sx2 <= size.width - PlotViewport().marginRight) {
        canvas.drawLine(
          Offset(sx2, PlotViewport().marginTop),
          Offset(sx2, PlotViewport().marginTop + plotH),
          line2Paint,
        );
        _drawMeasurementLabel(canvas, 'X2', sx2, PlotViewport().marginTop + 10, Colors.yellow);
      }
    }
  }

  /// 绘制 Y-Y 测量两条水平线及标签
  void _drawYMeasurement(Canvas canvas, Size size, double plotW) {
    final line1Paint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final line2Paint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // 第一条线
    if (cursor!.y != null) {
      final sy1 = viewport.dataToScreenY(cursor!.y!, size.height);
      if (sy1 >= PlotViewport().marginTop && sy1 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, sy1),
          Offset(PlotViewport().marginLeft + plotW, sy1),
          line1Paint,
        );
        _drawMeasurementLabel(canvas, 'Y1', PlotViewport().marginLeft + 10, sy1, Colors.cyan);
      }
    }

    // 第二条线
    if (cursor!.yCursor2 != null) {
      final sy2 = viewport.dataToScreenY(cursor!.yCursor2!, size.height);
      if (sy2 >= PlotViewport().marginTop && sy2 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(PlotViewport().marginLeft, sy2),
          Offset(PlotViewport().marginLeft + plotW, sy2),
          line2Paint,
        );
        _drawMeasurementLabel(canvas, 'Y2', PlotViewport().marginLeft + 10, sy2, Colors.yellow);
      }
    }
  }

  /// 绘制测量线标签（带背景框）
  void _drawMeasurementLabel(Canvas canvas, String label, double x, double y, Color color) {
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
      Rect.fromLTWH(x - textPainter.width / 2 - 3, y - textPainter.height / 2 - 2, textPainter.width + 6, textPainter.height + 4),
      const Radius.circular(2),
    );
    canvas.drawRRect(
      bgRect,
      Paint()..color = const Color(0xDD1A1A2E)..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bgRect,
      Paint()..color = color..strokeWidth = 1.0..style = PaintingStyle.stroke,
    );

    textPainter.paint(canvas, Offset(x - textPainter.width / 2, y - textPainter.height / 2));
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
    final sx1 = viewport.dataToScreenX(statsX1!, size.width)
        .clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight);
    final sx2 = viewport.dataToScreenX(statsX2!, size.width)
        .clamp(PlotViewport().marginLeft, size.width - PlotViewport().marginRight);

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
    final borderPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.5)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 左边界
    _drawDashedLine(canvas, Offset(left, PlotViewport().marginTop),
        Offset(left, size.height - PlotViewport().marginBottom), borderPaint);
    // 右边界
    _drawDashedLine(canvas, Offset(right, PlotViewport().marginTop),
        Offset(right, size.height - PlotViewport().marginBottom), borderPaint);

    // 绘制 S1/S2 标签（底部，带背景框）
    _drawMeasurementLabel(canvas, 'S1', left, size.height - PlotViewport().marginBottom - 10, Colors.green);
    _drawMeasurementLabel(canvas, 'S2', right, size.height - PlotViewport().marginBottom - 10, Colors.green);
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
        Offset(start.dx + dx * t2.clamp(0.0, 1.0), start.dy + dy * t2.clamp(0.0, 1.0)),
        paint,
      );
    }
  }

  /// 判断是否需要重绘
  ///
  /// 比较视口、数据长度、光标、网格、统计范围等关键属性。
  @override
  bool shouldRepaint(covariant PlotPainter oldDelegate) {
    return !_viewportEquals(oldDelegate.viewport, viewport) ||
        oldDelegate.data.length != data.length ||
        oldDelegate.cursor != cursor ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.statsEnabled != statsEnabled ||
        oldDelegate.statsRangeEnabled != statsRangeEnabled ||
        oldDelegate.statsX1 != statsX1 ||
        oldDelegate.statsX2 != statsX2;
  }
}

/**
 * 数据索引范围
 *
 * [start] 包含，[end] 不包含（左闭右开）。
 */
class _Range {
  final int start;
  final int end;
  _Range(this.start, this.end);
}
