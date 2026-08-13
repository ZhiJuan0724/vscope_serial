import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../core/constants/plot_configuration.dart';
import '../core/utils/app_logger.dart';
import '../data/models/plot_data.dart';

/// 精确绘图窗口的唯一状态与异步任务所有者。
///
/// 全量历史由外部提供只读 [valuesAt]；本类只物化有界窗口，并负责预取、
/// generation 取消和定位条拖动防抖。提交与加载状态通过窄回调通知门面。
class PlotWindowProvider {
  PlotWindowProvider({
    required bool Function() isDisposed,
    required void Function() onStateChanged,
    required void Function() onCommitted,
  }) : _isDisposed = isDisposed,
       _onStateChanged = onStateChanged,
       _onCommitted = onCommitted;

  final List<PlotDataPoint> _points = <PlotDataPoint>[];

  final bool Function() _isDisposed;
  final void Function() _onStateChanged;
  final void Function() _onCommitted;
  late final UnmodifiableListView<PlotDataPoint> points =
      UnmodifiableListView<PlotDataPoint>(_points);

  int _visibleStartIndex = 0;
  bool _isLoading = false;
  int _generation = 0;
  int _pendingPointCount = 0;
  int? _pendingStartIndex;
  int? _pendingEndIndex;
  bool _tracksLiveEdge = true;
  bool _pendingTracksLiveEdge = false;
  final List<PlotDataPoint> _pendingLivePoints = <PlotDataPoint>[];
  Timer? _dragLoadTimer;

  int get visibleStartIndex => _visibleStartIndex;
  int get visibleEndIndex => _visibleStartIndex + _points.length;
  bool get isLoading => _isLoading;
  int get pendingPointCount => _pendingPointCount;
  bool get hasLiveEdgeTarget =>
      _tracksLiveEdge || (_isLoading && _pendingTracksLiveEdge);

  void clear() {
    cancelLoad();
    _points.clear();
    _visibleStartIndex = 0;
    _tracksLiveEdge = true;
  }

  /// 将实时增量追加到当前尾部窗口，并同步保留给正在构建的尾部窗口。
  ///
  /// 历史窗口不接收实时点；异步尾部窗口完成时会把加载期间到达的点合并
  /// 进去，避免旧快照覆盖实时增量后被误判为历史窗口。
  bool appendLive(PlotDataPoint point) {
    var visibleChanged = false;
    if (_tracksLiveEdge &&
        (_points.isEmpty || visibleEndIndex == point.index)) {
      _points.add(point);
      visibleChanged = true;
    }

    if (_isLoading && _pendingTracksLiveEdge) {
      final expectedIndex =
          (_pendingEndIndex ?? point.index) + _pendingLivePoints.length;
      if (point.index == expectedIndex) {
        _pendingLivePoints.add(point);
      }
    }
    return visibleChanged;
  }

  void trimToLimit({required int limit, required int trimBatchSize}) {
    if (_points.length <= limit) {
      _visibleStartIndex = _points.isEmpty ? 0 : _points.first.index;
      return;
    }
    final removeCount = math.min(trimBatchSize, _points.length);
    _points.removeRange(0, removeCount);
    _visibleStartIndex = _points.first.index;
  }

  void loadViewport({
    required double xMin,
    required double xMax,
    required int total,
    required int materializedPointLimit,
    required int allocatedBytes,
    required int retentionLimitBytes,
    required List<double> Function(int pointIndex) valuesAt,
    bool force = false,
  }) {
    if (total <= 0) return;
    final requestedStart = xMin.floor().clamp(0, total).toInt();
    final requestedEnd = xMax.floor().toInt().clamp(0, total - 1) + 1;
    // 命中预取窗口时不重建；短距离拖动只交换视口，避免重复物化同一批点。
    final tracksLiveEdge = requestedEnd >= total;
    if (!force &&
        _hasPrefetchedRange(
          requestedStart: requestedStart,
          requestedEnd: requestedEnd,
          total: total,
          materializedPointLimit: materializedPointLimit,
        )) {
      if (tracksLiveEdge && visibleEndIndex == total) {
        _tracksLiveEdge = true;
      }
      return;
    }
    final (start, end) = _materializedWindowForRange(
      requestedStart,
      requestedEnd,
      total,
      materializedPointLimit,
    );
    rebuild(
      start: start,
      count: end - start,
      allocatedBytes: allocatedBytes,
      retentionLimitBytes: retentionLimitBytes,
      valuesAt: valuesAt,
      tracksLiveEdge: tracksLiveEdge,
      pointLimit: materializedPointLimit,
    );
  }

  void loadTail({
    required int total,
    required int materializedPointLimit,
    required int allocatedBytes,
    required int retentionLimitBytes,
    required List<double> Function(int pointIndex) valuesAt,
  }) {
    if (total <= 0) return;
    final count = total.clamp(0, materializedPointLimit).toInt();
    rebuild(
      start: total - count,
      count: count,
      allocatedBytes: allocatedBytes,
      retentionLimitBytes: retentionLimitBytes,
      valuesAt: valuesAt,
      tracksLiveEdge: true,
      pointLimit: materializedPointLimit,
    );
  }

  void rebuild({
    required int start,
    required int count,
    required int allocatedBytes,
    required int retentionLimitBytes,
    required List<double> Function(int pointIndex) valuesAt,
    bool tracksLiveEdge = false,
    int? pointLimit,
  }) {
    final effectivePointLimit = pointLimit ?? count;
    if (count <= 4096) {
      cancelLoad();
      _commit(start, <PlotDataPoint>[
        for (var offset = 0; offset < count; offset++)
          PlotDataPoint(
            index: start + offset,
            timestamp: (start + offset).toDouble(),
            values: valuesAt(start + offset),
          ),
      ], tracksLiveEdge: tracksLiveEdge);
      return;
    }

    if (allocatedBytes + count * 192 > retentionLimitBytes) {
      cancelLoad();
      AppLogger().warning(
        '精确窗口预计超过绘图预算，保持 LOD 显示：start=$start, count=$count',
        category: 'PLOT',
      );
      return;
    }

    // 每次重建递增 generation，异步分块完成时只允许最新请求提交结果。
    final generation = ++_generation;
    _isLoading = true;
    _pendingPointCount = count;
    _pendingStartIndex = start;
    _pendingEndIndex = start + count;
    _pendingTracksLiveEdge = tracksLiveEdge;
    _pendingLivePoints.clear();
    _onStateChanged();
    unawaited(
      _buildChunked(
        generation,
        start,
        count,
        valuesAt,
        tracksLiveEdge: tracksLiveEdge,
        pointLimit: effectivePointLimit,
      ),
    );
  }

  Future<void> _buildChunked(
    int generation,
    int start,
    int count,
    List<double> Function(int pointIndex) valuesAt, {
    required bool tracksLiveEdge,
    required int pointLimit,
  }) async {
    try {
      final next = <PlotDataPoint>[];
      for (var offset = 0; offset < count; offset++) {
        if (_isDisposed() || generation != _generation) return;
        final pointIndex = start + offset;
        next.add(
          PlotDataPoint(
            index: pointIndex,
            timestamp: pointIndex.toDouble(),
            values: valuesAt(pointIndex),
          ),
        );
        // 定期让出 UI，长窗口加载不能阻塞输入和定位条拖动。
        if ((offset + 1) % 4096 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (_isDisposed() || generation != _generation) return;
      if (tracksLiveEdge && _pendingLivePoints.isNotEmpty) {
        next.addAll(_pendingLivePoints);
      }
      var committedStart = start;
      if (next.length > pointLimit) {
        final removeCount = next.length - pointLimit;
        next.removeRange(0, removeCount);
        committedStart = next.first.index;
      }
      _commit(committedStart, next, tracksLiveEdge: tracksLiveEdge);
    } catch (error, stackTrace) {
      AppLogger().error('精确窗口加载失败: $error\n$stackTrace', category: 'PLOT');
    } finally {
      if (!_isDisposed() && generation == _generation) {
        _isLoading = false;
        _pendingPointCount = 0;
        _pendingStartIndex = null;
        _pendingEndIndex = null;
        _pendingTracksLiveEdge = false;
        _pendingLivePoints.clear();
        _onStateChanged();
      }
    }
  }

  void replaceSynchronously(
    int start,
    Iterable<PlotDataPoint> next, {
    bool tracksLiveEdge = false,
  }) {
    cancelLoad();
    _commit(start, next, tracksLiveEdge: tracksLiveEdge);
  }

  void scheduleDragLoad(void Function() load) {
    // 连续拖动只在用户停顿后加载精确窗口，期间由有界 LOD 维持预览。
    _dragLoadTimer?.cancel();
    _dragLoadTimer = Timer(PlotConfiguration.locatorDragWindowLoadDebounce, () {
      _dragLoadTimer = null;
      if (!_isDisposed()) load();
    });
  }

  void cancelDragLoad() {
    _dragLoadTimer?.cancel();
    _dragLoadTimer = null;
  }

  void cancelLoad() {
    // 递增 generation 即可使已在运行的分块任务自然失效，无需强行中断遍历。
    cancelDragLoad();
    _generation++;
    _isLoading = false;
    _pendingPointCount = 0;
    _pendingStartIndex = null;
    _pendingEndIndex = null;
    _pendingTracksLiveEdge = false;
    _pendingLivePoints.clear();
  }

  void dispose() {
    cancelLoad();
  }

  void _commit(
    int start,
    Iterable<PlotDataPoint> next, {
    required bool tracksLiveEdge,
  }) {
    _points
      ..clear()
      ..addAll(next);
    _visibleStartIndex = start;
    _tracksLiveEdge = tracksLiveEdge;
    _pendingStartIndex = null;
    _pendingEndIndex = null;
    _onCommitted();
  }

  (int, int) _materializedWindowForRange(
    int start,
    int end,
    int total,
    int pointLimit,
  ) {
    if (total <= 0) return (0, 0);
    final requestedStart = start.clamp(0, total);
    final requestedEnd = end.clamp(requestedStart, total);
    final count = math.min(total, pointLimit);
    final center = requestedStart + (requestedEnd - requestedStart) ~/ 2;
    var materializedStart = center - count ~/ 2;
    materializedStart = materializedStart.clamp(0, total - count);
    return (materializedStart, materializedStart + count);
  }

  bool _windowKeepsRangePrefetched({
    required int windowStart,
    required int windowEnd,
    required int requestedStart,
    required int requestedEnd,
    required int total,
  }) {
    if (requestedStart < windowStart || requestedEnd > windowEnd) return false;
    final windowLength = windowEnd - windowStart;
    final requestedLength = requestedEnd - requestedStart;
    final spare = windowLength - requestedLength;
    if (spare <= 0) return true;
    final desiredMargin =
        (windowLength * PlotConfiguration.materializedWindowReloadMarginRatio)
            .round();
    final margin = math.min(desiredMargin, spare ~/ 2);
    final safeStart = windowStart == 0 ? windowStart : windowStart + margin;
    final safeEnd = windowEnd == total ? windowEnd : windowEnd - margin;
    return requestedStart >= safeStart && requestedEnd <= safeEnd;
  }

  bool _hasPrefetchedRange({
    required int requestedStart,
    required int requestedEnd,
    required int total,
    required int materializedPointLimit,
  }) {
    if (requestedEnd - requestedStart >= materializedPointLimit) {
      final (targetStart, targetEnd) = _materializedWindowForRange(
        requestedStart,
        requestedEnd,
        total,
        materializedPointLimit,
      );
      final currentMatches =
          _visibleStartIndex == targetStart && visibleEndIndex == targetEnd;
      final pendingMatches =
          _isLoading &&
          _pendingStartIndex == targetStart &&
          _pendingEndIndex == targetEnd;
      if (currentMatches && _isLoading && !pendingMatches) cancelLoad();
      return currentMatches || pendingMatches;
    }

    final currentKeepsRange = _windowKeepsRangePrefetched(
      windowStart: _visibleStartIndex,
      windowEnd: visibleEndIndex,
      requestedStart: requestedStart,
      requestedEnd: requestedEnd,
      total: total,
    );
    final pendingStart = _pendingStartIndex;
    final pendingEnd = _pendingEndIndex;
    final pendingKeepsRange =
        _isLoading &&
        pendingStart != null &&
        pendingEnd != null &&
        _windowKeepsRangePrefetched(
          windowStart: pendingStart,
          windowEnd: pendingEnd,
          requestedStart: requestedStart,
          requestedEnd: requestedEnd,
          total: total,
        );
    if (currentKeepsRange && _isLoading && !pendingKeepsRange) cancelLoad();
    return currentKeepsRange || pendingKeepsRange;
  }
}
