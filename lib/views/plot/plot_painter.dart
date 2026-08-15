import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/constants/plot_configuration.dart';
import '../../core/utils/plot_value_formatter.dart';
import '../../core/utils/plot_performance_metrics.dart';
import '../../data/models/channel_config.dart';
import '../../data/models/plot_lod_index.dart';
import '../../data/models/plot_data.dart';
import '../../data/models/plot_viewport_query.dart';
import 'plot_data_renderer.dart';
import 'plot_render_snapshot.dart';
import 'plot_viewport.dart';

export 'plot_render_snapshot.dart';

/// 绘图层跨帧复用的 TypedData 缓冲区。
///
/// Canvas 在 drawRawPoints 返回前已经消费数据，因此各通道可以顺序复用同一组
/// 缓冲；容量只增不减，停止采样后的连续拖动不会再为每帧创建大数组。
class PlotGeometryBuffers {
  final PlotGeometryWorkspace viewportQuery = PlotGeometryWorkspace();
  Float32List _points = Float32List(0);
  Float32List _trend = Float32List(0);
  Float32List _extrema = Float32List(0);

  Float32List points(int requiredLength) =>
      _ensure(_points, requiredLength, (value) => _points = value);
  Float32List trend(int requiredLength) =>
      _ensure(_trend, requiredLength, (value) => _trend = value);
  Float32List extrema(int requiredLength) =>
      _ensure(_extrema, requiredLength, (value) => _extrema = value);

  Float32List _ensure(
    Float32List current,
    int requiredLength,
    void Function(Float32List value) replace,
  ) {
    if (current.length >= requiredLength) return current;
    var capacity = math.max(256, current.length);
    while (capacity < requiredLength) {
      capacity *= 2;
    }
    final next = Float32List(capacity);
    replace(next);
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.geometryBufferGrowth,
    );
    return next;
  }
}

class _PlotPalette {
  final Color background;
  final Color grid;
  final Color axis;
  final Color axisStrong;
  final Color tooltipBackground;
  final Color tooltipBorder;
  final Color tooltipText;
  final Color tooltipSubtleText;
  final Color measurementPrimary;
  final Color measurementSecondary;

  const _PlotPalette({
    required this.background,
    required this.grid,
    required this.axis,
    required this.axisStrong,
    required this.tooltipBackground,
    required this.tooltipBorder,
    required this.tooltipText,
    required this.tooltipSubtleText,
    required this.measurementPrimary,
    required this.measurementSecondary,
  });
}

/// 分层绘图 CustomPainter
///
/// 四个实例共享绘制算法，但每个实例只绘制一个图层，并按该层依赖判断重绘。
/// 主绘图区四层渲染中的数据、坐标轴和交互覆盖 Painter。
///
/// Painter 只消费不可变 [PlotRenderSnapshot]：大范围优先查询 LOD，精确窗口覆盖
/// 当前视口时才使用原始点，避免在 paint 阶段遍历全量历史或修改 ViewModel。
class PlotLayerPainter extends CustomPainter {
  static const double _denseLinePointThresholdRatio = 0.5;
  static const double _invalidPointThresholdRatio = 0.5;
  static const PlotDataRenderer _dataRenderer = CanvasPlotDataRenderer();

  final PlotPaintLayer layer;
  final PlotRenderSnapshot snapshot;
  final PlotGeometryBuffers? geometryBuffers;
  final bool externalDataClip;
  final double dataQueryPadding;
  final VoidCallback? onPaintCompleted;
  final PlotGeometryWorkspace _fallbackQueryWorkspace = PlotGeometryWorkspace();

  PlotViewport get viewport => snapshot.viewport;
  List<PlotDataPoint> get data => snapshot.data;
  int get dataRevision => snapshot.dataRevision;
  int get channelConfigRevision => snapshot.channelConfigRevision;
  int get viewportRevision => snapshot.viewportRevision;
  int get overlayRevision => snapshot.overlayRevision;
  PlotLodSource? get lodIndex => snapshot.lodIndex;
  PlotLodQuality get lodQuality => snapshot.lodQuality;
  bool get interactionActive => snapshot.interactionActive;
  double get devicePixelRatio => snapshot.devicePixelRatio;
  List<ChannelConfig> get channels => snapshot.channels;
  int get activeChannelCount => snapshot.activeChannelCount;
  bool get showGrid => snapshot.showGrid;
  GridDensity get gridDensity => snapshot.gridDensity;
  PlotBackgroundStyle get backgroundStyle => snapshot.backgroundStyle;
  double get floatingPanelOpacity => snapshot.floatingPanelOpacity;
  CursorState? get cursor => snapshot.cursor;
  double? get xCursor1 => snapshot.xCursor1;
  double? get xCursor2 => snapshot.xCursor2;
  double? get yCursor1 => snapshot.yCursor1;
  double? get yCursor2 => snapshot.yCursor2;
  List<PlotMeasurementGroup> get xMeasurementGroups =>
      snapshot.xMeasurementGroups;
  List<PlotMeasurementGroup> get yMeasurementGroups =>
      snapshot.yMeasurementGroups;
  Color? get xMeasurementLine1Color => snapshot.xMeasurementLine1Color;
  Color? get xMeasurementLine2Color => snapshot.xMeasurementLine2Color;
  Color? get yMeasurementLine1Color => snapshot.yMeasurementLine1Color;
  Color? get yMeasurementLine2Color => snapshot.yMeasurementLine2Color;
  double get xMeasurementLine1Opacity => snapshot.xMeasurementLine1Opacity;
  double get xMeasurementLine2Opacity => snapshot.xMeasurementLine2Opacity;
  double get yMeasurementLine1Opacity => snapshot.yMeasurementLine1Opacity;
  double get yMeasurementLine2Opacity => snapshot.yMeasurementLine2Opacity;
  bool get statsEnabled => snapshot.statsEnabled;
  bool get statsRangeEnabled => snapshot.statsRangeEnabled;
  double? get statsX1 => snapshot.statsX1;
  double? get statsX2 => snapshot.statsX2;
  List<SnapHighlightPoint> get snapHighlights => snapshot.snapHighlights;
  bool get snapHighlightEnabled => snapshot.snapHighlightEnabled;
  double get snapHighlightDiameter => snapshot.snapHighlightDiameter;
  bool get antiAliasEnabled => snapshot.antiAliasEnabled;
  bool get yValuesAreInteger => snapshot.yValuesAreInteger;
  int get plotFontSizeDelta => snapshot.plotFontSizeDelta;
  bool get plotFontBold => snapshot.plotFontBold;

  PlotLayerPainter({
    required this.layer,
    required PlotViewport viewport,
    required List<PlotDataPoint> data,
    int dataRevision = 0,
    int channelConfigRevision = 0,
    int viewportRevision = 0,
    int overlayRevision = 0,
    PlotLodSource? lodIndex,
    PlotLodQuality lodQuality = PlotLodQuality.performance,
    required List<ChannelConfig> channels,
    int? activeChannelCount,
    bool showGrid = true,
    GridDensity gridDensity = GridDensity.normal,
    PlotBackgroundStyle backgroundStyle = PlotBackgroundStyle.dark,
    double floatingPanelOpacity = 0.85,
    CursorState? cursor,
    double? xCursor1,
    double? xCursor2,
    double? yCursor1,
    double? yCursor2,
    Color? xMeasurementLine1Color,
    Color? xMeasurementLine2Color,
    Color? yMeasurementLine1Color,
    Color? yMeasurementLine2Color,
    double xMeasurementLine1Opacity = 1,
    double xMeasurementLine2Opacity = 1,
    double yMeasurementLine1Opacity = 1,
    double yMeasurementLine2Opacity = 1,
    bool statsEnabled = false,
    bool statsRangeEnabled = false,
    double? statsX1,
    double? statsX2,
    List<SnapHighlightPoint> snapHighlights = const [],
    bool snapHighlightEnabled = true,
    double snapHighlightDiameter = 8,
    bool antiAliasEnabled = true,
    bool yValuesAreInteger = false,
    int plotFontSizeDelta = 0,
    bool plotFontBold = false,
    this.geometryBuffers,
    this.externalDataClip = false,
    this.dataQueryPadding = 0,
    this.onPaintCompleted,
  }) : snapshot = PlotRenderSnapshot(
         viewport: viewport,
         data: data,
         dataRevision: dataRevision,
         channelConfigRevision: channelConfigRevision,
         viewportRevision: viewportRevision,
         overlayRevision: overlayRevision,
         lodIndex: lodIndex,
         lodQuality: lodQuality,
         channels: channels,
         activeChannelCount: activeChannelCount,
         showGrid: showGrid,
         gridDensity: gridDensity,
         backgroundStyle: backgroundStyle,
         floatingPanelOpacity: floatingPanelOpacity,
         cursor: cursor,
         xCursor1: xCursor1,
         xCursor2: xCursor2,
         yCursor1: yCursor1,
         yCursor2: yCursor2,
         xMeasurementLine1Color: xMeasurementLine1Color,
         xMeasurementLine2Color: xMeasurementLine2Color,
         yMeasurementLine1Color: yMeasurementLine1Color,
         yMeasurementLine2Color: yMeasurementLine2Color,
         xMeasurementLine1Opacity: xMeasurementLine1Opacity,
         xMeasurementLine2Opacity: xMeasurementLine2Opacity,
         yMeasurementLine1Opacity: yMeasurementLine1Opacity,
         yMeasurementLine2Opacity: yMeasurementLine2Opacity,
         statsEnabled: statsEnabled,
         statsRangeEnabled: statsRangeEnabled,
         statsX1: statsX1,
         statsX2: statsX2,
         snapHighlights: snapHighlights,
         snapHighlightEnabled: snapHighlightEnabled,
         snapHighlightDiameter: snapHighlightDiameter,
         antiAliasEnabled: antiAliasEnabled,
         yValuesAreInteger: yValuesAreInteger,
         plotFontSizeDelta: plotFontSizeDelta,
         plotFontBold: plotFontBold,
       );

  PlotLayerPainter.fromSnapshot({
    required this.layer,
    required this.snapshot,
    this.geometryBuffers,
    this.externalDataClip = false,
    this.dataQueryPadding = 0,
    this.onPaintCompleted,
  });

  double _fontSize(double base) {
    return (base + 1 + plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  bool get _isLightBackground => backgroundStyle == PlotBackgroundStyle.light;

  _PlotPalette get _palette {
    return switch (backgroundStyle) {
      PlotBackgroundStyle.dark => const _PlotPalette(
        background: Color(0xFF1A1A2E),
        grid: Color(0xFF2D2D44),
        axis: Color(0xFF8888AA),
        axisStrong: Color(0xFFCCCCDD),
        tooltipBackground: Color(0xFF1A1A2E),
        tooltipBorder: Color(0xFF8888AA),
        tooltipText: Colors.white,
        tooltipSubtleText: Colors.white70,
        measurementPrimary: Colors.cyan,
        measurementSecondary: Colors.yellow,
      ),
      PlotBackgroundStyle.light => const _PlotPalette(
        background: Color(0xFFF8FAFC),
        grid: Color(0xFFDDE3EA),
        axis: Color(0xFF64748B),
        axisStrong: Color(0xFF334155),
        tooltipBackground: Colors.white,
        tooltipBorder: Color(0xFF94A3B8),
        tooltipText: Color(0xFF0F172A),
        tooltipSubtleText: Color(0xFF475569),
        measurementPrimary: Color(0xFF0369A1),
        measurementSecondary: Color(0xFFB45309),
      ),
    };
  }

  Color _plotChannelColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    if (_isLightBackground && color.computeLuminance() > 0.55) {
      return hsl.withLightness(math.min(hsl.lightness, 0.42)).toColor();
    }
    if (!_isLightBackground && color.computeLuminance() < 0.18) {
      return hsl.withLightness(math.max(hsl.lightness, 0.62)).toColor();
    }
    return color;
  }

  static double _fontSizeFor(double base, double delta) {
    return (base + 1 + delta).clamp(6.0, 24.0).toDouble();
  }

  static double debugFontSizeFor(double base, double delta) {
    return _fontSizeFor(base, delta);
  }

  static double calculateLeftAxisWidth({
    required PlotViewport viewport,
    required double canvasHeight,
    required GridDensity gridDensity,
    required double plotFontSizeDelta,
    required bool plotFontBold,
  }) {
    final plotHeight = viewport.plotHeight(canvasHeight);
    if (plotHeight <= 0 || viewport.yRange <= 0) {
      return PlotViewport.defaultMarginLeft;
    }

    final step = _calculateYTickStepFor(
      viewport.yRange,
      plotHeight,
      gridDensity,
      yValuesAreInteger: true,
    );
    final tickValues = _tickValuesForRange(viewport.yMin, viewport.yMax, step);
    final textStyle = TextStyle(
      fontSize: _fontSizeFor(12, plotFontSizeDelta),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );
    var maxTextWidth = 0.0;
    for (final value in tickValues) {
      maxTextWidth = math.max(
        maxTextWidth,
        _measureRawTextWidth(_formatNumberFor(value, true), textStyle),
      );
    }
    if (viewport.yMin <= 0 && viewport.yMax >= 0) {
      maxTextWidth = math.max(
        maxTextWidth,
        _measureRawTextWidth(
          '0',
          textStyle.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    }

    const tickAndPadding = 16.0;
    return math.max(
      PlotViewport.defaultMarginLeft,
      maxTextWidth + tickAndPadding,
    );
  }

  static List<double> calculateOffsetAxisColumnWidths({
    required PlotViewport viewport,
    required List<ChannelConfig> channels,
    required int activeChannelCount,
    required double canvasHeight,
    required GridDensity gridDensity,
    required double plotFontSizeDelta,
    required bool plotFontBold,
    required bool yValuesAreInteger,
  }) {
    final plotH = viewport.plotHeight(canvasHeight);
    if (plotH <= 0) return const [];

    final textStyle = TextStyle(
      fontSize: _fontSizeFor(11, plotFontSizeDelta),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );
    final widths = <double>[];

    for (final ch in _visibleOffsetAxisChannels(channels, activeChannelCount)) {
      var maxTextWidth = 0.0;
      final tickValues = _offsetAxisTickValuesFor(
        viewport,
        ch,
        plotH,
        gridDensity,
      );

      for (final originalValue in tickValues) {
        final displayValue = originalValue * ch.yScale + ch.yOffset;
        final y = viewport.dataToScreenY(displayValue, canvasHeight);
        if (y < viewport.marginTop || y > viewport.marginTop + plotH) {
          continue;
        }
        maxTextWidth = math.max(
          maxTextWidth,
          _measureRawTextWidth(
            _formatNumberFor(originalValue, true),
            textStyle,
          ),
        );
      }

      const tickAndPadding = 14.0;
      widths.add(maxTextWidth + tickAndPadding);
    }

    return widths;
  }

  static List<double> _offsetAxisTickValuesFor(
    PlotViewport viewport,
    ChannelConfig channel,
    double plotHeight,
    GridDensity gridDensity,
  ) {
    final scale = channel.yScale;
    if (!scale.isFinite || scale == 0 || !channel.yOffset.isFinite) {
      return const [];
    }

    final first = (viewport.yMin - channel.yOffset) / scale;
    final second = (viewport.yMax - channel.yOffset) / scale;
    final minValue = math.min(first, second);
    final maxValue = math.max(first, second);
    final step = _calculateYTickStepFor(
      maxValue - minValue,
      plotHeight,
      gridDensity,
      yValuesAreInteger: true,
    );
    return _tickValuesForRange(minValue, maxValue, step);
  }

  static List<ChannelConfig> _visibleOffsetAxisChannels(
    List<ChannelConfig> channels,
    int activeChannelCount,
  ) {
    final result = <ChannelConfig>[];
    final seenGroups = <int>{};
    for (final channel in channels.take(activeChannelCount)) {
      if (!channel.visible || !channel.offsetEnabled) continue;
      final groupId = channel.offsetBindingGroupId;
      if (groupId != null) {
        if (!seenGroups.add(groupId)) continue;
      }
      result.add(channel);
    }
    return result;
  }

  /// 判断两个视口是否相等（用于重绘判断）
  bool _viewportEquals(PlotViewport a, PlotViewport b) {
    return a.xMin == b.xMin &&
        a.xMax == b.xMax &&
        a.yMin == b.yMin &&
        a.yMax == b.yMax &&
        a.marginLeft == b.marginLeft &&
        _doubleListsEqual(a.offsetAxisColumnWidths, b.offsetAxisColumnWidths);
  }

  bool _doubleListsEqual(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (layer) {
      case PlotPaintLayer.background:
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.backgroundPainterPaint,
        );
        _drawBackground(canvas, size);
        if (showGrid) _drawGrid(canvas, size);
        break;
      case PlotPaintLayer.data:
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.dataPainterPaint,
        );
        _drawChannels(canvas, size);
        onPaintCompleted?.call();
        break;
      case PlotPaintLayer.axis:
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.axisPainterPaint,
        );
        _drawAxes(canvas, size);
        _drawChannelOffsetBaselines(canvas, size);
        break;
      case PlotPaintLayer.overlay:
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.overlayPainterPaint,
        );
        if (xMeasurementGroups.isNotEmpty) {
          for (var i = 0; i < xMeasurementGroups.length; i++) {
            final group = xMeasurementGroups[i];
            _drawXMeasurement(
              canvas,
              size,
              group.cursor1,
              group.cursor2,
              viewport.plotHeight(size.height),
              i,
            );
          }
        } else if (xCursor1 != null || xCursor2 != null) {
          _drawXMeasurement(
            canvas,
            size,
            xCursor1,
            xCursor2,
            viewport.plotHeight(size.height),
            0,
          );
        }
        if (yMeasurementGroups.isNotEmpty) {
          for (var i = 0; i < yMeasurementGroups.length; i++) {
            final group = yMeasurementGroups[i];
            _drawYMeasurement(
              canvas,
              size,
              group.cursor1,
              group.cursor2,
              viewport.plotWidth(size.width),
              i,
            );
          }
        } else if (yCursor1 != null || yCursor2 != null) {
          _drawYMeasurement(
            canvas,
            size,
            yCursor1,
            yCursor2,
            viewport.plotWidth(size.width),
            0,
          );
        }
        _drawSnapHighlights(canvas, size);
        if (statsEnabled &&
            statsRangeEnabled &&
            statsX1 != null &&
            statsX2 != null) {
          _drawStatsRange(canvas, size);
        }
        // 光标和浮窗最后绘制，避免被测量线遮挡。
        _drawCursor(canvas, size);
        break;
    }
  }

  /// 绘制深色背景
  void _drawBackground(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = _palette.background
          ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  /// 绘制网格线和 Y=0 基准线
  void _drawGrid(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = _palette.grid
          ..strokeWidth = 0.5
          ..style = PaintingStyle.stroke
          ..isAntiAlias = antiAliasEnabled;

    final plotW = viewport.plotWidth(size.width);
    final plotH = viewport.plotHeight(size.height);
    if (plotW <= 0 || plotH <= 0) return;

    // 批量绘制网格线：先收集所有线，用 drawRawPoints 或 Path 优化
    final gridPath = Path();

    // 垂直网格线：按绝对 X 值生成 nice number 刻度，平移时网格随数据移动。
    for (final value in _xTickValues(size)) {
      final x = viewport.dataToScreenX(value, size.width);
      gridPath.moveTo(x, viewport.marginTop);
      gridPath.lineTo(x, viewport.marginTop + plotH);
    }

    // 水平网格线：复用 Y 轴 nice number 刻度值，避免刻度值和背景线错位。
    for (final value in _yTickValues(size, includeZero: true)) {
      final y = viewport.dataToScreenY(value, size.height);
      gridPath.moveTo(viewport.marginLeft, y);
      gridPath.lineTo(viewport.marginLeft + plotW, y);
    }

    canvas.drawPath(gridPath, paint);
  }

  List<double> _xTickValues(Size size) {
    final plotW = viewport.plotWidth(size.width);
    if (plotW <= 0 || viewport.xRange <= 0) return const [];
    final textStyle = TextStyle(
      fontSize: _fontSize(12),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );
    final widestLabel = math.max(
      _measureRawTextWidth(_formatNumber(viewport.xMin, false), textStyle),
      _measureRawTextWidth(_formatNumber(viewport.xMax, false), textStyle),
    );
    final step = _calculateXTickStepFor(
      viewport.xRange,
      plotW,
      gridDensity,
      minimumSpacing: widestLabel + 12,
    );
    return _tickValuesForRange(viewport.xMin, viewport.xMax, step);
  }

  List<double> _yTickValues(Size size, {required bool includeZero}) {
    final plotH = viewport.plotHeight(size.height);
    if (plotH <= 0 || viewport.yRange <= 0) return const [];
    final step = _calculateYTickStepFor(
      viewport.yRange,
      plotH,
      gridDensity,
      yValuesAreInteger: true,
    );
    if (step <= 0) return const [];

    final result = <double>[];
    final startValue = (viewport.yMin / step).floor() * step;
    for (
      double value = startValue;
      value <= viewport.yMax + step * 0.5;
      value += step
    ) {
      if (value < viewport.yMin || value > viewport.yMax) continue;
      final y = viewport.dataToScreenY(value, size.height);
      if (y < viewport.marginTop || y > viewport.marginTop + plotH) continue;
      result.add(value);
    }

    if (includeZero && viewport.yMin <= 0 && viewport.yMax >= 0) {
      final hasZero = result.any((value) => value.abs() < 1e-9);
      final zeroY = viewport.dataToScreenY(0, size.height);
      if (!hasZero &&
          zeroY >= viewport.marginTop &&
          zeroY <= viewport.marginTop + plotH) {
        result.add(0);
      }
    }
    result.sort();
    return result;
  }

  static int _calculateGridCountFor(double length, GridDensity gridDensity) {
    return _calculateGridCountWithSpacing(length, _gridSpacingFor(gridDensity));
  }

  static double _gridSpacingFor(GridDensity gridDensity) {
    return switch (gridDensity) {
      GridDensity.sparse => 160.0,
      GridDensity.normal => 80.0,
      GridDensity.dense => 40.0,
    };
  }

  static int debugXGridCountFor(double length) {
    return _calculateGridCountFor(length, GridDensity.normal);
  }

  static List<double> debugXTickValuesFor(
    double xMin,
    double xMax,
    double plotWidth, {
    GridDensity gridDensity = GridDensity.normal,
    double minimumSpacing = 0,
  }) {
    final range = xMax - xMin;
    final step = _calculateXTickStepFor(
      range,
      plotWidth,
      gridDensity,
      minimumSpacing: minimumSpacing,
    );
    return _tickValuesForRange(xMin, xMax, step);
  }

  static double _calculateXTickStepFor(
    double xRange,
    double plotWidth,
    GridDensity gridDensity, {
    double minimumSpacing = 0,
  }) {
    if (xRange <= 0 || plotWidth <= 0) return 0;
    final effectiveSpacing = math.max(
      _gridSpacingFor(gridDensity),
      minimumSpacing,
    );
    final targetCount = _calculateGridCountWithSpacing(
      plotWidth,
      effectiveSpacing,
    );
    // X 轴必须向上选择规则步长，防止取到更小步长后文字间距低于目标值。
    return math.max(1.0, _niceNumberFor(xRange / targetCount, false));
  }

  static List<double> _tickValuesForRange(
    double minValue,
    double maxValue,
    double step,
  ) {
    if (step <= 0 || maxValue < minValue) return const [];
    final firstTick = (minValue / step).ceil();
    final lastTick = (maxValue / step).floor();
    if (lastTick < firstTick) return const [];

    final values = <double>[];
    for (
      var tick = firstTick;
      tick <= lastTick && values.length < 100;
      tick++
    ) {
      final value = tick * step;
      values.add(value == 0 ? 0 : value);
    }
    return values;
  }

  static double debugYTickStepFor(
    double yRange,
    double plotHeight,
    GridDensity gridDensity, {
    bool yValuesAreInteger = false,
  }) {
    return _calculateYTickStepFor(
      yRange,
      plotHeight,
      gridDensity,
      yValuesAreInteger: yValuesAreInteger,
    );
  }

  static List<double> debugOffsetAxisTickValuesFor({
    required PlotViewport viewport,
    required ChannelConfig channel,
    required double plotHeight,
    GridDensity gridDensity = GridDensity.normal,
  }) {
    return _offsetAxisTickValuesFor(viewport, channel, plotHeight, gridDensity);
  }

  static double _calculateYTickStepFor(
    double yRange,
    double plotHeight,
    GridDensity gridDensity, {
    required bool yValuesAreInteger,
  }) {
    if (yRange <= 0 || plotHeight <= 0) return 0;

    final normalCount = _calculateGridCountFor(plotHeight, GridDensity.normal);
    final normalRoughStep = yRange / normalCount;
    final normalStep = _niceNumberFor(
      yValuesAreInteger ? math.max(1.0, normalRoughStep) : normalRoughStep,
      true,
    );
    final factor = switch (gridDensity) {
      GridDensity.sparse => 2.0,
      GridDensity.normal => 1.0,
      GridDensity.dense => 0.5,
    };
    final step = _niceNumberFor(normalStep * factor, true);
    return yValuesAreInteger ? math.max(1.0, step) : step;
  }

  static int _calculateGridCountWithSpacing(
    double length,
    double effectiveSpacing,
  ) {
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
    // 逐通道选择精确点或 LOD；背景、网格和坐标轴与数据绘制保持分层。
    if (data.isEmpty && (lodIndex == null || lodIndex!.isEmpty)) return;

    // 找到可见范围内的数据索引（缓存）
    final visibleIndices = _getVisibleRange();

    // 降采样：缩小时按像素桶保留 min/max，避免构建超长 Path。
    final plotW = viewport.plotWidth(size.width);
    final historyLength =
        lodIndex?.length ?? (data.isEmpty ? 0 : data.last.index + 1);
    final viewportDataCount = _visibleHistoryPointCount(historyLength);

    // 三档只改变 PlotViewportQuery 的几何密度：直接绘制原始点的阈值为
    // 每物理像素 1/2/4 点，高密度 M4 的列跨度为 2/1/1 个物理像素。
    // 接收阶段的增量 LOD、线条样式、抗锯齿和渲染后端均不随档位变化。
    final exactWindowCoversViewport = _exactWindowCoversViewport(
      visibleIndices,
    );
    final hasLod = lodIndex != null && lodIndex!.isNotEmpty;
    final plotH = viewport.plotHeight(size.height);
    if (plotW <= 0 || plotH <= 0) return;

    // LOD 换窗预览会保留视口两侧的桶边界点用于连线，
    // 数据层必须裁剪在主绘图矩形内，避免线段画入坐标轴或通道面板。
    if (!externalDataClip) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(viewport.marginLeft, viewport.marginTop, plotW, plotH),
      );
    }

    // 批量绘制：先收集所有通道的 Path，减少 Canvas 状态切换
    for (int ch = 0; ch < channels.length && ch < activeChannelCount; ch++) {
      final channel = channels[ch];
      if (!channel.visible) continue;
      if (!hasLod &&
          (visibleIndices.start >= visibleIndices.end ||
              ch >= data.first.values.length)) {
        continue;
      }

      _drawChannelOptimized(
        canvas,
        size,
        ch,
        channel,
        visibleIndices,
        exactWindowCoversViewport,
        viewportDataCount,
      );
    }
    if (!externalDataClip) canvas.restore();
  }

  bool _exactWindowCoversViewport(_Range visibleRange) {
    if (visibleRange.start >= visibleRange.end || data.isEmpty) return false;
    final historyLength = lodIndex?.length ?? data.length;
    if (historyLength <= 0) return false;
    final expectedStart = viewport.xMin.ceil().clamp(0, historyLength - 1);
    final expectedEnd = viewport.xMax.floor().clamp(0, historyLength - 1);
    if (expectedEnd < expectedStart) return false;

    final firstIndex = data[visibleRange.start].index;
    final lastIndex = data[visibleRange.end - 1].index;
    final visibleCount = visibleRange.end - visibleRange.start;
    return firstIndex <= expectedStart &&
        lastIndex >= expectedEnd &&
        visibleCount >= expectedEnd - expectedStart + 1;
  }

  double _visibleHistoryPointCount(int historyLength) {
    if (historyLength <= 0) return 0;
    final start = viewport.xMin.ceil().clamp(0, historyLength - 1);
    final end = viewport.xMax.floor().clamp(0, historyLength - 1);
    return end < start ? 0 : (end - start + 1).toDouble();
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
    bool exactWindowCoversViewport,
    double viewportDataCount,
  ) {
    final visibleCount = math.max(0, viewportDataCount.round());
    PlotGeometryBatch? sharedGeometry;
    var geometryQueried = false;

    PlotGeometryBatch? querySharedGeometry() {
      if (geometryQueried) return sharedGeometry;
      geometryQueried = true;
      final buffers = geometryBuffers;
      final geometryStopwatch =
          PlotPerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
      final queryPadding = viewport.xRange * dataQueryPadding;
      final queryWidthScale = 1 + dataQueryPadding * 2;
      sharedGeometry = PlotViewportQuery.queryChannel(
        exactData: data,
        rangeIndex: lodIndex,
        channelIndex: channelIndex,
        xMin: viewport.xMin - queryPadding,
        xMax: viewport.xMax + queryPadding,
        logicalPlotWidth: viewport.plotWidth(size.width) * queryWidthScale,
        devicePixelRatio: devicePixelRatio,
        quality: lodQuality,
        workspace: buffers?.viewportQuery ?? _fallbackQueryWorkspace,
      );
      if (geometryStopwatch != null) {
        geometryStopwatch.stop();
        PlotPerformanceMetrics.instance.record(
          PlotPerformanceMetric.geometryBuildMicros,
          geometryStopwatch.elapsedMicroseconds,
        );
      }
      return sharedGeometry;
    }

    if (channel.showLine && visibleCount > 1) {
      final channelColor = _plotChannelColor(channel.color);
      final linePaint =
          Paint()
            ..color = channelColor
            ..strokeWidth = channel.lineWidth
            ..style = PaintingStyle.stroke
            // 高密度折线的拖动瓶颈位于 Raster，而不是查询或几何生成。
            // 交互期间关闭抗锯齿只影响边缘平滑，不改变 M4 点序、峰谷、
            // 阶跃和脉冲宽度；松开后由最终质量帧立即恢复用户设置。
            ..isAntiAlias = antiAliasEnabled && !interactionActive;

      final buffers = geometryBuffers;
      final geometry = querySharedGeometry();
      if (geometry != null && geometry.length > 1) {
        final stopwatch =
            PlotPerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
        _dataRenderer.drawLineBatch(
          canvas: canvas,
          size: size,
          viewport: viewport,
          channel: channel,
          batch: geometry,
          paint: linePaint,
          acquirePoints:
              buffers?.points ??
              Float32List.new,
        );
        if (stopwatch != null) {
          stopwatch.stop();
          PlotPerformanceMetrics.instance
            ..record(
              PlotPerformanceMetric.canvasSubmitMicros,
              stopwatch.elapsedMicroseconds,
            )
            ..record(PlotPerformanceMetric.geometryPointCount, geometry.length);
        }
      } else {
        // 测试构造或旧调用未提供共享工作区时保留精确原始路径；正式页面
        // 始终通过 PlotViewportQuery 生成几何。
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
        channel.showLine &&
        visibleCount >
            math.max(1, plotW * _denseLinePointThresholdRatio).round();
    if (!hidePointsForDenseLine) {
      final channelColor = _plotChannelColor(channel.color);
      final pointPaint =
          Paint()
            ..color = channelColor
            ..style = PaintingStyle.fill
            ..strokeWidth = channel.pointSize;
      final geometry = querySharedGeometry();
      if (geometry != null && !geometry.isEmpty) {
        _drawGeometryPoints(canvas, size, channel, geometry, pointPaint);
      } else if (exactWindowCoversViewport ||
          (visibleRange.start < visibleRange.end &&
              (lodIndex == null || lodIndex!.isEmpty))) {
        _drawChannelPoints(
          canvas,
          size,
          channelIndex,
          channel,
          visibleRange,
          pointPaint,
        );
      } else {
        final lodSeries = _queryLodSeries(channel.index, size);
        if (lodSeries != null && lodSeries.isNotEmpty) {
          _drawChannelLodPoints(canvas, size, channel, lodSeries, pointPaint);
        }
      }
    }
  }

  /// 点与折线必须消费同一份视口几何；精确窗口换页期间若分别读取原始
  /// 窗口和LOD摘要，会在拖动尚未结束时出现点线错位。
  void _drawGeometryPoints(
    Canvas canvas,
    Size size,
    ChannelConfig channel,
    PlotGeometryBatch geometry,
    Paint paint,
  ) {
    final buffers = geometryBuffers;
    final rawPoints =
        buffers?.points(geometry.length * 2) ??
        Float32List(geometry.length * 2);
    var outputLength = 0;
    for (var point = 0; point < geometry.length; point++) {
      final value = geometry.values[point] * channel.yScale + channel.yOffset;
      if (!value.isFinite) continue;
      rawPoints[outputLength++] = viewport.dataToScreenX(
        geometry.indices[point].toDouble(),
        size.width,
      );
      rawPoints[outputLength++] = viewport.dataToScreenY(value, size.height);
    }
    if (outputLength == 0) return;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.sublistView(rawPoints, 0, outputLength),
      paint,
    );
  }

  PlotLodSeries? _queryLodSeries(int channelIndex, Size size) {
    final source = lodIndex;
    if (source == null) return null;
    final plotWidth = viewport.plotWidth(size.width);
    return source.query(
          channelIndex: channelIndex,
          xMin: viewport.xMin,
          xMax: viewport.xMax,
          plotWidth: plotWidth,
          quality: lodQuality,
          useViewportCache: true,
          // 拖动时保持用户选择的摘要层级。形状正确是硬约束，性能优化只能
          // 来自缓存、缓冲复用和静态纹理平移，不能通过放粗桶换取帧率。
          targetBucketScale: 1,
        ) ??
        source.queryCoarse(
          channelIndex: channelIndex,
          xMin: viewport.xMin,
          xMax: viewport.xMax,
          plotWidth: plotWidth,
        );
  }

  void _drawChannelLodPoints(
    Canvas canvas,
    Size size,
    ChannelConfig channel,
    PlotLodSeries series,
    Paint paint,
  ) {
    if (series.isEmpty) return;

    final rawPoints =
        geometryBuffers?.points(series.length * 2) ??
        Float32List(series.length * 2);
    var rawIndex = 0;
    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    for (int i = 0; i < series.length; i++) {
      rawPoints[rawIndex++] = viewport.dataToScreenX(
        series.indices[i].toDouble(),
        size.width,
      );
      rawPoints[rawIndex++] = viewport
          .dataToScreenY(
            series.values[i] * channel.yScale + channel.yOffset,
            size.height,
          )
          .clamp(marginTop, marginBottom);
    }

    canvas.drawRawPoints(ui.PointMode.points, rawPoints, paint);
  }

  void _drawChannelRawPath(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    Paint paint,
  ) {
    final rawPoints =
        geometryBuffers?.points((visibleRange.end - visibleRange.start) * 2) ??
        Float32List((visibleRange.end - visibleRange.start) * 2);
    var rawIndex = 0;
    final marginTop = viewport.marginTop;
    final marginBottom = size.height - viewport.marginBottom;

    var hasInvalid = false;
    for (int i = visibleRange.start; i < visibleRange.end; i++) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;
      final value = _displayValue(point, channelIndex, channel);
      if (!value.isFinite) {
        hasInvalid = true;
        continue;
      }
      rawPoints[rawIndex++] = viewport.dataToScreenX(
        point.index.toDouble(),
        size.width,
      );
      rawPoints[rawIndex++] = viewport
          .dataToScreenY(value, size.height)
          .clamp(marginTop, marginBottom);
    }

    if (hasInvalid) {
      _drawInvalidAwareRawPath(
        canvas,
        size,
        channelIndex,
        channel,
        visibleRange,
        paint,
      );
      return;
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
      final value = _displayValue(point, channelIndex, channel);
      if (!value.isFinite) continue;
      rawPoints[rawIndex++] = viewport.dataToScreenX(
        point.index.toDouble(),
        size.width,
      );
      rawPoints[rawIndex++] = viewport
          .dataToScreenY(value, size.height)
          .clamp(marginTop, marginBottom);
    }

    if (rawIndex > 0) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.sublistView(rawPoints, 0, rawIndex),
        paint..strokeWidth = channel.pointSize,
      );
    }
  }

  double _displayValue(
    PlotDataPoint point,
    int channelIndex,
    ChannelConfig channel,
  ) {
    final value = point.values[channelIndex];
    if (!value.isFinite) return double.nan;
    final displayValue = value * channel.yScale + channel.yOffset;
    return displayValue.isFinite ? displayValue : double.nan;
  }

  void _drawInvalidAwareRawPath(
    Canvas canvas,
    Size size,
    int channelIndex,
    ChannelConfig channel,
    _Range visibleRange,
    Paint normalPaint,
  ) {
    final dataCount = visibleRange.end - visibleRange.start;
    final plotW = viewport.plotWidth(size.width);
    if (dataCount > plotW * 2) return;

    final zeroY =
        viewport
            .dataToScreenY(0, size.height)
            .clamp(viewport.marginTop, size.height - viewport.marginBottom)
            .toDouble();
    final channelColor = _plotChannelColor(channel.color);
    final dashPaint =
        Paint()
          ..color = channelColor.withValues(alpha: 0.65)
          ..strokeWidth = math.max(1.0, channel.lineWidth)
          ..style = PaintingStyle.stroke;
    final invalidPoints = <Offset>[];
    final dashedPoints = <Offset>[];
    final showInvalidPoints =
        dataCount <= math.max(1, plotW * _invalidPointThresholdRatio).round();

    void flushDashedPoints() {
      if (dashedPoints.length >= 2) {
        _drawDashedPolyline(canvas, dashedPoints, dashPaint);
      }
      dashedPoints.clear();
    }

    Offset? previous;
    var previousInvalid = false;
    for (int i = visibleRange.start; i < visibleRange.end; i++) {
      final point = data[i];
      if (channelIndex >= point.values.length) continue;
      final x = viewport.dataToScreenX(point.index.toDouble(), size.width);
      final value = _displayValue(point, channelIndex, channel);
      final invalid = !value.isFinite;
      final y =
          invalid
              ? zeroY
              : viewport
                  .dataToScreenY(value, size.height)
                  .clamp(
                    viewport.marginTop,
                    size.height - viewport.marginBottom,
                  )
                  .toDouble();
      final current = Offset(x, y);
      if (previous != null) {
        if (previousInvalid || invalid) {
          if (dashedPoints.isEmpty) dashedPoints.add(previous);
          dashedPoints.add(current);
        } else {
          flushDashedPoints();
          canvas.drawLine(previous, current, normalPaint);
        }
      }
      if (showInvalidPoints && invalid) invalidPoints.add(current);
      previous = current;
      previousInvalid = invalid;
    }

    flushDashedPoints();
    _drawInvalidHollowPoints(canvas, invalidPoints, channel);
  }

  void _drawInvalidHollowPoints(
    Canvas canvas,
    List<Offset> invalidPoints,
    ChannelConfig channel,
  ) {
    if (invalidPoints.isEmpty) return;
    final pointPaint =
        Paint()
          ..color = _plotChannelColor(channel.color)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.75, channel.lineWidth * 0.75);
    final radius = math.max(1.5, channel.pointSize * 0.7);
    for (final point in invalidPoints) {
      canvas.drawCircle(point, radius, pointPaint);
    }
  }

  /// 绘制坐标轴、刻度线和刻度值
  void _drawSnapHighlights(Canvas canvas, Size size) {
    if (!snapHighlightEnabled || snapHighlights.isEmpty) return;
    for (final highlight in snapHighlights) {
      _drawSnapHighlightAt(
        canvas,
        size,
        highlight.x,
        highlight.y,
        highlight.color,
      );
    }
  }

  void _drawSnapHighlightAt(
    Canvas canvas,
    Size size,
    double x,
    double y,
    Color color,
  ) {
    final sx = viewport.dataToScreenX(x, size.width);
    final sy = viewport.dataToScreenY(y, size.height);
    final plotLeft = viewport.marginLeft;
    final plotRight = size.width - viewport.marginRight;
    final plotTop = PlotViewport().marginTop;
    final plotBottom = size.height - PlotViewport().marginBottom;
    if (sx < plotLeft || sx > plotRight || sy < plotTop || sy > plotBottom) {
      return;
    }

    final fillPaint =
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
    final strokePaint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..isAntiAlias = true;
    final radius = (snapHighlightDiameter / 2).clamp(3.0, 6.0).toDouble();
    canvas.drawCircle(Offset(sx, sy), radius, fillPaint);
    canvas.drawCircle(Offset(sx, sy), radius, strokePaint);
  }

  void _drawAxes(Canvas canvas, Size size) {
    final palette = _palette;
    final axisPaint =
        Paint()
          ..color = palette.axis
          ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: palette.axis,
      fontSize: _fontSize(12),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );

    final plotH = viewport.plotHeight(size.height);

    // X 轴
    canvas.drawLine(
      Offset(viewport.marginLeft, size.height - viewport.marginBottom),
      Offset(
        size.width - viewport.marginRight,
        size.height - viewport.marginBottom,
      ),
      axisPaint,
    );

    // Y 轴
    canvas.drawLine(
      Offset(viewport.marginLeft, viewport.marginTop),
      Offset(viewport.marginLeft, size.height - viewport.marginBottom),
      axisPaint,
    );

    // X 轴刻度使用绝对 nice number 值，避免固定等分产生混乱标签。
    for (final xValue in _xTickValues(size)) {
      final x = viewport.dataToScreenX(xValue, size.width);

      // 刻度线
      canvas.drawLine(
        Offset(x, size.height - viewport.marginBottom),
        Offset(x, size.height - viewport.marginBottom + 5),
        axisPaint,
      );

      // 刻度值
      _drawText(
        canvas,
        _formatNumber(xValue, false),
        Offset(x, size.height - viewport.marginBottom + 8),
        textStyle,
        alignCenter: true,
      );
    }

    // Y 轴刻度（使用 nice number 取整）
    final Set<double> drawnValues = {};
    for (final value in _yTickValues(size, includeZero: false)) {
      final y = viewport.dataToScreenY(value, size.height);
      drawnValues.add(value);

      // 刻度线
      canvas.drawLine(
        Offset(viewport.marginLeft - 5, y),
        Offset(viewport.marginLeft, y),
        axisPaint,
      );

      // 刻度值
      _drawText(
        canvas,
        _formatNumber(value, true),
        Offset(viewport.marginLeft - 8, y),
        textStyle,
        alignRight: true,
        alignVerticalCenter: true,
      );
    }

    // 常驻 Y=0 刻度（如果 0 在可见范围内且尚未绘制）
    if (viewport.yMin <= 0 &&
        viewport.yMax >= 0 &&
        !drawnValues.contains(0.0)) {
      final zeroY = viewport.dataToScreenY(0, size.height);
      if (zeroY >= viewport.marginTop && zeroY <= viewport.marginTop + plotH) {
        // 刻度线（稍长，突出显示）
        canvas.drawLine(
          Offset(viewport.marginLeft - 8, zeroY),
          Offset(viewport.marginLeft, zeroY),
          axisPaint,
        );

        // 刻度值：Y=0（加粗）
        final zeroTextStyle = TextStyle(
          color: palette.axisStrong,
          fontSize: _fontSize(12),
          fontFamily: 'SarasaUiSC',
          fontWeight: FontWeight.bold,
        );
        _drawText(
          canvas,
          '0',
          Offset(viewport.marginLeft - 8, zeroY),
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
    final left = viewport.marginLeft;
    final right = left + plotW;

    // 收集所有可见且开启偏移的通道，分配列索引。绑定组只占用一列。
    final offsetChannels = _visibleOffsetAxisChannels(
      channels,
      activeChannelCount,
    );

    var axisX = right;
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
        final channelColor = _plotChannelColor(ch.color);
        // 绘制水平虚线（通道颜色，半透明）
        final dashPaint =
            Paint()
              ..color = channelColor.withValues(alpha: 0.4)
              ..strokeWidth = 1.0;

        const dashLen = 6.0;
        const gapLen = 4.0;
        var x = left;
        while (x < right) {
          final endX = (x + dashLen).clamp(left, right);
          canvas.drawLine(Offset(x, zeroY), Offset(endX, zeroY), dashPaint);
          x += dashLen + gapLen;
        }

        // 绘制左侧标签。绑定组显示组名，完整通道名称放到图例中。
        final displayName = _offsetAxisLabel(ch);
        final labelStyle = TextStyle(
          color:
              channelColor.computeLuminance() > 0.5
                  ? Colors.black
                  : Colors.white,
          fontSize: _fontSize(10),
          fontWeight: FontWeight.bold,
          fontFamily: 'SarasaUiSC',
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
        canvas.drawRRect(bgRect, Paint()..color = channelColor);

        // 标签文字
        textPainter.paint(
          canvas,
          Offset(labelX + labelPadding.left, labelY + labelPadding.top),
        );
      }

      // 绘制右侧独立 Y 轴刻度（多列，每列向右偏移）—— 始终绘制，不依赖标签可见性
      _drawChannelYAxis(canvas, size, ch, axisX);
      axisX += _offsetAxisColumnWidth(colIndex);
    }
  }

  String _offsetAxisLabel(ChannelConfig channel) {
    final groupId = channel.offsetBindingGroupId;
    if (groupId == null) return _shortChannelName(channel);
    final names = channels
        .take(activeChannelCount)
        .where(
          (member) =>
              member.visible &&
              member.offsetEnabled &&
              member.offsetBindingGroupId == groupId,
        )
        .map(_shortChannelName)
        .toList(growable: false);
    if (names.isEmpty) return _shortChannelName(channel);
    return names.join('+');
  }

  String _shortChannelName(ChannelConfig channel) {
    return channel.index >= PlotConfiguration.rawChannelCount
        ? 'Math${channel.index - PlotConfiguration.rawChannelCount + 1}'
        : 'Ch${channel.index}';
  }

  double _offsetAxisColumnWidth(int colIndex) {
    final widths = viewport.offsetAxisColumnWidths;
    if (colIndex >= 0 && colIndex < widths.length) {
      return widths[colIndex];
    }
    return PlotViewport.minOffsetAxisColumnWidth;
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

    final tickValues = _offsetAxisTickValuesFor(
      viewport,
      ch,
      plotH,
      gridDensity,
    );
    final channelColor = _plotChannelColor(ch.color);

    final tickPaint =
        Paint()
          ..color = channelColor.withValues(alpha: 0.6)
          ..strokeWidth = 0.5;

    final textStyle = TextStyle(
      color: channelColor,
      fontSize: _fontSize(11),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );

    for (final originalValue in tickValues) {
      final displayValue = originalValue * ch.yScale + ch.yOffset;
      final y = viewport.dataToScreenY(displayValue, size.height);
      if (y < top || y > bottom) continue;

      // 刻度线（向右伸出）
      canvas.drawLine(Offset(axisX, y), Offset(axisX + 5, y), tickPaint);

      // 刻度值
      _drawOffsetAxisText(canvas, originalValue, axisX, y, textStyle);
    }

    // 绘制轴线
    final axisPaint =
        Paint()
          ..color = channelColor.withValues(alpha: 0.3)
          ..strokeWidth = 1.0;
    canvas.drawLine(Offset(axisX, top), Offset(axisX, bottom), axisPaint);
  }

  /// 绘制垂直光标（鼠标悬停跟随）
  void _drawCursor(Canvas canvas, Size size) {
    if (cursor == null) return;

    final plotRect = Rect.fromLTWH(
      viewport.marginLeft,
      viewport.marginTop,
      viewport.plotWidth(size.width),
      viewport.plotHeight(size.height),
    );
    if (plotRect.width <= 0 || plotRect.height <= 0) return;

    final sx = viewport.dataToScreenX(cursor!.x, size.width);
    // 快速换窗时光标仍可能保留上一帧的数据坐标；旧坐标离开视口后不再绘制。
    if (sx < plotRect.left || sx > plotRect.right) return;

    final cursorPaint =
        Paint()
          ..color = _palette.axisStrong
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;

    canvas.save();
    canvas.clipRect(plotRect);
    canvas.drawLine(
      Offset(sx, plotRect.top),
      Offset(sx, plotRect.bottom),
      cursorPaint,
    );
    _drawCursorTooltip(canvas, plotRect);
    canvas.restore();
  }

  /// 绘制垂直光标旁的各通道 Y 值 tooltip
  ///
  /// - 无数据（hasData=false）时整个 tooltip 不显示
  /// - 只显示有数据且 visible 的通道，不显示 "ChX: --"
  /// - 字体已放大以便阅读
  void _drawCursorTooltip(Canvas canvas, Rect plotRect) {
    if (cursor?.screenPosition == null) return;

    final screenPos = cursor!.screenPosition!;
    final hasData = cursor!.hasData;

    // 无数据时不显示tooltip
    if (!hasData) return;

    // 获取通道值（如果有数据）
    final List<double>? values = cursor?.channelValues;

    // 确定要显示的通道数：只显示有数据且可见的通道
    final valueStyle = TextStyle(
      fontSize: _fontSize(12),
      fontFamily: 'SarasaUiSC',
      fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
    );
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
            name: displayName,
            value: formatPlotValue(values[i]),
          ),
        );
      }
    }

    if (rows.isEmpty) return;

    // 计算tooltip尺寸
    final lineHeight = _fontSize(12) + 8;
    final headerHeight = _fontSize(12) + 10;
    const padding = 8.0;
    const markerAndGapWidth = 12.0;
    final separatorWidth = _measureRawTextWidth(': ', valueStyle);
    final maxValueWidth = rows.fold<double>(0, (width, row) {
      return math.max(width, _measureRawTextWidth(row.value, valueStyle));
    });
    final maxNameWidth = rows.fold<double>(0, (width, row) {
      return math.max(width, _measureRawTextWidth(row.name, valueStyle));
    });
    final desiredContentWidth =
        markerAndGapWidth + maxNameWidth + separatorWidth + maxValueWidth;
    final availableWidth = plotRect.width - 10;
    if (availableWidth <= 0) return;
    final tooltipWidth =
        math
            .min(
              availableWidth,
              math.max(120, desiredContentWidth + padding * 2),
            )
            .toDouble();
    final tooltipHeight = rows.length * lineHeight + padding * 2 + headerHeight;

    // 提示框锚点先限制在主绘图区，避免视口快速变化时沿用区域外的旧鼠标位置。
    final anchorX =
        screenPos.dx.clamp(plotRect.left, plotRect.right).toDouble();
    final anchorY =
        screenPos.dy.clamp(plotRect.top, plotRect.bottom).toDouble();
    var tooltipX = anchorX + 18;
    var tooltipY = anchorY + 18;

    // 提示框只在主绘图区内翻转和限位，不占用坐标轴或定位条区域。
    if (tooltipX + tooltipWidth > plotRect.right - 5) {
      tooltipX = anchorX - tooltipWidth - 10;
    }
    if (tooltipY + tooltipHeight > plotRect.bottom - 5) {
      tooltipY = anchorY - tooltipHeight - 10;
    }
    final minimumX = plotRect.left + 5;
    final minimumY = plotRect.top + 5;
    final maximumX = math.max(minimumX, plotRect.right - tooltipWidth - 5);
    final maximumY = math.max(minimumY, plotRect.bottom - tooltipHeight - 5);
    tooltipX = tooltipX.clamp(minimumX, maximumX).toDouble();
    tooltipY = tooltipY.clamp(minimumY, maximumY).toDouble();

    // 绘制背景
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tooltipX, tooltipY, tooltipWidth, tooltipHeight),
      const Radius.circular(4),
    );
    final palette = _palette;
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = palette.tooltipBackground.withValues(
          alpha: floatingPanelOpacity,
        )
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = palette.tooltipBorder
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // 绘制标题（X值）
    final headerStyle = TextStyle(
      color: palette.tooltipText,
      fontSize: _fontSize(12),
      fontWeight: FontWeight.bold,
      fontFamily: 'SarasaUiSC',
    );
    _drawText(
      canvas,
      'X: ${cursor!.x.toInt()}',
      Offset(tooltipX + padding, tooltipY + padding),
      headerStyle,
    );

    // 绘制分隔线（往下移，给标题更多空间）
    canvas.drawLine(
      Offset(tooltipX + padding, tooltipY + padding + headerHeight - 5),
      Offset(
        tooltipX + tooltipWidth - padding,
        tooltipY + padding + headerHeight - 5,
      ),
      Paint()
        ..color = palette.tooltipBorder
        ..strokeWidth = 0.5,
    );

    // 绘制各通道值（只显示有数据且visible的通道）
    int row = 0;
    for (final rowValue in rows) {
      // 只显示有数据值的通道，跳过数据范围外的
      final y = tooltipY + padding + headerHeight + row * lineHeight;
      final color = _plotChannelColor(channels[rowValue.index].color);

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
        fontSize: _fontSize(12),
        fontFamily: 'SarasaUiSC',
        fontWeight: plotFontBold ? FontWeight.bold : FontWeight.normal,
      );
      final valuePainter = TextPainter(
        text: TextSpan(text: rowValue.value, style: rowStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      final separatorPainter = TextPainter(
        text: TextSpan(text: ': ', style: rowStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      final nameX = tooltipX + padding + markerAndGapWidth;
      final rowRight = tooltipX + tooltipWidth - padding;
      final availableNameWidth = math.max(
        0.0,
        rowRight - nameX - separatorPainter.width - valuePainter.width,
      );
      var paintedNameWidth = 0.0;
      if (availableNameWidth > 0) {
        final namePainter = TextPainter(
          text: TextSpan(text: rowValue.name, style: rowStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '...',
        )..layout(maxWidth: availableNameWidth);
        namePainter.paint(canvas, Offset(nameX, y));
        paintedNameWidth = namePainter.width;
      }
      final separatorX = nameX + paintedNameWidth;
      separatorPainter.paint(canvas, Offset(separatorX, y));
      valuePainter.paint(
        canvas,
        Offset(separatorX + separatorPainter.width, y),
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

  void _drawOffsetAxisText(
    Canvas canvas,
    double value,
    double axisX,
    double y,
    TextStyle style, {
    double tickLength = 5,
  }) {
    const textGap = 2.0;
    final text = _formatNumber(value, true);
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(axisX + tickLength + textGap, y - textPainter.height / 2),
    );
  }

  static double _measureRawTextWidth(String text, TextStyle style) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return textPainter.width;
  }

  /// 将值取整到 "好看" 的数字（1, 2, 5, 10, 20, 50, 100...）
  static double _niceNumberFor(double value, bool round) {
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
    return _formatNumberFor(value, isY);
  }

  static String _formatNumberFor(double value, bool isY) {
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

  // ========== X-X / Y-Y 测量绘制 ==========
  /// 绘制 X-X 测量两条垂直线及标签
  void _drawXMeasurement(
    Canvas canvas,
    Size size,
    double? x1,
    double? x2,
    double plotH,
    int groupIndex,
  ) {
    if (x1 == null && x2 == null) return;

    final color1 = (xMeasurementLine1Color ?? _palette.measurementPrimary)
        .withValues(alpha: xMeasurementLine1Opacity.clamp(0.0, 1.0));
    final color2 = (xMeasurementLine2Color ?? _palette.measurementSecondary)
        .withValues(alpha: xMeasurementLine2Opacity.clamp(0.0, 1.0));
    final line1Paint =
        Paint()
          ..color = color1
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
    final line2Paint =
        Paint()
          ..color = color2
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;

    // 第一条线
    if (x1 != null) {
      final sx1 = viewport.dataToScreenX(x1, size.width);
      if (sx1 >= viewport.marginLeft &&
          sx1 <= size.width - viewport.marginRight) {
        canvas.drawLine(
          Offset(sx1, PlotViewport().marginTop),
          Offset(sx1, PlotViewport().marginTop + plotH),
          line1Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'X${groupIndex * 2 + 1}',
          sx1,
          PlotViewport().marginTop + 12,
          color1,
        );
      }
    }

    // 第二条线
    if (x2 != null) {
      final sx2 = viewport.dataToScreenX(x2, size.width);
      if (sx2 >= viewport.marginLeft &&
          sx2 <= size.width - viewport.marginRight) {
        canvas.drawLine(
          Offset(sx2, PlotViewport().marginTop),
          Offset(sx2, PlotViewport().marginTop + plotH),
          line2Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'X${groupIndex * 2 + 2}',
          sx2,
          PlotViewport().marginTop + 12,
          color2,
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
    int groupIndex,
  ) {
    if (y1 == null && y2 == null) return;

    final color1 = (yMeasurementLine1Color ?? _palette.measurementPrimary)
        .withValues(alpha: yMeasurementLine1Opacity.clamp(0.0, 1.0));
    final color2 = (yMeasurementLine2Color ?? _palette.measurementSecondary)
        .withValues(alpha: yMeasurementLine2Opacity.clamp(0.0, 1.0));
    final line1Paint =
        Paint()
          ..color = color1
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
    final line2Paint =
        Paint()
          ..color = color2
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;

    // 第一条线
    if (y1 != null) {
      final sy1 = viewport.dataToScreenY(y1, size.height);
      if (sy1 >= PlotViewport().marginTop &&
          sy1 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(viewport.marginLeft, sy1),
          Offset(viewport.marginLeft + plotW, sy1),
          line1Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'Y${groupIndex * 2 + 1}',
          viewport.marginLeft - 18,
          sy1,
          color1,
        );
      }
    }

    // 第二条线
    if (y2 != null) {
      final sy2 = viewport.dataToScreenY(y2, size.height);
      if (sy2 >= PlotViewport().marginTop &&
          sy2 <= size.height - PlotViewport().marginBottom) {
        canvas.drawLine(
          Offset(viewport.marginLeft, sy2),
          Offset(viewport.marginLeft + plotW, sy2),
          line2Paint,
        );
        _drawMeasurementLabel(
          canvas,
          'Y${groupIndex * 2 + 2}',
          viewport.marginLeft - 18,
          sy2,
          color2,
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
      fontSize: _fontSize(10),
      fontWeight: FontWeight.bold,
      fontFamily: 'SarasaUiSC',
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
        ..color = _palette.tooltipBackground.withValues(
          alpha: floatingPanelOpacity,
        )
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
        .clamp(viewport.marginLeft, size.width - viewport.marginRight);
    final sx2 = viewport
        .dataToScreenX(statsX2!, size.width)
        .clamp(viewport.marginLeft, size.width - viewport.marginRight);

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

  /// 绘制虚线（7px 实线 + 5px 间隙）
  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    const dashLength = 7.0;
    const gapLength = 5.0;
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

  void _drawDashedPolyline(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.length < 2) return;
    const dashLength = 7.0;
    const gapLength = 5.0;
    const patternLength = dashLength + gapLength;
    var patternOffset = 0.0;

    for (int i = 1; i < points.length; i++) {
      final start = points[i - 1];
      final end = points[i];
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final segmentLength = math.sqrt(dx * dx + dy * dy);
      if (segmentLength <= 0) continue;

      var consumed = 0.0;
      while (consumed < segmentLength) {
        final inDash = patternOffset < dashLength;
        final remainInPattern =
            (inDash ? dashLength : patternLength) - patternOffset;
        final step = math.min(remainInPattern, segmentLength - consumed);

        if (inDash) {
          final t1 = consumed / segmentLength;
          final t2 = (consumed + step) / segmentLength;
          canvas.drawLine(
            Offset(start.dx + dx * t1, start.dy + dy * t1),
            Offset(start.dx + dx * t2, start.dy + dy * t2),
            paint,
          );
        }

        consumed += step;
        patternOffset = (patternOffset + step) % patternLength;
      }
    }
  }

  /// 判断是否需要重绘
  ///
  /// 比较视口、数据长度、光标、网格、统计范围等关键属性。
  @override
  bool shouldRepaint(covariant PlotLayerPainter oldDelegate) {
    if (oldDelegate.layer != layer) return true;
    final viewportChanged = !_viewportEquals(oldDelegate.viewport, viewport);
    final dataChanged = oldDelegate.data.length != data.length;
    final dataRevisionChanged = oldDelegate.dataRevision != dataRevision;
    return switch (layer) {
      PlotPaintLayer.background =>
        viewportChanged ||
            oldDelegate.viewportRevision != viewportRevision ||
            oldDelegate.showGrid != showGrid ||
            oldDelegate.gridDensity != gridDensity ||
            oldDelegate.backgroundStyle != backgroundStyle ||
            oldDelegate.antiAliasEnabled != antiAliasEnabled,
      PlotPaintLayer.data =>
        viewportChanged ||
            dataChanged ||
            dataRevisionChanged ||
            oldDelegate.viewportRevision != viewportRevision ||
            oldDelegate.channelConfigRevision != channelConfigRevision ||
            oldDelegate.lodIndex != lodIndex ||
            oldDelegate.lodQuality != lodQuality ||
            oldDelegate.interactionActive != interactionActive ||
            oldDelegate.devicePixelRatio != devicePixelRatio ||
            oldDelegate.activeChannelCount != activeChannelCount ||
            oldDelegate.backgroundStyle != backgroundStyle ||
            oldDelegate.antiAliasEnabled != antiAliasEnabled ||
            oldDelegate.externalDataClip != externalDataClip ||
            oldDelegate.dataQueryPadding != dataQueryPadding,
      PlotPaintLayer.axis =>
        viewportChanged ||
            oldDelegate.viewportRevision != viewportRevision ||
            oldDelegate.channelConfigRevision != channelConfigRevision ||
            oldDelegate.activeChannelCount != activeChannelCount ||
            oldDelegate.gridDensity != gridDensity ||
            oldDelegate.backgroundStyle != backgroundStyle ||
            oldDelegate.yValuesAreInteger != yValuesAreInteger ||
            oldDelegate.plotFontSizeDelta != plotFontSizeDelta ||
            oldDelegate.plotFontBold != plotFontBold,
      PlotPaintLayer.overlay =>
        viewportChanged ||
            oldDelegate.viewportRevision != viewportRevision ||
            oldDelegate.overlayRevision != overlayRevision ||
            oldDelegate.channelConfigRevision != channelConfigRevision ||
            oldDelegate.backgroundStyle != backgroundStyle ||
            oldDelegate.floatingPanelOpacity != floatingPanelOpacity ||
            oldDelegate.xMeasurementLine1Color != xMeasurementLine1Color ||
            oldDelegate.xMeasurementLine2Color != xMeasurementLine2Color ||
            oldDelegate.yMeasurementLine1Color != yMeasurementLine1Color ||
            oldDelegate.yMeasurementLine2Color != yMeasurementLine2Color ||
            oldDelegate.xMeasurementLine1Opacity != xMeasurementLine1Opacity ||
            oldDelegate.xMeasurementLine2Opacity != xMeasurementLine2Opacity ||
            oldDelegate.yMeasurementLine1Opacity != yMeasurementLine1Opacity ||
            oldDelegate.yMeasurementLine2Opacity != yMeasurementLine2Opacity ||
            oldDelegate.plotFontSizeDelta != plotFontSizeDelta ||
            oldDelegate.plotFontBold != plotFontBold,
    };
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

class _CursorValueRow {
  final int index;
  final String name;
  final String value;

  const _CursorValueRow({
    required this.index,
    required this.name,
    required this.value,
  });
}
