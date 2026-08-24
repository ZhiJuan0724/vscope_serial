import 'package:flutter/material.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/plot_data.dart';
import '../../data/models/plot_lod_index.dart';
import '../../data/models/plot_render_engine.dart';
import 'plot_viewport.dart';

/// 垂直光标状态（鼠标悬停跟随）。
class CursorState {
  final double x;
  final double? y;
  final Offset? screenPosition;
  final List<double>? channelValues;
  final bool hasData;

  CursorState({
    required this.x,
    this.y,
    this.screenPosition,
    this.channelValues,
    this.hasData = true,
  });
}

class PlotObservation {
  final CursorState cursor;
  final String note;
  final bool locked;

  const PlotObservation({
    required this.cursor,
    this.note = '',
    this.locked = false,
  });

  double get x => cursor.x;
  double? get y => cursor.y;
  Offset? get screenPosition => cursor.screenPosition;
  List<double>? get channelValues => cursor.channelValues;
  bool get hasData => cursor.hasData;

  PlotObservation copyWith({CursorState? cursor, String? note, bool? locked}) {
    return PlotObservation(
      cursor: cursor ?? this.cursor,
      note: note ?? this.note,
      locked: locked ?? this.locked,
    );
  }
}

class SnapHighlightPoint {
  final double x;
  final double y;
  final Color color;

  const SnapHighlightPoint({
    required this.x,
    required this.y,
    required this.color,
  });
}

/// 一组 Delta X 或 Delta Y 测量线。
class PlotMeasurementGroup {
  final double cursor1;
  final double cursor2;

  const PlotMeasurementGroup({required this.cursor1, required this.cursor2});

  PlotMeasurementGroup copyWith({double? cursor1, double? cursor2}) {
    return PlotMeasurementGroup(
      cursor1: cursor1 ?? this.cursor1,
      cursor2: cursor2 ?? this.cursor2,
    );
  }
}

enum GridDensity { sparse, normal, dense }

enum PlotBackgroundStyle { dark, light }

enum PlotPaintLayer { background, data, axis, overlay }

/// 一次绘制提交所需的完整不可变输入描述。
///
/// 数据窗口和 LOD 本身由各自只读接口提供，revision 明确标识其内容版本；
/// Painter 不再在构造时零散读取 ViewModel 状态。
class PlotRenderSnapshot {
  PlotRenderSnapshot({
    required this.viewport,
    required this.data,
    required this.channels,
    this.dataRevision = 0,
    this.channelConfigRevision = 0,
    this.viewportRevision = 0,
    this.overlayRevision = 0,
    this.lodIndex,
    this.lodQuality = PlotLodQuality.performance,
    this.renderEngine = PlotRenderEngine.canvas,
    this.interactionActive = false,
    this.devicePixelRatio = 1,
    int? activeChannelCount,
    this.showGrid = true,
    this.gridDensity = GridDensity.normal,
    this.backgroundStyle = PlotBackgroundStyle.dark,
    this.floatingPanelOpacity = 0.85,
    this.cursor,
    this.xCursor1,
    this.xCursor2,
    this.yCursor1,
    this.yCursor2,
    this.xMeasurementGroups = const [],
    this.yMeasurementGroups = const [],
    this.xMeasurementLine1Color,
    this.xMeasurementLine2Color,
    this.yMeasurementLine1Color,
    this.yMeasurementLine2Color,
    this.xMeasurementLine1Opacity = 1,
    this.xMeasurementLine2Opacity = 1,
    this.yMeasurementLine1Opacity = 1,
    this.yMeasurementLine2Opacity = 1,
    this.statsEnabled = false,
    this.statsRangeEnabled = false,
    this.statsX1,
    this.statsX2,
    this.snapHighlights = const [],
    this.snapHighlightEnabled = true,
    this.snapHighlightDiameter = 8,
    this.antiAliasEnabled = true,
    this.yValuesAreInteger = false,
    this.plotFontSizeDelta = 0,
    this.plotFontBold = false,
  }) : activeChannelCount = (activeChannelCount ?? channels.length).clamp(
         0,
         channels.length,
       );

  final PlotViewport viewport;
  final List<PlotDataPoint> data;
  final int dataRevision;
  final int channelConfigRevision;
  final int viewportRevision;
  final int overlayRevision;
  final PlotLodSource? lodIndex;
  final PlotLodQuality lodQuality;
  final PlotRenderEngine renderEngine;

  /// 当前绘图区的设备像素比；屏幕级 M4 必须按物理像素而非逻辑像素分桶。
  final double devicePixelRatio;

  /// 视口正在连续平移或拖动缩放；绘制层使用有界预览，松手后恢复最终质量。
  final bool interactionActive;
  final List<ChannelConfig> channels;
  final int activeChannelCount;
  final bool showGrid;
  final GridDensity gridDensity;
  final PlotBackgroundStyle backgroundStyle;
  final double floatingPanelOpacity;
  final CursorState? cursor;
  final double? xCursor1;
  final double? xCursor2;
  final double? yCursor1;
  final double? yCursor2;
  final List<PlotMeasurementGroup> xMeasurementGroups;
  final List<PlotMeasurementGroup> yMeasurementGroups;
  final Color? xMeasurementLine1Color;
  final Color? xMeasurementLine2Color;
  final Color? yMeasurementLine1Color;
  final Color? yMeasurementLine2Color;
  final double xMeasurementLine1Opacity;
  final double xMeasurementLine2Opacity;
  final double yMeasurementLine1Opacity;
  final double yMeasurementLine2Opacity;
  final bool statsEnabled;
  final bool statsRangeEnabled;
  final double? statsX1;
  final double? statsX2;
  final List<SnapHighlightPoint> snapHighlights;
  final bool snapHighlightEnabled;
  final double snapHighlightDiameter;
  final bool antiAliasEnabled;
  final bool yValuesAreInteger;
  final int plotFontSizeDelta;
  final bool plotFontBold;

  PlotRenderSnapshot copyWith({
    PlotViewport? viewport,
    bool? interactionActive,
    PlotRenderEngine? renderEngine,
  }) => PlotRenderSnapshot(
    viewport: viewport ?? this.viewport,
    data: data,
    channels: channels,
    dataRevision: dataRevision,
    channelConfigRevision: channelConfigRevision,
    viewportRevision: viewportRevision,
    overlayRevision: overlayRevision,
    lodIndex: lodIndex,
    lodQuality: lodQuality,
    renderEngine: renderEngine ?? this.renderEngine,
    interactionActive: interactionActive ?? this.interactionActive,
    devicePixelRatio: devicePixelRatio,
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
    xMeasurementGroups: xMeasurementGroups,
    yMeasurementGroups: yMeasurementGroups,
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
}
