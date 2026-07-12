import 'dart:math' as math;
import 'dart:typed_data';

/// 大规模绘图历史数据的内存级 LOD 索引。
///
/// 每个桶从 64 个点开始分层。较小可见范围仍使用精确点窗口；
/// 较大范围可以绘制数量受控的最小/最大采样点，避免每帧扫描全部可见点。
class PlotLodIndex {
  static const int maxChannels = 16;
  static const int minBucketSize = 64;
  static const int _minLevel = 6; // 2^6 = 64
  static const int _maxLevel = 23;

  final List<_LodLevel> _levels = [
    for (int level = _minLevel; level <= _maxLevel; level++)
      _LodLevel(1 << level),
  ];

  int _length = 0;
  int _maxChannelCount = 0;

  int get length => _length;
  int get maxChannelCount => _maxChannelCount;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length > 0;
  int get allocatedBucketCount =>
      _levels.fold(0, (total, level) => total + level.allocatedBucketCount);

  void clear() {
    for (final level in _levels) {
      level.clear();
    }
    _length = 0;
    _maxChannelCount = 0;
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
    return count;
  }

  void rebuild(Iterable<List<double>> rows) {
    clear();
    var index = 0;
    for (final values in rows) {
      add(index++, values);
    }
  }

  bool canQuery(double visiblePointCount, double plotWidth) {
    if (_length == 0 || plotWidth <= 0 || visiblePointCount <= 0) return false;
    // 首层 LOD 桶为 64 点；一旦数据密度超过像素宽度，直接使用桶摘要，
    // 避免在中等规模窗口中每帧重新扫描全部点构建临时 min/max 桶。
    return visiblePointCount > plotWidth;
  }

  PlotLodSeries? query({
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

    final visibleCount = xMax - xMin;
    if (!canQuery(visibleCount, plotWidth)) return null;

    final targetBucketSize = math.max(
      minBucketSize,
      (visibleCount / plotWidth).ceil(),
    );
    final level = _selectLevel(targetBucketSize);
    return level.query(channelIndex, xMin, xMax);
  }

  /// 概览使用的全范围查询。即使数据量小于像素桶阈值，也返回桶级摘要。
  PlotLodSeries? queryOverview({
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
    return _selectLevel(targetBucketSize).query(channelIndex, xMin, xMax);
  }

  _LodLevel _selectLevel(int targetBucketSize) {
    for (final level in _levels) {
      if (level.bucketSize >= targetBucketSize) return level;
    }
    return _levels.last;
  }
}

class PlotLodSeries {
  final Int32List indices;
  final Float64List values;

  const PlotLodSeries({required this.indices, required this.values})
    : assert(indices.length == values.length);

  int get length => indices.length;
  bool get isEmpty => indices.isEmpty;
  bool get isNotEmpty => indices.isNotEmpty;
}

class _LodLevel {
  final int bucketSize;
  final List<_LodBucket?> _buckets = [];
  int _allocatedBucketCount = 0;

  _LodLevel(this.bucketSize);

  int get allocatedBucketCount => _allocatedBucketCount;

  void clear() {
    _buckets.clear();
    _allocatedBucketCount = 0;
  }

  void add(int index, List<double> values, int channelCount) {
    final bucketIndex = index ~/ bucketSize;
    while (_buckets.length <= bucketIndex) {
      _buckets.add(null);
    }
    var bucket = _buckets[bucketIndex];
    if (bucket == null) {
      bucket = _LodBucket(channelCount);
      _buckets[bucketIndex] = bucket;
      _allocatedBucketCount++;
    }
    bucket.add(index, values, channelCount);
  }

  PlotLodSeries? query(int channelIndex, double xMin, double xMax) {
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
    var out = 0;

    for (int i = firstBucket; i <= lastBucket; i++) {
      final bucket = _buckets[i];
      if (bucket == null) continue;
      out = bucket.appendChannelSamples(
        channelIndex,
        xMin,
        xMax,
        indices,
        values,
        out,
      );
    }

    if (out == 0) return null;
    return PlotLodSeries(
      indices: Int32List.sublistView(indices, 0, out),
      values: Float64List.sublistView(values, 0, out),
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
  late Uint8List _hasChannel;

  int _firstIndex = -1;
  int _lastIndex = -1;
  int _channelCount = 0;

  _LodBucket(int channelCapacity) {
    _allocate(channelCapacity.clamp(1, PlotLodIndex.maxChannels));
  }

  void add(int index, List<double> values, int channelCount) {
    if (channelCount > _firstValues.length) {
      _grow(channelCount);
    }
    if (_firstIndex < 0) _firstIndex = index;
    _lastIndex = index;
    if (channelCount > _channelCount) _channelCount = channelCount;

    for (int ch = 0; ch < channelCount; ch++) {
      final value = values[ch];
      if (_hasChannel[ch] == 0) {
        _hasChannel[ch] = 1;
        _firstValues[ch] = value;
        _lastValues[ch] = value;
        _minValues[ch] = value;
        _maxValues[ch] = value;
        _minIndices[ch] = index;
        _maxIndices[ch] = index;
        continue;
      }

      _lastValues[ch] = value;
      if (value < _minValues[ch]) {
        _minValues[ch] = value;
        _minIndices[ch] = index;
      }
      if (value > _maxValues[ch]) {
        _maxValues[ch] = value;
        _maxIndices[ch] = index;
      }
    }
  }

  int appendChannelSamples(
    int channelIndex,
    double xMin,
    double xMax,
    Int32List indices,
    Float64List values,
    int out,
  ) {
    if (channelIndex >= _channelCount || _hasChannel[channelIndex] == 0) {
      return out;
    }

    var previousIndex = -1;
    void append(int index, double value) {
      if (index == previousIndex) return;
      previousIndex = index;
      if (index < xMin || index > xMax) return;
      indices[out] = index;
      values[out] = value;
      out++;
    }

    append(_firstIndex, _firstValues[channelIndex]);
    final minIndex = _minIndices[channelIndex];
    final maxIndex = _maxIndices[channelIndex];
    if (minIndex <= maxIndex) {
      append(minIndex, _minValues[channelIndex]);
      append(maxIndex, _maxValues[channelIndex]);
    } else {
      append(maxIndex, _maxValues[channelIndex]);
      append(minIndex, _minValues[channelIndex]);
    }
    append(_lastIndex, _lastValues[channelIndex]);
    return out;
  }

  void _allocate(int capacity) {
    _firstValues = Float64List(capacity);
    _lastValues = Float64List(capacity);
    _minValues = Float64List(capacity);
    _maxValues = Float64List(capacity);
    _minIndices = Int32List(capacity);
    _maxIndices = Int32List(capacity);
    _hasChannel = Uint8List(capacity);
  }

  void _grow(int nextCapacity) {
    final oldFirst = _firstValues;
    final oldLast = _lastValues;
    final oldMin = _minValues;
    final oldMax = _maxValues;
    final oldMinIndices = _minIndices;
    final oldMaxIndices = _maxIndices;
    final oldHasChannel = _hasChannel;
    _allocate(nextCapacity.clamp(1, PlotLodIndex.maxChannels));
    _firstValues.setRange(0, oldFirst.length, oldFirst);
    _lastValues.setRange(0, oldLast.length, oldLast);
    _minValues.setRange(0, oldMin.length, oldMin);
    _maxValues.setRange(0, oldMax.length, oldMax);
    _minIndices.setRange(0, oldMinIndices.length, oldMinIndices);
    _maxIndices.setRange(0, oldMaxIndices.length, oldMaxIndices);
    _hasChannel.setRange(0, oldHasChannel.length, oldHasChannel);
  }
}
