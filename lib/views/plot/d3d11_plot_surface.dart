import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/plot_viewport_query.dart';
import '../../core/utils/plot_performance_metrics.dart';
import 'plot_render_snapshot.dart';

/// 将共享的屏幕级几何提交给 Windows D3D11 外部纹理。
///
/// 本组件不决定LOD，也不改变点序；原生侧只把相邻点展开为抗锯齿线段。
/// 初始化或渲染失败时始终保留Canvas回退画面。
class D3d11PlotSurface extends StatefulWidget {
  const D3d11PlotSurface({
    required this.snapshot,
    required this.size,
    required this.fallback,
    super.key,
  });

  final PlotRenderSnapshot snapshot;
  final Size size;
  final Widget fallback;

  @override
  State<D3d11PlotSurface> createState() => _D3d11PlotSurfaceState();
}

class _D3d11PlotSurfaceState extends State<D3d11PlotSurface> {
  static const MethodChannel _channel = MethodChannel(
    'vscope_serial/plot_gpu_renderer',
  );

  final _workspace = _D3d11SegmentWorkspace();
  int? _textureId;
  bool _initializing = false;
  bool _rendering = false;
  bool _renderScheduled = false;
  bool _failed = false;
  PlotRenderSnapshot? _pendingSnapshot;
  Size? _pendingSize;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant D3d11PlotSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleRender(widget.snapshot, widget.size);
  }

  Future<void> _initialize() async {
    if (_initializing || _failed || !Platform.isWindows) return;
    _initializing = true;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'initialize',
      );
      final textureId = result?['textureId'];
      if (textureId is! int) throw StateError('D3D11纹理编号无效');
      if (!mounted) return;
      setState(() => _textureId = textureId);
      _scheduleRender(widget.snapshot, widget.size);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  void _scheduleRender(PlotRenderSnapshot snapshot, Size size) {
    if (_failed || _textureId == null || !size.isFinite || size.isEmpty) {
      return;
    }
    _pendingSnapshot = snapshot;
    _pendingSize = size;
    if (_rendering || _renderScheduled) return;
    _renderScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderScheduled = false;
      _renderLatest();
    });
  }

  Future<void> _renderLatest() async {
    if (_rendering || _failed || !mounted) return;
    final snapshot = _pendingSnapshot;
    final size = _pendingSize;
    if (snapshot == null || size == null) return;
    _pendingSnapshot = null;
    _pendingSize = null;
    _rendering = true;
    final submitStopwatch =
        PlotPerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      final dpr = snapshot.devicePixelRatio;
      final width = (size.width * dpr).ceil().clamp(1, 16384);
      final height = (size.height * dpr).ceil().clamp(1, 16384);
      final segments = _workspace.build(snapshot, size, dpr);
      PlotPerformanceMetrics.instance.record(
        PlotPerformanceMetric.gpuSegmentCount,
        segments.length ~/ 9,
      );
      await _channel.invokeMethod<void>('render', <String, Object>{
        'width': width,
        'height': height,
        'clipLeft': (snapshot.viewport.marginLeft * dpr).round(),
        'clipTop': (snapshot.viewport.marginTop * dpr).round(),
        'clipRight':
            ((size.width - snapshot.viewport.marginRight) * dpr).round(),
        'clipBottom':
            ((size.height - snapshot.viewport.marginBottom) * dpr).round(),
        'segments': segments,
      });
      if (submitStopwatch != null) {
        submitStopwatch.stop();
        PlotPerformanceMetrics.instance
          ..increment(PlotPerformanceMetric.gpuSubmitCount)
          ..record(
            PlotPerformanceMetric.gpuSubmitMicros,
            submitStopwatch.elapsedMicroseconds,
          );
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _rendering = false;
      if (_pendingSnapshot != null && mounted && !_failed) {
        _scheduleRender(_pendingSnapshot!, _pendingSize!);
      }
    }
  }

  @override
  void dispose() {
    _channel.invokeMethod<void>('dispose').catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    if (_failed || textureId == null) return widget.fallback;
    return Texture(textureId: textureId, filterQuality: FilterQuality.none);
  }
}

class _D3d11SegmentWorkspace {
  final PlotGeometryWorkspace _queryWorkspace = PlotGeometryWorkspace();
  Float32List _segments = Float32List(4096);

  Float32List build(PlotRenderSnapshot snapshot, Size size, double dpr) {
    var outputLength = 0;
    final channelCount = snapshot.activeChannelCount.clamp(
      0,
      snapshot.channels.length,
    );
    for (var channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      final channel = snapshot.channels[channelIndex];
      if (!channel.visible) continue;
      final geometry = PlotViewportQuery.queryChannel(
        exactData: snapshot.data,
        rangeIndex: snapshot.lodIndex,
        channelIndex: channelIndex,
        xMin: snapshot.viewport.xMin,
        xMax: snapshot.viewport.xMax,
        logicalPlotWidth: snapshot.viewport.plotWidth(size.width),
        devicePixelRatio: dpr,
        quality: snapshot.lodQuality,
        workspace: _queryWorkspace,
      );
      if (geometry == null || geometry.isEmpty) continue;
      final color = channel.color;
      double screenX(int point) =>
          snapshot.viewport.dataToScreenX(
            geometry.indices[point].toDouble(),
            size.width,
          ) *
          dpr;
      double screenY(int point) =>
          snapshot.viewport.dataToScreenY(
            geometry.values[point] * channel.yScale + channel.yOffset,
            size.height,
          ) *
          dpr;

      void appendPrimitive(
        double x0,
        double y0,
        double x1,
        double y1,
        double width,
      ) {
        if (!x0.isFinite || !y0.isFinite || !x1.isFinite || !y1.isFinite) {
          return;
        }
        _ensure(outputLength + 9);
        _segments[outputLength++] = x0;
        _segments[outputLength++] = y0;
        _segments[outputLength++] = x1;
        _segments[outputLength++] = y1;
        _segments[outputLength++] = width;
        _segments[outputLength++] = color.r;
        _segments[outputLength++] = color.g;
        _segments[outputLength++] = color.b;
        _segments[outputLength++] = color.a;
      }

      if (channel.showLine && geometry.length >= 2) {
        for (var run = 0; run < geometry.runCount; run++) {
          final start = geometry.runOffsets[run];
          final end = geometry.runOffsets[run + 1];
          for (var point = start + 1; point < end; point++) {
            final previous = point - 1;
            final x0 = screenX(previous);
            final y0 = screenY(previous);
            final x1 = screenX(point);
            final y1 = screenY(point);
            if (x0 == x1 && y0 == y1) continue;
            appendPrimitive(x0, y0, x1, y1, channel.lineWidth * dpr);
          }
        }
      }

      final historyLength = snapshot.lodIndex?.length ?? snapshot.data.length;
      final visibleStart = snapshot.viewport.xMin.ceil().clamp(
        0,
        math.max(0, historyLength - 1),
      );
      final visibleEnd = snapshot.viewport.xMax.floor().clamp(
        0,
        math.max(0, historyLength - 1),
      );
      final visibleCount = math.max(0, visibleEnd - visibleStart + 1);
      final showPoints =
          !channel.showLine ||
          visibleCount <=
              math
                  .max(1, snapshot.viewport.plotWidth(size.width) * 0.5)
                  .round();
      if (showPoints) {
        for (var point = 0; point < geometry.length; point++) {
          final x = screenX(point);
          final y = screenY(point);
          // 原生着色器把零长度线段识别为方形点实例。
          appendPrimitive(x, y, x, y, channel.pointSize * dpr);
        }
      }
    }
    return Float32List.sublistView(_segments, 0, outputLength);
  }

  void _ensure(int requiredLength) {
    if (_segments.length >= requiredLength) return;
    var capacity = _segments.length;
    while (capacity < requiredLength) {
      capacity *= 2;
    }
    final expanded = Float32List(capacity);
    expanded.setRange(0, _segments.length, _segments);
    _segments = expanded;
  }
}
