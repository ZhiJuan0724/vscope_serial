import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/constants/plot_configuration.dart';
import '../../core/utils/plot_performance_metrics.dart';

/// 主绘图区使用 LOD 历史时的质量策略。
enum PlotLodQuality {
  /// 性能优先：每个物理像素最多直接绘制一个原始点；高密度时允许把
  /// 相邻两个物理像素列合并为一个 M4 列。
  ///
  /// 只降低屏幕级摘要密度，不允许改变真实时序、丢失显著峰谷或跨段连线。
  performance,

  /// 均衡：每个物理像素最多直接绘制两个原始点；高密度时按每个物理
  /// 像素列生成一个 M4 列。
  ///
  /// 这是默认档位，在完整走势还原与几何数量之间折中。
  balanced,

  /// 质量优先：每个物理像素最多直接绘制四个原始点；高密度时与均衡
  /// 一样按每个物理像素列生成一个 M4 列。
  ///
  /// 因而它主要在放大到中低密度时比均衡档更早恢复完整原始折线；在
  /// 高密度 M4 场景中二者可能得到相同几何。
  quality,
}

/// 三档绘图质量唯一的几何密度策略。
///
/// 分层 LOD 只负责加速候选查询；最终图形始终由视口查询器按这里定义的
/// 物理像素密度生成，渲染后端不得再次解释质量档位。
extension PlotLodQualityPolicy on PlotLodQuality {
  int get rawPointsPerPhysicalPixel => switch (this) {
    PlotLodQuality.performance => 1,
    PlotLodQuality.balanced => 2,
    PlotLodQuality.quality => 4,
  };

  int get physicalPixelsPerM4Column => switch (this) {
    PlotLodQuality.performance => 2,
    PlotLodQuality.balanced || PlotLodQuality.quality => 1,
  };

  /// 旧式固定桶查询仍供自动 Y 范围等辅助功能使用；它不决定主曲线几何。
  int get auxiliaryFinerLevelCount => switch (this) {
    PlotLodQuality.performance => 0,
    PlotLodQuality.balanced => 1,
    PlotLodQuality.quality => 2,
  };
}

/// Painter 查询普通与派生通道 LOD 的统一入口。
abstract interface class PlotLodSource {
  int get length;
  bool get isEmpty;
  bool get isNotEmpty;

  bool canQuery(double visiblePointCount, double plotWidth);

  PlotLodSeries? query({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
    PlotLodQuality quality,
    bool useViewportCache = false,
    double targetBucketScale = 1,
  });

  /// 返回最细层级的范围摘要，供视口按物理像素重新归并 M4。
  ///
  /// 该接口不把固定 LOD 桶直接当作最终几何；最细桶只提供候选极值，
  /// 最终像素列边界和时序连接由视口查询器决定。
  PlotLodSeries? queryFinest({
    required int channelIndex,
    required double xMin,
    required double xMax,
    bool useViewportCache = false,
  });

  /// 返回桶宽不超过一个目标屏幕列的最粗候选层。
  PlotLodSeries? queryForPixelColumns({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required int maxBucketSize,
    bool useViewportCache = false,
  });

  /// 精确窗口暂未覆盖视口时，返回有界的粗略摘要。
  ///
  /// 该查询不受常规点密度门槛限制，用于异步换窗期间避免空白。
  PlotLodSeries? queryCoarse({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
  });
}

/// 大规模绘图历史数据的内存级 LOD 索引。
///
/// 每个桶从 8 个点开始分层。较小可见范围仍使用精确点窗口；
/// 较大范围可以绘制数量受控的最小/最大采样点，避免每帧扫描全部可见点。
class PlotLodIndex implements PlotLodSource {
  static const int maxChannels = PlotConfiguration.totalChannelCount;
  static const int minBucketSize = 8;
  static const int _minLevel = 3; // 2^3 = 8
  static const int _maxLevel = 23;

  final List<_LodLevel> _levels = [
    for (int level = _minLevel; level <= _maxLevel; level++)
      _LodLevel(1 << level),
  ];

  int _length = 0;
  int _maxChannelCount = 0;
  int _generation = 0;
  final Map<int, _LodQueryCache> _queryCache = <int, _LodQueryCache>{};

  @override
  int get length => _length;
  int get maxChannelCount => _maxChannelCount;
  @override
  bool get isEmpty => _length == 0;
  @override
  bool get isNotEmpty => _length > 0;
  int get allocatedBucketCount =>
      _levels.fold(0, (total, level) => total + level.allocatedBucketCount);
  int get estimatedAllocatedBytes =>
      _levels.fold(0, (total, level) => total + level.estimatedAllocatedBytes);

  int estimatedAdditionalBytesFor(int index, int channelCount) => _levels.fold(
    0,
    (total, level) =>
        total + level.estimatedAdditionalBytesFor(index, channelCount),
  );

  void clear() {
    for (final level in _levels) {
      level.clear();
    }
    _length = 0;
    _maxChannelCount = 0;
    _invalidateQueryCache(release: true);
  }

  void add(int index, List<double> values) {
    final count = _recordPoint(index, values);

    for (final level in _levels) {
      level.add(index, values, count);
    }
  }

  void addSampled(int index, List<double> values, int sampleStep) {
    final count = _recordPoint(index, values);
    final step = math.max(1, sampleStep);
    if (index % step != 0) return;

    for (final level in _levels) {
      level.add(index, values, count);
    }
  }

  int _recordPoint(int index, List<double> values) {
    final count = math.min(values.length, maxChannels);
    if (count > _maxChannelCount) _maxChannelCount = count;
    if (index >= _length) _length = index + 1;
    _invalidateQueryCache();
    return count;
  }

  void _invalidateQueryCache({bool release = false}) {
    _generation++;
    // 实时接收每包都会失效缓存，只递增 generation 可避免高频清空 Map；
    // 下一次查询会按固定 key 覆盖旧条目。真正清空历史时再释放引用。
    if (release) _queryCache.clear();
  }

  void rebuild(Iterable<List<double>> rows) {
    clear();
    var index = 0;
    for (final values in rows) {
      add(index++, values);
    }
  }

  @override
  bool canQuery(double visiblePointCount, double plotWidth) {
    if (_length == 0 || plotWidth <= 0 || visiblePointCount <= 0) return false;
    // 首层 LOD 桶为 8 点；一旦数据密度超过像素宽度，直接使用桶摘要，
    // 避免在中等规模窗口中每帧重新扫描全部点构建临时 min/max 桶。
    return visiblePointCount > plotWidth;
  }

  @override
  PlotLodSeries? query({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
    PlotLodQuality quality = PlotLodQuality.performance,
    bool useViewportCache = false,
    double targetBucketScale = 1,
  }) {
    final stopwatch =
        PlotPerformanceMetrics.enabled ? (Stopwatch()..start()) : null;
    if (channelIndex < 0 ||
        channelIndex >= maxChannels ||
        channelIndex >= _maxChannelCount ||
        plotWidth <= 0 ||
        xMax <= xMin) {
      return null;
    }

    final visibleCount = xMax - xMin;
    if (!canQuery(visibleCount, plotWidth)) return null;

    final targetBucketSize = math.max(
      minBucketSize,
      (visibleCount / plotWidth * targetBucketScale.clamp(1, 16)).ceil(),
    );
    final level = _selectLevel(
      targetBucketSize,
      finerLevelCount: quality.auxiliaryFinerLevelCount,
    );
    PlotLodSeries? result;
    if (useViewportCache) {
      final requestedMin = math.max(0.0, xMin);
      final requestedMax = math.min((_length - 1).toDouble(), xMax);
      final levelIndex = _levels.indexOf(level);
      final key = levelIndex * maxChannels + channelIndex;
      final cached = _queryCache[key];
      if (cached != null &&
          cached.generation == _generation &&
          cached.xMin <= requestedMin &&
          cached.xMax >= requestedMax) {
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.lodCacheHit,
        );
        result = cached.series;
      } else {
        PlotPerformanceMetrics.instance.increment(
          PlotPerformanceMetric.lodCacheMiss,
        );
        final margin = visibleCount * 0.2;
        final cachedMin = math.max(0.0, requestedMin - margin);
        final cachedMax = math.min(
          (_length - 1).toDouble(),
          requestedMax + margin,
        );
        result = level.query(
          channelIndex,
          cachedMin,
          cachedMax,
          clipSamplesToRange: false,
        );
        if (result != null) {
          _queryCache[key] = _LodQueryCache(
            generation: _generation,
            xMin: cachedMin,
            xMax: cachedMax,
            series: result,
          );
        }
      }
    } else {
      result = level.query(channelIndex, xMin, xMax);
    }
    if (stopwatch != null) {
      stopwatch.stop();
      PlotPerformanceMetrics.instance
        ..record(
          PlotPerformanceMetric.lodQueryMicros,
          stopwatch.elapsedMicroseconds,
        )
        ..record(
          PlotPerformanceMetric.lodBucketCount,
          result?.bucketCount ?? 0,
        );
    }
    return result;
  }

  @override
  PlotLodSeries? queryFinest({
    required int channelIndex,
    required double xMin,
    required double xMax,
    bool useViewportCache = false,
  }) {
    return queryForPixelColumns(
      channelIndex: channelIndex,
      xMin: xMin,
      xMax: xMax,
      maxBucketSize: minBucketSize,
      useViewportCache: useViewportCache,
    );
  }

  @override
  PlotLodSeries? queryForPixelColumns({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required int maxBucketSize,
    bool useViewportCache = false,
  }) {
    if (channelIndex < 0 ||
        channelIndex >= maxChannels ||
        channelIndex >= _maxChannelCount ||
        xMax <= xMin ||
        _length == 0) {
      return null;
    }
    var levelIndex = 0;
    for (var i = 1; i < _levels.length; i++) {
      if (_levels[i].bucketSize > maxBucketSize) break;
      levelIndex = i;
    }
    final level = _levels[levelIndex];
    if (!useViewportCache) return level.query(channelIndex, xMin, xMax);

    final requestedMin = math.max(0.0, xMin);
    final requestedMax = math.min((_length - 1).toDouble(), xMax);
    // 常规 query 使用非负层级 key；最细候选使用独立负 key，避免与
    // 性能档恰好选中首层时共享不同裁剪语义的缓存。
    final key = -(levelIndex * maxChannels + channelIndex) - 1;
    final cached = _queryCache[key];
    if (cached != null &&
        cached.generation == _generation &&
        cached.xMin <= requestedMin &&
        cached.xMax >= requestedMax) {
      PlotPerformanceMetrics.instance.increment(
        PlotPerformanceMetric.lodCacheHit,
      );
      return cached.series;
    }

    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.lodCacheMiss,
    );
    final margin = (xMax - xMin) * 0.2;
    final cachedMin = math.max(0.0, requestedMin - margin);
    final cachedMax = math.min((_length - 1).toDouble(), requestedMax + margin);
    final result = level.query(
      channelIndex,
      cachedMin,
      cachedMax,
      clipSamplesToRange: false,
    );
    if (result != null) {
      _queryCache[key] = _LodQueryCache(
        generation: _generation,
        xMin: cachedMin,
        xMax: cachedMax,
        series: result,
      );
    }
    return result;
  }

  @override
  PlotLodSeries? queryCoarse({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
  }) {
    if (channelIndex < 0 ||
        channelIndex >= maxChannels ||
        channelIndex >= _maxChannelCount ||
        plotWidth <= 0 ||
        xMax <= xMin) {
      return null;
    }
    final targetBucketSize = math.max(
      minBucketSize,
      ((xMax - xMin) / plotWidth).ceil(),
    );
    final preferred = _selectLevel(targetBucketSize);
    final preferredResult = preferred.query(
      channelIndex,
      xMin,
      xMax,
      clipSamplesToRange: false,
    );
    if (preferredResult != null) return preferredResult;

    // 高频采样可能跳过最细桶，逐级放大查询桶以确保
    // 定位拖动时总有一个有界的趋势摘要可用。
    final preferredIndex = _levels.indexOf(preferred);
    for (var i = preferredIndex + 1; i < _levels.length; i++) {
      final level = _levels[i];
      final result = level.query(
        channelIndex,
        xMin,
        xMax,
        clipSamplesToRange: false,
      );
      if (result != null) return result;
    }
    return null;
  }

  /// 概览的兼容入口，与精确窗口换载时的粗略查询共用实现。
  PlotLodSeries? queryOverview({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
  }) => queryCoarse(
    channelIndex: channelIndex,
    xMin: xMin,
    xMax: xMax,
    plotWidth: plotWidth,
  );

  _LodLevel _selectLevel(int targetBucketSize, {int finerLevelCount = 0}) {
    for (var index = 0; index < _levels.length; index++) {
      if (_levels[index].bucketSize >= targetBucketSize) {
        final selectedIndex = math.max(0, index - finerLevelCount);
        return _levels[selectedIndex];
      }
    }
    return _levels.last;
  }
}

class _LodQueryCache {
  const _LodQueryCache({
    required this.generation,
    required this.xMin,
    required this.xMax,
    required this.series,
  });

  final int generation;
  final double xMin;
  final double xMax;
  final PlotLodSeries series;
}

class PlotLodSeries {
  final Int32List indices;
  final Float64List values;
  final Int32List bucketOffsets;
  final Uint8List bucketStepKinds;

  const PlotLodSeries({
    required this.indices,
    required this.values,
    required this.bucketOffsets,
    required this.bucketStepKinds,
  }) : assert(indices.length == values.length),
       assert(bucketOffsets.length >= 2),
       assert(bucketStepKinds.length == bucketOffsets.length - 1);

  int get length => indices.length;
  bool get isEmpty => indices.isEmpty;
  bool get isNotEmpty => indices.isNotEmpty;
  int get bucketCount => bucketOffsets.length - 1;
}

class _LodLevel {
  final int bucketSize;
  final List<_LodBucket?> _buckets = [];
  int _allocatedBucketCount = 0;
  int _estimatedAllocatedBytes = 0;

  _LodLevel(this.bucketSize);

  int get allocatedBucketCount => _allocatedBucketCount;
  int get estimatedAllocatedBytes => _estimatedAllocatedBytes;

  int estimatedAdditionalBytesFor(int index, int channelCount) {
    final bucketIndex = index ~/ bucketSize;
    final listGrowth = math.max(0, bucketIndex + 1 - _buckets.length) * 8;
    if (bucketIndex < _buckets.length) {
      final bucket = _buckets[bucketIndex];
      if (bucket != null) {
        return listGrowth + bucket.estimatedGrowthBytes(channelCount);
      }
    }
    return listGrowth + _LodBucket.estimatedBytesForCapacity(channelCount);
  }

  void clear() {
    _buckets.clear();
    _allocatedBucketCount = 0;
    _estimatedAllocatedBytes = 0;
  }

  void add(int index, List<double> values, int channelCount) {
    final bucketIndex = index ~/ bucketSize;
    final previousListLength = _buckets.length;
    while (_buckets.length <= bucketIndex) {
      _buckets.add(null);
    }
    _estimatedAllocatedBytes += (_buckets.length - previousListLength) * 8;
    var bucket = _buckets[bucketIndex];
    if (bucket == null) {
      bucket = _LodBucket(channelCount);
      _buckets[bucketIndex] = bucket;
      _allocatedBucketCount++;
      _estimatedAllocatedBytes += bucket.estimatedAllocatedBytes;
      bucket.add(index, values, channelCount);
      return;
    }
    final previousBytes = bucket.estimatedAllocatedBytes;
    bucket.add(index, values, channelCount);
    _estimatedAllocatedBytes += bucket.estimatedAllocatedBytes - previousBytes;
  }

  PlotLodSeries? query(
    int channelIndex,
    double xMin,
    double xMax, {
    bool clipSamplesToRange = true,
  }) {
    if (_buckets.isEmpty) return null;

    final firstBucket = (xMin.floor() ~/ bucketSize).clamp(
      0,
      _buckets.length - 1,
    );
    final lastBucket = (xMax.ceil() ~/ bucketSize).clamp(
      firstBucket,
      _buckets.length - 1,
    );

    var populatedBucketCount = 0;
    for (var i = firstBucket; i <= lastBucket; i++) {
      if (_buckets[i] != null) populatedBucketCount++;
    }
    if (populatedBucketCount == 0) return null;

    final maxPoints = populatedBucketCount * 4;
    final indices = Int32List(maxPoints);
    final values = Float64List(maxPoints);
    final bucketOffsets = Int32List(populatedBucketCount + 1);
    final bucketStepKinds = Uint8List(populatedBucketCount);
    var out = 0;
    var bucketOut = 0;

    for (int i = firstBucket; i <= lastBucket; i++) {
      final bucket = _buckets[i];
      if (bucket == null) continue;
      final nextOut = bucket.appendChannelSamples(
        channelIndex,
        xMin,
        xMax,
        indices,
        values,
        out,
        clipSamplesToRange: clipSamplesToRange,
      );
      if (nextOut == out) continue;
      bucketOffsets[bucketOut++] = out;
      bucketStepKinds[bucketOut - 1] = bucket.stepKind(channelIndex);
      out = nextOut;
    }

    if (out == 0) return null;
    bucketOffsets[bucketOut] = out;
    return PlotLodSeries(
      indices: Int32List.sublistView(indices, 0, out),
      values: Float64List.sublistView(values, 0, out),
      bucketOffsets: Int32List.sublistView(bucketOffsets, 0, bucketOut + 1),
      bucketStepKinds: Uint8List.sublistView(bucketStepKinds, 0, bucketOut),
    );
  }
}

class _LodBucket {
  late Float64List _firstValues;
  late Float64List _lastValues;
  late Float64List _minValues;
  late Float64List _maxValues;
  late Int32List _minIndices;
  late Int32List _maxIndices;
  late Int32List _firstIndices;
  late Int32List _lastIndices;
  late Uint8List _hasChannel;
  late Uint8List _binaryOnly;

  int _channelCount = 0;

  int get estimatedAllocatedBytes =>
      estimatedBytesForCapacity(_firstValues.length);

  static int estimatedBytesForCapacity(int channelCapacity) {
    final capacity = channelCapacity.clamp(1, PlotLodIndex.maxChannels);
    // 4x Float64、4x Int32、2x Uint8，加上对象和 typed-list 头部余量。
    return 208 + capacity * 50;
  }

  int estimatedGrowthBytes(int nextCapacity) =>
      nextCapacity <= _firstValues.length
          ? 0
          : estimatedBytesForCapacity(nextCapacity) - estimatedAllocatedBytes;

  _LodBucket(int channelCapacity) {
    _allocate(channelCapacity.clamp(1, PlotLodIndex.maxChannels));
  }

  void add(int index, List<double> values, int channelCount) {
    if (channelCount > _firstValues.length) {
      _grow(channelCount);
    }
    if (channelCount > _channelCount) _channelCount = channelCount;

    for (int ch = 0; ch < channelCount; ch++) {
      final value = values[ch];
      if (!value.isFinite) continue;
      if (_hasChannel[ch] == 0) {
        _hasChannel[ch] = 1;
        _binaryOnly[ch] = 1;
        _firstValues[ch] = value;
        _lastValues[ch] = value;
        _minValues[ch] = value;
        _maxValues[ch] = value;
        _minIndices[ch] = index;
        _maxIndices[ch] = index;
        _firstIndices[ch] = index;
        _lastIndices[ch] = index;
        continue;
      }

      _lastValues[ch] = value;
      _lastIndices[ch] = index;
      if (value < _minValues[ch]) {
        if (_minValues[ch] != _maxValues[ch]) _binaryOnly[ch] = 0;
        _minValues[ch] = value;
        _minIndices[ch] = index;
      } else if (value > _maxValues[ch]) {
        if (_minValues[ch] != _maxValues[ch]) _binaryOnly[ch] = 0;
        _maxValues[ch] = value;
        _maxIndices[ch] = index;
      } else if (value != _minValues[ch] && value != _maxValues[ch]) {
        _binaryOnly[ch] = 0;
      }
    }
  }

  /// 桶内始终只有两个精确平台值时，返回上升或下降阶跃类型。
  int stepKind(int channelIndex) {
    if (channelIndex >= _channelCount ||
        _hasChannel[channelIndex] == 0 ||
        _binaryOnly[channelIndex] == 0 ||
        _minValues[channelIndex] >= _maxValues[channelIndex]) {
      return 0;
    }
    final first = _firstValues[channelIndex];
    final last = _lastValues[channelIndex];
    if (first == _minValues[channelIndex] && last == _maxValues[channelIndex]) {
      return 1;
    }
    if (first == _maxValues[channelIndex] && last == _minValues[channelIndex]) {
      return 2;
    }
    return 0;
  }

  int appendChannelSamples(
    int channelIndex,
    double xMin,
    double xMax,
    Int32List indices,
    Float64List values,
    int out, {
    bool clipSamplesToRange = true,
  }) {
    if (channelIndex >= _channelCount || _hasChannel[channelIndex] == 0) {
      return out;
    }

    var previousIndex = -1;
    void append(int index, double value) {
      if (index == previousIndex) return;
      previousIndex = index;
      if (clipSamplesToRange && (index < xMin || index > xMax)) return;
      indices[out] = index;
      values[out] = value;
      out++;
    }

    append(_firstIndices[channelIndex], _firstValues[channelIndex]);
    final minIndex = _minIndices[channelIndex];
    final maxIndex = _maxIndices[channelIndex];
    if (minIndex <= maxIndex) {
      append(minIndex, _minValues[channelIndex]);
      append(maxIndex, _maxValues[channelIndex]);
    } else {
      append(maxIndex, _maxValues[channelIndex]);
      append(minIndex, _minValues[channelIndex]);
    }
    append(_lastIndices[channelIndex], _lastValues[channelIndex]);
    return out;
  }

  void _allocate(int capacity) {
    _firstValues = Float64List(capacity);
    _lastValues = Float64List(capacity);
    _minValues = Float64List(capacity);
    _maxValues = Float64List(capacity);
    _minIndices = Int32List(capacity);
    _maxIndices = Int32List(capacity);
    _firstIndices = Int32List(capacity);
    _lastIndices = Int32List(capacity);
    _hasChannel = Uint8List(capacity);
    _binaryOnly = Uint8List(capacity);
  }

  void _grow(int nextCapacity) {
    final oldFirst = _firstValues;
    final oldLast = _lastValues;
    final oldMin = _minValues;
    final oldMax = _maxValues;
    final oldMinIndices = _minIndices;
    final oldMaxIndices = _maxIndices;
    final oldFirstIndices = _firstIndices;
    final oldLastIndices = _lastIndices;
    final oldHasChannel = _hasChannel;
    final oldBinaryOnly = _binaryOnly;
    _allocate(nextCapacity.clamp(1, PlotLodIndex.maxChannels));
    _firstValues.setRange(0, oldFirst.length, oldFirst);
    _lastValues.setRange(0, oldLast.length, oldLast);
    _minValues.setRange(0, oldMin.length, oldMin);
    _maxValues.setRange(0, oldMax.length, oldMax);
    _minIndices.setRange(0, oldMinIndices.length, oldMinIndices);
    _maxIndices.setRange(0, oldMaxIndices.length, oldMaxIndices);
    _firstIndices.setRange(0, oldFirstIndices.length, oldFirstIndices);
    _lastIndices.setRange(0, oldLastIndices.length, oldLastIndices);
    _hasChannel.setRange(0, oldHasChannel.length, oldHasChannel);
    _binaryOnly.setRange(0, oldBinaryOnly.length, oldBinaryOnly);
  }
}
