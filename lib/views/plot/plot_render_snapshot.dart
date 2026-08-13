import 'package:flutter/material.dart';

import '../../data/models/channel_config.dart';
import '../../data/models/plot_data.dart';
import '../../data/models/plot_lod_index.dart';
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
}
