import 'dart:math' as math;
import 'dart:typed_data';

import 'plot_data.dart';
import 'plot_lod_index.dart';

/// 视口查询生成的单通道几何。
///
/// [indices] 与 [values] 始终按原始采样序号递增；[runOffsets] 用于隔离
/// 缺失数据或不连续摘要，渲染器不得跨 run 连接。
class PlotGeometryBatch {
  const PlotGeometryBatch({
    required this.indices,
    required this.values,
    required this.runOffsets,
    required this.isRaw,
  }) : assert(indices.length == values.length),
       assert(runOffsets.length >= 2);

  final Int32List indices;
  final Float64List values;
  final Int32List runOffsets;
  final bool isRaw;

  int get length => indices.length;
  int get runCount => runOffsets.length - 1;
  bool get isEmpty => indices.isEmpty;
}

/// 跨帧复用的视口查询工作区。
///
/// 查询结果会在下一次调用 [PlotViewportQuery.queryChannel] 时被覆盖，因此
/// 调用方必须在查询下一个通道前完成当前批次的绘制。
class PlotGeometryWorkspace {
  Int32List _indices = Int32List(0);
  Float64List _values = Float64List(0);
  Int32List _runOffsets = Int32List(0);

  Int32List ensureIndices(int length) {
    if (_indices.length < length) _indices = Int32List(_capacity(length));
    return _indices;
  }

  Float64List ensureValues(int length) {
    if (_values.length < length) _values = Float64List(_capacity(length));
    return _values;
  }

  Int32List ensureRunOffsets(int length) {
    if (_runOffsets.length < length) {
      _runOffsets = Int32List(_capacity(length));
    }
    return _runOffsets;
  }

  int _capacity(int required) {
    var result = 256;
    while (result < required) {
      result *= 2;
    }
    return result;
  }
}

/// 将精确窗口或分层摘要转换成屏幕像素级时序几何。
///
/// 低密度视口直接返回原始采样；高密度视口按物理像素列选取
/// first/min/max/last，并按真实采样序号连接。性能档最多合并相邻两个
/// 物理像素，不允许简单抽点或生成跨桶的虚假趋势线。
abstract final class PlotViewportQuery {
  static PlotGeometryBatch? queryChannel({
    required List<PlotDataPoint> exactData,
    required PlotLodSource? rangeIndex,
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double logicalPlotWidth,
    required double devicePixelRatio,
    required PlotLodQuality quality,
    required PlotGeometryWorkspace workspace,
  }) {
    if (channelIndex < 0 ||
        xMax <= xMin ||
        logicalPlotWidth <= 0 ||
        devicePixelRatio <= 0) {
      return null;
    }

    final physicalWidth = math.max(
      1,
      (logicalPlotWidth * devicePixelRatio).round(),
    );
    final exactRange = _visibleExactRange(exactData, xMin, xMax);
    final exactCoversViewport =
        exactRange != null &&
        exactData[exactRange.$1].index <= xMin.ceil() &&
        exactData[exactRange.$2 - 1].index >= xMax.floor();
    final visiblePointCount = math.max(0, xMax.floor() - xMin.ceil() + 1);
    final rawLimit = physicalWidth * quality.rawPointsPerPhysicalPixel;

    if (exactCoversViewport && visiblePointCount <= rawLimit) {
      return _buildRaw(exactData, exactRange, channelIndex, workspace);
    }

    if (exactCoversViewport && rangeIndex == null) {
      return _buildM4FromExact(
        exactData: exactData,
        range: exactRange,
        channelIndex: channelIndex,
        xMin: xMin,
        xMax: xMax,
        physicalWidth: physicalWidth,
        quality: quality,
        workspace: workspace,
      );
    }

    final columnSpan = quality.physicalPixelsPerM4Column;
    final maxBucketSize = math.max(
      PlotLodIndex.minBucketSize,
      (((xMax - xMin) / physicalWidth) * columnSpan).floor(),
    );
    final candidates = rangeIndex?.queryForPixelColumns(
      channelIndex: channelIndex,
      xMin: xMin,
      xMax: xMax,
      maxBucketSize: maxBucketSize,
      useViewportCache: true,
    );
    if (candidates == null || candidates.isEmpty) {
      if (exactCoversViewport) {
        return _buildM4FromExact(
          exactData: exactData,
          range: exactRange,
          channelIndex: channelIndex,
          xMin: xMin,
          xMax: xMax,
          physicalWidth: physicalWidth,
          quality: quality,
          workspace: workspace,
        );
      }
      return null;
    }
    return _buildM4FromCandidates(
      candidates: candidates,
      xMin: xMin,
      xMax: xMax,
      physicalWidth: physicalWidth,
      quality: quality,
      workspace: workspace,
    );
  }

  static (int, int)? _visibleExactRange(
    List<PlotDataPoint> data,
    double xMin,
    double xMax,
  ) {
    if (data.isEmpty) return null;
    var low = 0;
    var high = data.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (data[mid].index < xMin) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final start = low;
    high = data.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (data[mid].index <= xMax) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return start < low ? (start, low) : null;
  }

  static PlotGeometryBatch? _buildRaw(
    List<PlotDataPoint> data,
    (int, int)? range,
    int channelIndex,
    PlotGeometryWorkspace workspace,
  ) {
    if (range == null) return null;
    final capacity = range.$2 - range.$1;
    final indices = workspace.ensureIndices(capacity);
    final values = workspace.ensureValues(capacity);
    final runs = workspace.ensureRunOffsets(capacity + 1);
    var out = 0;
    var runCount = 0;
    var inRun = false;
    var previousIndex = -2;
    for (var i = range.$1; i < range.$2; i++) {
      final point = data[i];
      final valid =
          channelIndex < point.values.length &&
          point.values[channelIndex].isFinite;
      if (!valid || point.index <= previousIndex) {
        inRun = false;
        continue;
      }
      if (!inRun || point.index != previousIndex + 1) {
        runs[runCount++] = out;
        inRun = true;
      }
      indices[out] = point.index;
      values[out] = point.values[channelIndex];
      previousIndex = point.index;
      out++;
    }
    if (out == 0) return null;
    runs[runCount] = out;
    return PlotGeometryBatch(
      indices: Int32List.sublistView(indices, 0, out),
      values: Float64List.sublistView(values, 0, out),
      runOffsets: Int32List.sublistView(runs, 0, runCount + 1),
      isRaw: true,
    );
  }

  static PlotGeometryBatch? _buildM4FromExact({
    required List<PlotDataPoint> exactData,
    required (int, int)? range,
    required int channelIndex,
    required double xMin,
    required double xMax,
    required int physicalWidth,
    required PlotLodQuality quality,
    required PlotGeometryWorkspace workspace,
  }) {
    if (range == null) return null;
    return _buildM4(
      sampleCount: range.$2 - range.$1,
      sampleAt: (position) {
        final point = exactData[range.$1 + position];
        if (channelIndex >= point.values.length) return null;
        final value = point.values[channelIndex];
        return value.isFinite ? (point.index, value) : null;
      },
      xMin: xMin,
      xMax: xMax,
      physicalWidth: physicalWidth,
      quality: quality,
      workspace: workspace,
    );
  }

  static PlotGeometryBatch? _buildM4FromCandidates({
    required PlotLodSeries candidates,
    required double xMin,
    required double xMax,
    required int physicalWidth,
    required PlotLodQuality quality,
    required PlotGeometryWorkspace workspace,
  }) => _buildM4(
    sampleCount: candidates.length,
    sampleAt: (position) {
      final index = candidates.indices[position];
      final value = candidates.values[position];
      return value.isFinite ? (index, value) : null;
    },
    xMin: xMin,
    xMax: xMax,
    physicalWidth: physicalWidth,
    quality: quality,
    workspace: workspace,
  );

  static PlotGeometryBatch? _buildM4({
    required int sampleCount,
    required (int, double)? Function(int position) sampleAt,
    required double xMin,
    required double xMax,
    required int physicalWidth,
    required PlotLodQuality quality,
    required PlotGeometryWorkspace workspace,
  }) {
    final columnSpan = quality.physicalPixelsPerM4Column;
    final columnCount = math.max(1, (physicalWidth / columnSpan).ceil());
    final maxPoints = columnCount * 4;
    final indices = workspace.ensureIndices(maxPoints);
    final values = workspace.ensureValues(maxPoints);
    final runs = workspace.ensureRunOffsets(columnCount + 1);
    final xRange = xMax - xMin;
    var out = 0;
    var runCount = 1;
    var activeColumn = -1;
    var firstIndex = 0;
    var lastIndex = 0;
    var minIndex = 0;
    var maxIndex = 0;
    var firstValue = 0.0;
    var lastValue = 0.0;
    var minValue = 0.0;
    var maxValue = 0.0;

    void flushColumn() {
      if (activeColumn < 0) return;
      // 分层摘要只包含每个基础块的候选点，候选像素列之间的空白不代表
      // 原始数据中断。它们必须保持同一时序 run，否则小视口会退化成
      // 大量无法绘制的单点片段。真实 NaN/缺帧只由精确原始路径断开。
      var emittedIndex = -1;

      void emit(int index, double value) {
        if (index == emittedIndex) return;
        indices[out] = index;
        values[out] = value;
        emittedIndex = index;
        out++;
      }

      emit(firstIndex, firstValue);
      if (minIndex <= maxIndex) {
        emit(minIndex, minValue);
        emit(maxIndex, maxValue);
      } else {
        emit(maxIndex, maxValue);
        emit(minIndex, minValue);
      }
      emit(lastIndex, lastValue);
    }

    runs[0] = 0;

    for (var position = 0; position < sampleCount; position++) {
      final sample = sampleAt(position);
      if (sample == null || sample.$1 < xMin || sample.$1 > xMax) continue;
      final normalized = (sample.$1 - xMin) / xRange;
      final column = (normalized * columnCount).floor().clamp(
        0,
        columnCount - 1,
      );
      if (column != activeColumn) {
        flushColumn();
        activeColumn = column;
        firstIndex = sample.$1;
        lastIndex = sample.$1;
        minIndex = sample.$1;
        maxIndex = sample.$1;
        firstValue = sample.$2;
        lastValue = sample.$2;
        minValue = sample.$2;
        maxValue = sample.$2;
        continue;
      }
      lastIndex = sample.$1;
      lastValue = sample.$2;
      if (sample.$2 < minValue) {
        minValue = sample.$2;
        minIndex = sample.$1;
      }
      if (sample.$2 > maxValue) {
        maxValue = sample.$2;
        maxIndex = sample.$1;
      }
    }
    flushColumn();
    if (out == 0) return null;
    runs[runCount] = out;
    return PlotGeometryBatch(
      indices: Int32List.sublistView(indices, 0, out),
      values: Float64List.sublistView(values, 0, out),
      runOffsets: Int32List.sublistView(runs, 0, runCount + 1),
      isRaw: false,
    );
  }
}
