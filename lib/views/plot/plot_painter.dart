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

/// 绘图 CustomPainter
class PlotPainter extends CustomPainter {
  final PlotViewport viewport;
  final List<PlotDataPoint> data;
  final List<ChannelConfig> channels;
  final bool showGrid;
  final CursorState? cursor;

  PlotPainter({
    required this.viewport,
    required this.data,
    required this.channels,
    this.showGrid = true,
    this.cursor,
  });

  /// 判断两个视口是否相等（用于重绘判断）
  bool _viewportEquals(PlotViewport a, PlotViewport b) {
    return a.xMin == b.xMin && a.xMax == b.xMax && a.yMin == b.yMin && a.yMax == b.yMax;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制背景
    _drawBackground(canvas, size);

    // 绘制网格
    if (showGrid) {
      _drawGrid(canvas, size);
    }

    // 绘制通道数据
    _drawChannels(canvas, size);

    // 绘制坐标轴
    _drawAxes(canvas, size);

    // 绘制光标（单垂直光标或X-X/Y-Y测量光标）
    _drawCursor(canvas, size);
  }

  void _drawBackground(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2D2D44)
      ..strokeWidth = 0.5;

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    // 计算网格间距
    final xGridCount = _calculateGridCount(plotW, 80);
    final yGridCount = _calculateGridCount(plotH, 60);

    // 垂直网格线
    for (int i = 0; i <= xGridCount; i++) {
      final x = PlotViewport().marginLeft + plotW * i / xGridCount;
      canvas.drawLine(
        Offset(x, PlotViewport().marginTop),
        Offset(x, PlotViewport().marginTop + plotH),
        paint,
      );
    }

    // 水平网格线
    for (int i = 0; i <= yGridCount; i++) {
      final y = PlotViewport().marginTop + plotH * i / yGridCount;
      canvas.drawLine(
        Offset(PlotViewport().marginLeft, y),
        Offset(PlotViewport().marginLeft + plotW, y),
        paint,
      );
    }
  }

  int _calculateGridCount(double length, double minSpacing) {
    final count = (length / minSpacing).floor();
    if (count < 2) return 2;
    if (count > 20) return 20;
    return count;
  }

  // 缓存可见范围，避免每帧重复二分查找
  _Range? _cachedVisibleRange;
  PlotViewport? _cachedViewport;

  void _drawChannels(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    // 找到可见范围内的数据索引（缓存）
    final visibleIndices = _getVisibleRange();
    if (visibleIndices.start >= visibleIndices.end) return;

    // 降采样：根据像素宽度决定采样步长
    final plotW = viewport.plotWidth(size.width);
    final dataCount = visibleIndices.end - visibleIndices.start;
    final step = dataCount > plotW * 2 ? (dataCount / (plotW * 2)).ceil() : 1;

    for (int ch = 0; ch < channels.length; ch++) {
      final channel = channels[ch];
      if (!channel.visible) continue;
      if (ch >= data.first.values.length) continue;

      _drawChannel(canvas, size, ch, channel, visibleIndices, step);
    }
  }

  _Range _getVisibleRange() {
    if (_cachedVisibleRange != null && _cachedViewport != null &&
        _viewportEquals(_cachedViewport!, viewport)) {
      return _cachedVisibleRange!;
    }
    _cachedVisibleRange = _findVisibleRange();
    _cachedViewport = viewport.copy();
    return _cachedVisibleRange!;
  }

  void _drawChannel(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    int step,
  ) {
    final points = <Offset>[];

    for (int i = visibleRange.start; i < visibleRange.end; i += step) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;

      final x = viewport.dataToScreenX(point.index.toDouble(), size.width);
      var y = viewport.dataToScreenY(
        point.values[channelIndex] * channel.yScale + channel.yOffset,
        size.height,
      );

      // 限制在绘图区域内
      y = y.clamp(viewport.marginTop, size.height - viewport.marginBottom);

      points.add(Offset(x, y));
    }

    if (points.isEmpty) return;

    // 绘制连线
    if (channel.showLine && points.length > 1) {
      final linePaint = Paint()
        ..color = channel.color
        ..strokeWidth = channel.lineWidth
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;

      final path = Path();
      path.moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    // 绘制点
    if (channel.showPoint || points.length < 100) {
      final pointPaint = Paint()
        ..color = channel.color
        ..style = PaintingStyle.fill;

      for (final p in points) {
        canvas.drawCircle(p, channel.pointSize, pointPaint);
      }
    }
  }

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
  }

  void _drawCursor(Canvas canvas, Size size) {
    if (cursor == null) return;

    final cursorPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);

    switch (cursor!.mode) {
      case CursorMode.follow:
        final sx = viewport.dataToScreenX(cursor!.x, size.width);
        // 垂直线：在绘图区域内绘制
        canvas.drawLine(
          Offset(sx, PlotViewport().marginTop),
          Offset(sx, size.height - PlotViewport().marginBottom),
          cursorPaint,
        );

        // 绘制鼠标旁各通道Y值tooltip
        _drawCursorTooltip(canvas, size, sx);
        break;

      case CursorMode.xCursor:
        // x-x 光标：两条垂直线
        final sx1 = viewport.dataToScreenX(cursor!.x, size.width);
        if (sx1 >= PlotViewport().marginLeft && sx1 <= PlotViewport().marginLeft + plotW) {
          canvas.drawLine(
            Offset(sx1, PlotViewport().marginTop),
            Offset(sx1, PlotViewport().marginTop + plotH),
            cursorPaint,
          );
        }
        // 第二条线
        if (cursor!.xCursor2 != null) {
          final sx2 = viewport.dataToScreenX(cursor!.xCursor2!, size.width);
          if (sx2 >= PlotViewport().marginLeft && sx2 <= PlotViewport().marginLeft + plotW) {
            final paint2 = Paint()
              ..color = Colors.yellow
              ..strokeWidth = 1.0
              ..style = PaintingStyle.stroke;
            canvas.drawLine(
              Offset(sx2, PlotViewport().marginTop),
              Offset(sx2, PlotViewport().marginTop + plotH),
              paint2,
            );
          }
        }
        break;

      case CursorMode.yCursor:
        // y-y 光标：两条水平线
        if (cursor!.y != null) {
          final sy1 = viewport.dataToScreenY(cursor!.y!, size.height);
          if (sy1 >= PlotViewport().marginTop && sy1 <= PlotViewport().marginTop + plotH) {
            canvas.drawLine(
              Offset(PlotViewport().marginLeft, sy1),
              Offset(PlotViewport().marginLeft + plotW, sy1),
              cursorPaint,
            );
          }
        }
        // 第二条线
        if (cursor!.yCursor2 != null) {
          final sy2 = viewport.dataToScreenY(cursor!.yCursor2!, size.height);
          if (sy2 >= PlotViewport().marginTop && sy2 <= PlotViewport().marginTop + plotH) {
            final paint2 = Paint()
              ..color = Colors.yellow
              ..strokeWidth = 1.0
              ..style = PaintingStyle.stroke;
            canvas.drawLine(
              Offset(PlotViewport().marginLeft, sy2),
              Offset(PlotViewport().marginLeft + plotW, sy2),
              paint2,
          );
          }
        }
        break;

      case CursorMode.none:
        break;
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

  void _drawText(
    Canvas canvas,
    String text,
    Offset position,
    TextStyle style, {
    bool alignCenter = false,
    bool alignRight = false,
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

    textPainter.paint(canvas, Offset(dx, position.dy));
  }

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

  /// 找到可见范围内的数据索引
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

  @override
  bool shouldRepaint(covariant PlotPainter oldDelegate) {
    return !_viewportEquals(oldDelegate.viewport, viewport) ||
        oldDelegate.data.length != data.length ||
        oldDelegate.cursor != cursor ||
        oldDelegate.showGrid != showGrid;
  }
}

class _Range {
  final int start;
  final int end;
  _Range(this.start, this.end);
}
