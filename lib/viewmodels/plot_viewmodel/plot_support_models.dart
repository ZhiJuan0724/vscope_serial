part of '../plot_viewmodel.dart';

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
