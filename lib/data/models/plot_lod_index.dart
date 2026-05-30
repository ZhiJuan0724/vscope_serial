import 'dart:math' as math;
import 'dart:typed_data';

/// In-memory level-of-detail index for large plot histories.
///
/// Levels start at 64 points per bucket. Smaller visible ranges keep using the
/// exact point window; larger ranges can draw a bounded number of min/max
/// samples without scanning every visible point each frame.
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

  void clear() {
    for (final level in _levels) {
      level.clear();
    }
    _length = 0;
    _maxChannelCount = 0;
  }

  void add(int index, List<double> values) {
    final count = math.min(values.length, maxChannels);
    if (count > _maxChannelCount) _maxChannelCount = count;
    if (index >= _length) _length = index + 1;

    for (final level in _levels) {
      level.add(index, values, count);
    }
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
    return visiblePointCount / plotWidth >= minBucketSize;
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
  final List<_LodBucket> _buckets = [];

  _LodLevel(this.bucketSize);

  void clear() => _buckets.clear();

  void add(int index, List<double> values, int channelCount) {
    final bucketIndex = index ~/ bucketSize;
    while (_buckets.length <= bucketIndex) {
      _buckets.add(_LodBucket());
    }
    _buckets[bucketIndex].add(index, values, channelCount);
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

    final maxPoints = (lastBucket - firstBucket + 1) * 4;
    final indices = Int32List(maxPoints);
    final values = Float64List(maxPoints);
    var out = 0;

    for (int i = firstBucket; i <= lastBucket; i++) {
      out = _buckets[i].appendChannelSamples(
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
  final Float64List _firstValues = Float64List(PlotLodIndex.maxChannels);
  final Float64List _lastValues = Float64List(PlotLodIndex.maxChannels);
  final Float64List _minValues = Float64List(PlotLodIndex.maxChannels);
  final Float64List _maxValues = Float64List(PlotLodIndex.maxChannels);
  final Int32List _minIndices = Int32List(PlotLodIndex.maxChannels);
  final Int32List _maxIndices = Int32List(PlotLodIndex.maxChannels);
  final Uint8List _hasChannel = Uint8List(PlotLodIndex.maxChannels);

  int _firstIndex = -1;
  int _lastIndex = -1;
  int _channelCount = 0;

  void add(int index, List<double> values, int channelCount) {
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

    final samples = <_LodSample>[
      _LodSample(_firstIndex, _firstValues[channelIndex]),
      _LodSample(_minIndices[channelIndex], _minValues[channelIndex]),
      _LodSample(_maxIndices[channelIndex], _maxValues[channelIndex]),
      _LodSample(_lastIndex, _lastValues[channelIndex]),
    ]..sort((a, b) => a.index.compareTo(b.index));

    var previousIndex = -1;
    for (final sample in samples) {
      if (sample.index == previousIndex) continue;
      previousIndex = sample.index;
      if (sample.index < xMin || sample.index > xMax) continue;
      indices[out] = sample.index;
      values[out] = sample.value;
      out++;
    }
    return out;
  }
}

class _LodSample {
  final int index;
  final double value;

  const _LodSample(this.index, this.value);
}
