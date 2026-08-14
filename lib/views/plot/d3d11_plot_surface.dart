import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/plot_configuration.dart';
import '../../core/utils/plot_performance_metrics.dart';
import '../../data/models/plot_viewport_query.dart';
import 'plot_frame_transform.dart';
import 'plot_render_snapshot.dart';

typedef PlotFramePresented =
    void Function(PlotRenderSnapshot snapshot, int frameId);

/// 将共享几何以数据坐标常驻在Windows D3D11缓冲中。
///
/// 视口平移、Y缩放和有效密度区间内的X缩放只更新常量缓冲；只有数据、
/// LOD质量或预取范围变化时才重新查询并上传几何。原生侧不决定LOD和点序。
class D3d11PlotSurface extends StatefulWidget {
  const D3d11PlotSurface({
    required this.snapshot,
    required this.size,
    required this.fallback,
    this.onFramePresented,
    super.key,
  });

  final PlotRenderSnapshot snapshot;
  final Size size;
  final Widget fallback;
  final PlotFramePresented? onFramePresented;

  @override
  State<D3d11PlotSurface> createState() => _D3d11PlotSurfaceState();
}

class _D3d11PlotSurfaceState extends State<D3d11PlotSurface> {
  static const MethodChannel _channel = MethodChannel(
    'vscope_serial/plot_gpu_renderer',
  );
  static const double _xPrefetchFraction = 0.2;
  static const double _minimumDensityRatio = 0.8;
  static const double _maximumDensityRatio = 1.25;
  static const int _maximumResidentGeometryBytes = 64 * 1024 * 1024;
  static int _nextFrameId = 1;
  static int _nextGeometryGeneration = 1;
  static int _nextClientId = 1;

  final _workspace = _D3d11ResidentGeometryWorkspace();
  late final int _clientId = _nextClientId++;
  int? _textureId;
  bool _initializing = false;
  bool _rendering = false;
  bool _renderScheduled = false;
  bool _failed = false;
  bool _hasPresentedFrame = false;
  PlotRenderSnapshot? _pendingSnapshot;
  Size? _pendingSize;
  _ResidentGeometryState? _geometry;

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
        <String, Object>{'clientId': _clientId},
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
    final stopwatch =
        PlotPerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
    try {
      var geometry = _geometry;
      if (geometry == null || !geometry.canRender(snapshot, size)) {
        geometry = _workspace.build(
          snapshot,
          size,
          generation: _nextGeometryGeneration++,
          prefetchFraction: _xPrefetchFraction,
        );
        if (geometry.primitives.lengthInBytes > _maximumResidentGeometryBytes) {
          throw StateError('D3D11常驻几何超过64 MiB安全上限');
        }
        await _channel.invokeMethod<void>('uploadGeometry', <String, Object>{
          'generation': geometry.generation,
          'clientId': _clientId,
          'primitives': geometry.primitives,
        });
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.gpuGeometryUploadCount,
        );
        _geometry = geometry;
      } else {
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.gpuViewportOnlyCount,
        );
      }

      final frameId = _nextFrameId++;
      PlotPerformanceMetrics.instance.record(
        PlotPerformanceMetric.gpuSegmentCount,
        geometry.primitives.length ~/ 6,
      );
      final transform = PlotFrameTransform(
        frameId: frameId,
        dataRevision: snapshot.dataRevision,
        geometryGeneration: geometry.generation,
        viewport: snapshot.viewport,
        logicalSize: size,
        devicePixelRatio: snapshot.devicePixelRatio,
      );
      final xTransform = transform.physicalXTransform;
      final yTransform = transform.physicalYTransform;
      final response = await _channel
          .invokeMapMethod<String, Object?>('present', <String, Object>{
            'frameId': frameId,
            'clientId': _clientId,
            'generation': geometry.generation,
            'width': transform.textureWidth.clamp(1, 16384),
            'height': transform.textureHeight.clamp(1, 16384),
            'clipLeft': transform.physicalPlotRect.left.round(),
            'clipTop': transform.physicalPlotRect.top.round(),
            'clipRight': transform.physicalPlotRect.right.round(),
            'clipBottom': transform.physicalPlotRect.bottom.round(),
            'xScale': xTransform.$1,
            'xOffset': xTransform.$2,
            'yScale': yTransform.$1,
            'yOffset': yTransform.$2,
            'styles': _workspace.buildStyles(snapshot, size),
          });
      final presentedFrameId = response?['frameId'];
      if (presentedFrameId is int && mounted) {
        if (!_hasPresentedFrame) setState(() => _hasPresentedFrame = true);
        widget.onFramePresented?.call(snapshot, presentedFrameId);
      }
      if (stopwatch != null) {
        stopwatch.stop();
        PlotPerformanceMetrics.instance
          ..increment(PlotPerformanceMetric.gpuSubmitCount)
          ..record(
            PlotPerformanceMetric.gpuSubmitMicros,
            stopwatch.elapsedMicroseconds,
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
    _channel
        .invokeMethod<void>('dispose', <String, Object>{'clientId': _clientId})
        .catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    if (_failed || textureId == null || !_hasPresentedFrame) {
      return widget.fallback;
    }
    return Texture(textureId: textureId, filterQuality: FilterQuality.none);
  }
}

class _ResidentGeometryState {
  const _ResidentGeometryState({
    required this.generation,
    required this.primitives,
    required this.dataRevision,
    required this.dataSource,
    required this.lodSource,
    required this.activeChannelCount,
    required this.quality,
    required this.xMin,
    required this.xMax,
    required this.dataPerPhysicalPixel,
    required this.devicePixelRatio,
    required this.logicalPlotWidth,
  });

  final int generation;
  final Float32List primitives;
  final int dataRevision;
  final Object dataSource;
  final Object? lodSource;
  final int activeChannelCount;
  final Object quality;
  final double xMin;
  final double xMax;
  final double dataPerPhysicalPixel;
  final double devicePixelRatio;
  final double logicalPlotWidth;

  bool canRender(PlotRenderSnapshot snapshot, Size size) {
    if (snapshot.dataRevision != dataRevision ||
        !identical(snapshot.data, dataSource) ||
        !identical(snapshot.lodIndex, lodSource) ||
        snapshot.activeChannelCount != activeChannelCount ||
        snapshot.lodQuality != quality ||
        snapshot.viewport.xMin < xMin ||
        snapshot.viewport.xMax > xMax ||
        snapshot.devicePixelRatio != devicePixelRatio) {
      return false;
    }
    final width = snapshot.viewport.plotWidth(size.width);
    if ((width - logicalPlotWidth).abs() > 0.5 || width <= 0) return false;
    final density = snapshot.viewport.xRange / (width * devicePixelRatio);
    final ratio = density / dataPerPhysicalPixel;
    return ratio >= _D3d11PlotSurfaceState._minimumDensityRatio &&
        ratio <= _D3d11PlotSurfaceState._maximumDensityRatio;
  }
}

/// 图元格式：x0、y0、x1、y1、类型（0线/1点）、通道序号。
class _D3d11ResidentGeometryWorkspace {
  final PlotGeometryWorkspace _queryWorkspace = PlotGeometryWorkspace();
  Float32List _primitives = Float32List(4096);
  final Float32List _styles = Float32List(
    PlotConfiguration.totalChannelCount * 12,
  );

  _ResidentGeometryState build(
    PlotRenderSnapshot snapshot,
    Size size, {
    required int generation,
    required double prefetchFraction,
  }) {
    final range = snapshot.viewport.xRange;
    final historyLength = snapshot.lodIndex?.length ?? snapshot.data.length;
    final lastDataX = math.max(0, historyLength - 1).toDouble();
    final xMin = math.max(
      0.0,
      snapshot.viewport.xMin - range * prefetchFraction,
    );
    final xMax = math.min(
      lastDataX,
      snapshot.viewport.xMax + range * prefetchFraction,
    );
    final expandedRatio = (xMax - xMin) / range;
    final plotWidth = snapshot.viewport.plotWidth(size.width);
    final queryWidth = plotWidth * expandedRatio;
    var outputLength = 0;
    final channelCount = snapshot.activeChannelCount.clamp(
      0,
      snapshot.channels.length,
    );

    void append(
      double x0,
      double y0,
      double x1,
      double y1,
      double kind,
      int channel,
    ) {
      if (!x0.isFinite || !y0.isFinite || !x1.isFinite || !y1.isFinite) {
        return;
      }
      _ensure(outputLength + 6);
      _primitives[outputLength++] = x0;
      _primitives[outputLength++] = y0;
      _primitives[outputLength++] = x1;
      _primitives[outputLength++] = y1;
      _primitives[outputLength++] = kind;
      _primitives[outputLength++] = channel.toDouble();
    }

    for (var channelIndex = 0; channelIndex < channelCount; channelIndex++) {
      final geometry = PlotViewportQuery.queryChannel(
        exactData: snapshot.data,
        rangeIndex: snapshot.lodIndex,
        channelIndex: channelIndex,
        xMin: xMin,
        xMax: xMax,
        logicalPlotWidth: queryWidth,
        devicePixelRatio: snapshot.devicePixelRatio,
        quality: snapshot.lodQuality,
        workspace: _queryWorkspace,
      );
      if (geometry == null || geometry.isEmpty) continue;
      for (var run = 0; run < geometry.runCount; run++) {
        final start = geometry.runOffsets[run];
        final end = geometry.runOffsets[run + 1];
        for (var point = start + 1; point < end; point++) {
          final previous = point - 1;
          append(
            geometry.indices[previous].toDouble(),
            geometry.values[previous],
            geometry.indices[point].toDouble(),
            geometry.values[point],
            0,
            channelIndex,
          );
        }
      }
      for (var point = 0; point < geometry.length; point++) {
        append(
          geometry.indices[point].toDouble(),
          geometry.values[point],
          geometry.indices[point].toDouble(),
          geometry.values[point],
          1,
          channelIndex,
        );
      }
    }
    final physicalWidth = math.max(1.0, plotWidth * snapshot.devicePixelRatio);
    return _ResidentGeometryState(
      generation: generation,
      primitives: Float32List.fromList(
        Float32List.sublistView(_primitives, 0, outputLength),
      ),
      dataRevision: snapshot.dataRevision,
      dataSource: snapshot.data,
      lodSource: snapshot.lodIndex,
      activeChannelCount: snapshot.activeChannelCount,
      quality: snapshot.lodQuality,
      xMin: xMin,
      xMax: xMax,
      dataPerPhysicalPixel: snapshot.viewport.xRange / physicalWidth,
      devicePixelRatio: snapshot.devicePixelRatio,
      logicalPlotWidth: plotWidth,
    );
  }

  Float32List buildStyles(PlotRenderSnapshot snapshot, Size size) {
    _styles.fillRange(0, _styles.length, 0);
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
    final pointThreshold =
        math.max(1, snapshot.viewport.plotWidth(size.width) * 0.5).round();
    final count = snapshot.activeChannelCount.clamp(
      0,
      math.min(snapshot.channels.length, PlotConfiguration.totalChannelCount),
    );
    for (var index = 0; index < count; index++) {
      final channel = snapshot.channels[index];
      final geometryBase = index * 4;
      _styles[geometryBase] = channel.yScale;
      _styles[geometryBase + 1] = channel.yOffset;
      _styles[geometryBase + 2] = channel.lineWidth * snapshot.devicePixelRatio;
      _styles[geometryBase + 3] = channel.pointSize * snapshot.devicePixelRatio;

      final colorBase = PlotConfiguration.totalChannelCount * 4 + index * 4;
      _styles[colorBase] = channel.color.r;
      _styles[colorBase + 1] = channel.color.g;
      _styles[colorBase + 2] = channel.color.b;
      _styles[colorBase + 3] = channel.color.a;

      final flagBase = PlotConfiguration.totalChannelCount * 8 + index * 4;
      _styles[flagBase] = channel.visible ? 1 : 0;
      _styles[flagBase + 1] = channel.showLine ? 1 : 0;
      _styles[flagBase + 2] =
          (!channel.showLine || visibleCount <= pointThreshold) ? 1 : 0;
    }
    return _styles;
  }

  void _ensure(int requiredLength) {
    if (_primitives.length >= requiredLength) return;
    var capacity = _primitives.length;
    while (capacity < requiredLength) {
      capacity *= 2;
    }
    final expanded = Float32List(capacity);
    expanded.setRange(0, _primitives.length, _primitives);
    _primitives = expanded;
  }
}
