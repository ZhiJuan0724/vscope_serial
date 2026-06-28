part of '../plot_viewmodel.dart';

/// PlotViewModel 内部使用的历史数据缓冲和速率采样模型。
/// - 当前绘图窗口需要回看时，通过 [valuesAt] 临时还原单点 List。
class _ParsedValueHistory {
  static const int _chunkPointCount = 4096;
  static const int _maxChannels = 16;

  final List<Float64List> _valueChunks = [];
  final List<Uint8List> _countChunks = [];

  int _length = 0;
  int _maxChannelCount = 0;

  bool get isEmpty => _length == 0;
  int get length => _length;
  int get maxChannelCount => _maxChannelCount;

  void clear() {
    _valueChunks.clear();
    _countChunks.clear();
    _length = 0;
    _maxChannelCount = 0;
  }

  void add(List<double> values) {
    final chunkIndex = _length ~/ _chunkPointCount;
    final chunkOffset = _length % _chunkPointCount;
    if (chunkIndex == _valueChunks.length) {
      _valueChunks.add(Float64List(_chunkPointCount * _maxChannels));
      _countChunks.add(Uint8List(_chunkPointCount));
    }

    final count = values.length.clamp(0, _maxChannels).toInt();
    _countChunks[chunkIndex][chunkOffset] = count;
    final base = chunkOffset * _maxChannels;
    final chunk = _valueChunks[chunkIndex];
    for (int i = 0; i < count; i++) {
      chunk[base + i] = values[i];
    }

    if (count > _maxChannelCount) _maxChannelCount = count;
    _length++;
  }

  List<double> valuesAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    final chunkIndex = index ~/ _chunkPointCount;
    final chunkOffset = index % _chunkPointCount;
    final count = _countChunks[chunkIndex][chunkOffset];
    final base = chunkOffset * _maxChannels;
    final chunk = _valueChunks[chunkIndex];

    return List<double>.generate(
      count,
      (i) => chunk[base + i],
      growable: false,
    );
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
    'fixedFrame' => ParserType.fixedFrame,
    'zobow' => ParserType.zobow,
    'justFloat' => ParserType.justFloat,
    _ => ParserType.fireWater,
  };
}

SendProtocolType _sendProtocolTypeFromString(String value) {
  return switch (value) {
    'rProtocol' => SendProtocolType.rProtocol,
    _ => SendProtocolType.none,
  };
}
