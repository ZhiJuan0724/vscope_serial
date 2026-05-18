import 'channel_config.dart';

/// 绘图数据点模型
class PlotDataPoint {
  /// 数据包序号（用于 X 轴，从 0 开始递增）
  final int index;

  /// 相对时间（毫秒，从第一个数据点开始）
  final double timestamp;

  /// 多通道 Y 值
  final List<double> values;

  PlotDataPoint({
    required this.index,
    required this.timestamp,
    required this.values,
  });

  Map<String, dynamic> toJson() => {
        'i': index,
        't': timestamp,
        'v': values,
      };

  factory PlotDataPoint.fromJson(Map<String, dynamic> json) {
    return PlotDataPoint(
      index: json['i'] as int,
      timestamp: (json['t'] as num).toDouble(),
      values: (json['v'] as List).map((e) => (e as num).toDouble()).toList(),
    );
  }

  /// 获取指定通道的值
  double? valueAt(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= values.length) return null;
    return values[channelIndex];
  }

  /// 通道数
  int get channelCount => values.length;
}

/// 绘图数据集
class PlotDataSet {
  final List<PlotDataPoint> points;
  final List<String> channelNames;
  final List<DataType> channelTypes;
  final DateTime startTime;

  PlotDataSet({
    required this.points,
    required this.channelNames,
    this.channelTypes = const [],
    required this.startTime,
  });

  int get channelCount => channelNames.length;

  Map<String, dynamic> toJson() => {
        'startTime': startTime.millisecondsSinceEpoch,
        'channelNames': channelNames,
        'channelTypes': channelTypes.map((t) => t.label).toList(),
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory PlotDataSet.fromJson(Map<String, dynamic> json) {
    return PlotDataSet(
      startTime: DateTime.fromMillisecondsSinceEpoch(json['startTime'] as int),
      channelNames: (json['channelNames'] as List).cast<String>(),
      channelTypes: (json['channelTypes'] as List? ?? [])
          .map((e) => DataType.fromLabel(e as String))
          .toList(),
      points: (json['points'] as List)
          .map((e) => PlotDataPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
