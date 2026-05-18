/// 绘图数据点模型
class PlotDataPoint {
  /// 相对时间（毫秒，从第一个数据点开始）
  final double timestamp;

  /// 多通道 Y 值
  final List<double> values;

  PlotDataPoint({
    required this.timestamp,
    required this.values,
  });

  Map<String, dynamic> toJson() => {
        't': timestamp,
        'v': values,
      };

  factory PlotDataPoint.fromJson(Map<String, dynamic> json) {
    return PlotDataPoint(
      timestamp: (json['t'] as num).toDouble(),
      values: (json['v'] as List).map((e) => (e as num).toDouble()).toList(),
    );
  }
}

/// 绘图数据集
class PlotDataSet {
  final List<PlotDataPoint> points;
  final List<String> channelNames;
  final DateTime startTime;

  PlotDataSet({
    required this.points,
    required this.channelNames,
    required this.startTime,
  });

  int get channelCount => channelNames.length;

  Map<String, dynamic> toJson() => {
        'startTime': startTime.millisecondsSinceEpoch,
        'channelNames': channelNames,
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory PlotDataSet.fromJson(Map<String, dynamic> json) {
    return PlotDataSet(
      startTime: DateTime.fromMillisecondsSinceEpoch(json['startTime'] as int),
      channelNames: (json['channelNames'] as List).cast<String>(),
      points: (json['points'] as List)
          .map((e) => PlotDataPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
