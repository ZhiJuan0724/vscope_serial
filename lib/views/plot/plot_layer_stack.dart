import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/plot_render_engine.dart';
import 'd3d11_plot_surface.dart';
import 'plot_painter.dart';
import 'plot_presentation_coordinator.dart';
import 'plot_viewport.dart';

/// 只订阅冻结渲染快照的四层绘图组件。
///
/// 静态历史进入拖动后，数据层会异步生成一张带 X/Y 预取的透明位图；后续
/// 平移只移动该纹理，避免 Raster 每帧重新光栅化数万条高密度线段。越过
/// 预取范围或数据发生变化时自动回到 Canvas 并生成下一张缓存。
class PlotLayerStack extends StatefulWidget {
  const PlotLayerStack({
    required this.snapshot,
    this.presentationCoordinator,
    super.key,
  });

  final PlotRenderSnapshot snapshot;
  final PlotPresentationCoordinator? presentationCoordinator;

  @override
  State<PlotLayerStack> createState() => _PlotLayerStackState();
}

class _PlotLayerStackState extends State<PlotLayerStack> {
  static const double _xPrefetchFraction = 1.5;
  static const double _yPrefetchFraction = 0.5;
  static const double _maxRasterDimension = 8192;
  static const double _maxRasterPixels = 32 * 1024 * 1024;
  static const double _rapidMotionViewportRangesPerSecond = 2.5;
  static const int _rapidMotionCooldownMicros = 200000;

  final PlotGeometryBuffers _geometryBuffers = PlotGeometryBuffers();
  PlotRenderSnapshot? _dataBaseSnapshot;
  ui.Image? _dataRasterImage;
  Size? _dataRasterLogicalSize;
  int _captureGeneration = 0;
  bool _captureScheduled = false;
  PlotViewport? _lastInteractionViewport;
  int? _lastInteractionMicros;
  int _rapidMotionUntilMicros = 0;
  PlotRenderSnapshot? _presentedSnapshot;

  @override
  void dispose() {
    _captureGeneration++;
    _dataRasterImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.snapshot;
    if (current.renderEngine == PlotRenderEngine.canvas) {
      _presentedSnapshot = current;
      widget.presentationCoordinator?.present(
        current,
        frameId: current.viewportRevision,
        notify: false,
      );
    }
    final presented = _presentedSnapshot ?? current;
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    _updateInteractionVelocity(current, nowMicros);
    _resolveDataBase(current);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (current.interactionActive &&
            current.renderEngine == PlotRenderEngine.canvas &&
            nowMicros >= _rapidMotionUntilMicros &&
            size.isFinite &&
            size.width > 0 &&
            size.height > 0 &&
            _dataRasterImage == null) {
          _scheduleRasterCapture(_dataBaseSnapshot!, size);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            _paintLayer(PlotPaintLayer.background, presented),
            ClipRect(
              clipper: _PlotAreaClipper(presented.viewport),
              child: _buildDataLayer(current, size),
            ),
            _paintLayer(PlotPaintLayer.axis, presented),
            _paintLayer(PlotPaintLayer.overlay, presented),
          ],
        );
      },
    );
  }

  Widget _buildDataLayer(PlotRenderSnapshot current, Size size) {
    if (current.renderEngine == PlotRenderEngine.d3d11) {
      return D3d11PlotSurface(
        snapshot: current,
        size: size,
        onFramePresented: _handleD3dFramePresented,
        fallback: _paintLayer(
          PlotPaintLayer.data,
          current,
          externalDataClip: true,
        ),
      );
    }
    final image = _dataRasterImage;
    final imageSize = _dataRasterLogicalSize;
    final base = _dataBaseSnapshot!;
    if (current.interactionActive && image != null && imageSize != null) {
      final viewport = current.viewport;
      final baseViewport = base.viewport;
      final plotWidth = viewport.plotWidth(size.width);
      final plotHeight = viewport.plotHeight(size.height);
      final paddingX = plotWidth * _xPrefetchFraction;
      final paddingY = plotHeight * _yPrefetchFraction;
      final offsetX =
          -paddingX +
          (baseViewport.xMin - viewport.xMin) * plotWidth / viewport.xRange;
      final offsetY =
          -paddingY +
          (viewport.yMax - baseViewport.yMax) * plotHeight / viewport.yRange;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: offsetX,
            top: offsetY,
            width: imageSize.width,
            height: imageSize.height,
            child: RawImage(image: image, fit: BoxFit.fill),
          ),
        ],
      );
    }
    return _paintLayer(PlotPaintLayer.data, current, externalDataClip: true);
  }

  void _handleD3dFramePresented(PlotRenderSnapshot snapshot, int frameId) {
    if (!mounted) return;
    setState(() => _presentedSnapshot = snapshot);
    widget.presentationCoordinator?.present(snapshot, frameId: frameId);
  }

  Widget _paintLayer(
    PlotPaintLayer layer,
    PlotRenderSnapshot snapshot, {
    bool externalDataClip = false,
  }) => RepaintBoundary(
    key: ValueKey<String>('plot-layer-${layer.name}'),
    child: CustomPaint(
      painter: PlotLayerPainter.fromSnapshot(
        layer: layer,
        snapshot: snapshot,
        geometryBuffers: _geometryBuffers,
        externalDataClip: externalDataClip,
      ),
      size: Size.infinite,
    ),
  );

  void _resolveDataBase(PlotRenderSnapshot current) {
    final cached = _dataBaseSnapshot;
    final mustReplace =
        !current.interactionActive ||
        cached == null ||
        !_sameStaticData(cached, current) ||
        !_sameViewportScaleAndMargins(cached.viewport, current.viewport) ||
        !_insidePrefetchedViewport(cached.viewport, current.viewport);
    if (!mustReplace) return;
    _dataBaseSnapshot = current;
    _captureGeneration++;
    _captureScheduled = false;
    _dataRasterImage?.dispose();
    _dataRasterImage = null;
    _dataRasterLogicalSize = null;
  }

  void _updateInteractionVelocity(PlotRenderSnapshot current, int nowMicros) {
    if (!current.interactionActive) {
      _lastInteractionViewport = null;
      _lastInteractionMicros = null;
      _rapidMotionUntilMicros = 0;
      return;
    }
    final previous = _lastInteractionViewport;
    final previousMicros = _lastInteractionMicros;
    if (previous != null && previousMicros != null) {
      final elapsedMicros = nowMicros - previousMicros;
      if (elapsedMicros > 0 &&
          _near(previous.xRange, current.viewport.xRange)) {
        final movedRanges =
            (current.viewport.xMin - previous.xMin).abs() /
            current.viewport.xRange;
        final rangesPerSecond = movedRanges * 1000000 / elapsedMicros;
        if (rangesPerSecond >= _rapidMotionViewportRangesPerSecond) {
          _rapidMotionUntilMicros = nowMicros + _rapidMotionCooldownMicros;
          // 已开始的 toImage 无法真正取消；递增代次可阻止过期结果替换当前画面。
          if (_captureScheduled) {
            _captureGeneration++;
            _captureScheduled = false;
          }
        }
      }
    }
    _lastInteractionViewport = current.viewport.copy();
    _lastInteractionMicros = nowMicros;
  }

  void _scheduleRasterCapture(PlotRenderSnapshot base, Size size) {
    if (_captureScheduled) return;
    _captureScheduled = true;
    final generation = ++_captureGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _captureGeneration) return;
      try {
        final viewport = base.viewport;
        final plotWidth = viewport.plotWidth(size.width);
        final plotHeight = viewport.plotHeight(size.height);
        final expandedViewport = viewport.copy();
        expandedViewport
          ..xMin = viewport.xMin - viewport.xRange * _xPrefetchFraction
          ..xMax = viewport.xMax + viewport.xRange * _xPrefetchFraction
          ..yMin = viewport.yMin - viewport.yRange * _yPrefetchFraction
          ..yMax = viewport.yMax + viewport.yRange * _yPrefetchFraction;
        final logicalSize = Size(
          size.width + plotWidth * _xPrefetchFraction * 2,
          size.height + plotHeight * _yPrefetchFraction * 2,
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final requestedDpr = base.devicePixelRatio;
        final rasterDpr = math.min(
          requestedDpr,
          math.min(
            _maxRasterDimension / logicalSize.width,
            math.min(
              _maxRasterDimension / logicalSize.height,
              math.sqrt(
                _maxRasterPixels / (logicalSize.width * logicalSize.height),
              ),
            ),
          ),
        );
        canvas.scale(rasterDpr, rasterDpr);
        PlotLayerPainter.fromSnapshot(
          layer: PlotPaintLayer.data,
          snapshot: base.copyWith(viewport: expandedViewport),
          geometryBuffers: _geometryBuffers,
          externalDataClip: true,
        ).paint(canvas, logicalSize);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          (logicalSize.width * rasterDpr).ceil(),
          (logicalSize.height * rasterDpr).ceil(),
        );
        picture.dispose();
        if (!mounted || generation != _captureGeneration) {
          image.dispose();
          return;
        }
        setState(() {
          _dataRasterImage?.dispose();
          _dataRasterImage = image;
          _dataRasterLogicalSize = logicalSize;
          _captureScheduled = false;
        });
      } catch (_) {
        if (mounted && generation == _captureGeneration) {
          _captureScheduled = false;
        }
        // 位图生成失败时继续使用 Canvas；不清空历史，也不改变质量设置。
      }
    });
  }

  bool _sameStaticData(PlotRenderSnapshot a, PlotRenderSnapshot b) =>
      a.dataRevision == b.dataRevision &&
      a.channelConfigRevision == b.channelConfigRevision &&
      identical(a.lodIndex, b.lodIndex) &&
      a.lodQuality == b.lodQuality &&
      a.devicePixelRatio == b.devicePixelRatio &&
      a.activeChannelCount == b.activeChannelCount &&
      a.backgroundStyle == b.backgroundStyle &&
      a.antiAliasEnabled == b.antiAliasEnabled;

  bool _sameViewportScaleAndMargins(PlotViewport a, PlotViewport b) =>
      _near(a.xRange, b.xRange) &&
      _near(a.yRange, b.yRange) &&
      a.marginLeft == b.marginLeft &&
      a.marginRight == b.marginRight &&
      a.marginTop == b.marginTop &&
      a.marginBottom == b.marginBottom;

  bool _insidePrefetchedViewport(PlotViewport cached, PlotViewport current) {
    final xPadding = cached.xRange * _xPrefetchFraction;
    final yPadding = cached.yRange * _yPrefetchFraction;
    return current.xMin >= cached.xMin - xPadding &&
        current.xMax <= cached.xMax + xPadding &&
        current.yMin >= cached.yMin - yPadding &&
        current.yMax <= cached.yMax + yPadding;
  }

  bool _near(double a, double b) {
    final scale = a.abs() > b.abs() ? a.abs() : b.abs();
    return (a - b).abs() <= (scale * 1e-9).clamp(1e-9, double.infinity);
  }
}

class _PlotAreaClipper extends CustomClipper<Rect> {
  const _PlotAreaClipper(this.viewport);

  final PlotViewport viewport;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    viewport.marginLeft,
    viewport.marginTop,
    viewport.plotWidth(size.width),
    viewport.plotHeight(size.height),
  );

  @override
  bool shouldReclip(covariant _PlotAreaClipper oldClipper) =>
      oldClipper.viewport.marginLeft != viewport.marginLeft ||
      oldClipper.viewport.marginRight != viewport.marginRight ||
      oldClipper.viewport.marginTop != viewport.marginTop ||
      oldClipper.viewport.marginBottom != viewport.marginBottom;
}
