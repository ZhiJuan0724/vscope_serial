import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/plot_viewport_query.dart';
import 'plot_viewport.dart';

/// 绘图数据层渲染边界。
///
/// 视口查询负责决定绘制哪些真实采样；渲染器只做坐标变换和提交，禁止
/// 再次抽点、改序或推断阶跃。后续 GPU 实现必须消费同一几何批次。
abstract interface class PlotDataRenderer {
  void drawLineBatch({
    required Canvas canvas,
    required Size size,
    required PlotViewport viewport,
    required ChannelConfig channel,
    required PlotGeometryBatch batch,
    required Paint paint,
    required Float32List Function(int requiredLength) acquirePoints,
  });
}

class CanvasPlotDataRenderer implements PlotDataRenderer {
  const CanvasPlotDataRenderer();

  @override
  void drawLineBatch({
    required Canvas canvas,
    required Size size,
    required PlotViewport viewport,
    required ChannelConfig channel,
    required PlotGeometryBatch batch,
    required Paint paint,
    required Float32List Function(int requiredLength) acquirePoints,
  }) {
    if (batch.isEmpty) return;
    final points = acquirePoints(batch.length * 2);
    var out = 0;
    for (var i = 0; i < batch.length; i++) {
      final displayValue = batch.values[i] * channel.yScale + channel.yOffset;
      points[out++] = viewport.dataToScreenX(
        batch.indices[i].toDouble(),
        size.width,
      );
      // 数据层外部已经按绘图区 clip。这里必须保留真实投影坐标，不能把
      // 越界点钳到上下边缘，否则连续越界数据会生成并不存在的水平线。
      points[out++] = viewport.dataToScreenY(displayValue, size.height);
    }

    for (var run = 0; run < batch.runCount; run++) {
      final start = batch.runOffsets[run] * 2;
      final end = batch.runOffsets[run + 1] * 2;
      if (end - start < 4) continue;
      canvas.drawRawPoints(
        ui.PointMode.polygon,
        Float32List.sublistView(points, start, end),
        paint,
      );
    }
  }
}
