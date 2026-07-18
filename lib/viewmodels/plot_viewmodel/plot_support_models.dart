part of '../plot_viewmodel.dart';

/// PlotViewModel 内部使用的历史数据缓冲和速率采样模型。
/// - 当前绘图窗口需要回看时，通过 [valuesAt] 临时还原单点 List。
class _ParsedValueHistory {
  static const int _chunkPointCount = 4096;
  static const int _maxChannels = PlotConfiguration.rawChannelCount;

  final List<_ParsedValueChunk> _chunks = [];

  int _length = 0;
  int _maxChannelCount = 0;

  bool get isEmpty => _length == 0;
  int get length => _length;
  int get maxChannelCount => _maxChannelCount;
  int get allocatedValueSlots =>
      _chunks.fold(0, (total, chunk) => total + chunk.allocatedValueSlots);

  @visibleForTesting
  void debugSetLengthForTest(
    int length, {
    int maxChannelCount = PlotConfiguration.rawChannelCount,
  }) {
    _chunks.clear();
    _length = length;
    _maxChannelCount = maxChannelCount.clamp(0, _maxChannels).toInt();
  }

  void clear() {
    _chunks.clear();
    _length = 0;
    _maxChannelCount = 0;
  }

  void add(List<double> values) {
    final chunkIndex = _length ~/ _chunkPointCount;
    if (chunkIndex == _chunks.length) {
      _chunks.add(
        _ParsedValueChunk(
          pointCapacity: _chunkPointCount,
          channelCapacity: values.length.clamp(1, _maxChannels),
        ),
      );
    }

    final count = values.length.clamp(0, _maxChannels).toInt();
    _chunks[chunkIndex].add(values, count);

    if (count > _maxChannelCount) _maxChannelCount = count;
    _length++;
  }

  List<double> valuesAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    final chunkIndex = index ~/ _chunkPointCount;
    final chunkOffset = index % _chunkPointCount;
    return _chunks[chunkIndex].valuesAt(chunkOffset);
  }

  int valueCountAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    return _chunks[index ~/ _chunkPointCount].valueCountAt(
      index % _chunkPointCount,
    );
  }

  double valueAt(int pointIndex, int channelIndex) {
    RangeError.checkValueInInterval(pointIndex, 0, _length - 1, 'pointIndex');
    return _chunks[pointIndex ~/ _chunkPointCount].valueAt(
      pointIndex % _chunkPointCount,
      channelIndex,
    );
  }
}

/// 一个历史值块。稳定通道协议只按实际通道数分配；同一块内通道数增加时
/// 才扩容并重排已有数据，避免少通道场景长期按普通通道上限分配空间。
class _ParsedValueChunk {
  final int pointCapacity;
  int channelCapacity;
  late Float64List _values;
  final Uint8List _counts;
  int _length = 0;

  _ParsedValueChunk({
    required this.pointCapacity,
    required this.channelCapacity,
  }) : _counts = Uint8List(pointCapacity) {
    _values = Float64List(pointCapacity * channelCapacity);
  }

  int get allocatedValueSlots => _values.length;

  void add(List<double> values, int count) {
    if (_length >= pointCapacity) {
      throw StateError('parsed value chunk is full');
    }
    if (count > channelCapacity) {
      _growChannels(count);
    }
    _counts[_length] = count;
    final base = _length * channelCapacity;
    for (var i = 0; i < count; i++) {
      _values[base + i] = values[i];
    }
    _length++;
  }

  List<double> valuesAt(int pointOffset) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    final count = _counts[pointOffset];
    final base = pointOffset * channelCapacity;
    return List<double>.generate(
      count,
      (i) => _values[base + i],
      growable: false,
    );
  }

  int valueCountAt(int pointOffset) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    return _counts[pointOffset];
  }

  double valueAt(int pointOffset, int channelIndex) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    RangeError.checkValueInInterval(
      channelIndex,
      0,
      _counts[pointOffset] - 1,
      'channelIndex',
    );
    return _values[pointOffset * channelCapacity + channelIndex];
  }

  void _growChannels(int nextCapacity) {
    final expanded = Float64List(pointCapacity * nextCapacity);
    for (var point = 0; point < _length; point++) {
      final oldBase = point * channelCapacity;
      final newBase = point * nextCapacity;
      final count = _counts[point];
      expanded.setRange(newBase, newBase + count, _values, oldBase);
    }
    channelCapacity = nextCapacity;
    _values = expanded;
  }
}

/// 当前绘图窗口对紧凑历史中单个点的只读视图。
///
/// 视图本身不复制通道值，避免当前精确窗口再次持有一份逐点 List。
class _ParsedHistoryValues extends ListBase<double> {
  final _ParsedValueHistory history;
  final int pointIndex;

  _ParsedHistoryValues(this.history, this.pointIndex);

  @override
  int get length => history.valueCountAt(pointIndex);

  @override
  set length(int value) => throw UnsupportedError('只读视图');

  @override
  double operator [](int index) => history.valueAt(pointIndex, index);

  @override
  void operator []=(int index, double value) {
    throw UnsupportedError('只读视图');
  }
}

/// 数学通道显示点使用的只读组合视图。
///
/// 普通通道值直接引用原始点，只有数学结果单独分配，避免每启用一个数学
/// 通道就为当前窗口内的每个点复制全部普通通道值。
class _CombinedChannelValues extends ListBase<double> {
  final List<double> rawValues;
  final int rawChannelCount;
  final List<double> mathValues;

  _CombinedChannelValues({
    required this.rawValues,
    required this.rawChannelCount,
    required this.mathValues,
  });

  @override
  int get length => rawChannelCount + mathValues.length;

  @override
  set length(int value) {
    throw UnsupportedError('combined channel values are read-only');
  }

  @override
  double operator [](int index) {
    RangeError.checkValidIndex(index, this);
    if (index < rawChannelCount) {
      return index < rawValues.length ? rawValues[index] : double.nan;
    }
    return mathValues[index - rawChannelCount];
  }

  @override
  void operator []=(int index, double value) {
    throw UnsupportedError('combined channel values are read-only');
  }
}

class _RateBucket {
  final int startMs;
  final int firstIndex;
  final int firstTimestampMs;
  int lastIndex;
  int lastTimestampMs;

  _RateBucket({
    required this.startMs,
    required this.firstIndex,
    required this.firstTimestampMs,
  }) : lastIndex = firstIndex,
       lastTimestampMs = firstTimestampMs;

  void update(int index, int timestampMs) {
    lastIndex = index;
    lastTimestampMs = timestampMs;
  }
}

/// 将字符串解析为 ParserType
ParserType _parserTypeFromString(String value) {
  return switch (value) {
    'fireWater' => ParserType.fireWater,
    'fixedFrame' => ParserType.fixedFrame,
    'zobow' => ParserType.zobow,
    'justFloat' => ParserType.justFloat,
    _ => ParserType.zobow,
  };
}

SendProtocolType _sendProtocolTypeFromString(String value) {
  return switch (value) {
    'rProtocol' => SendProtocolType.rProtocol,
    _ => SendProtocolType.none,
  };
}
