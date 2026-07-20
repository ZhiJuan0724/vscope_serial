typedef PlotStatisticsValueReader = List<double>? Function(int pointIndex);

class PlotChannelStatistics {
  const PlotChannelStatistics({
    required this.minimum,
    required this.maximum,
    required this.average,
    required this.sampleCount,
  });

  final double minimum;
  final double maximum;
  final double average;
  final int sampleCount;
}

class PlotStatisticsResult {
  const PlotStatisticsResult({
    required this.channels,
    required this.rangePointCount,
    required this.approximate,
    required this.sampleLimit,
  });

  final List<PlotChannelStatistics?> channels;
  final int rangePointCount;
  final bool approximate;
  final int sampleLimit;
}

/// 对历史值执行有界采样统计，不依赖 ViewModel、Widget 或格式化规则。
class PlotStatisticsCalculator {
  static const int defaultExactPointLimit = 100000;

  const PlotStatisticsCalculator();

  PlotStatisticsResult calculate({
    required int rangeStart,
    required int rangeEnd,
    required int channelCount,
    required bool Function(int channelIndex) isChannelVisible,
    required PlotStatisticsValueReader valuesAt,
    int exactPointLimit = defaultExactPointLimit,
  }) {
    final pointCount = rangeEnd - rangeStart + 1;
    final approximate = pointCount > exactPointLimit;
    final sampleStep =
        approximate
            ? (pointCount / exactPointLimit).ceil().clamp(1, pointCount)
            : 1;
    final maximums = List<double?>.filled(channelCount, null);
    final minimums = List<double?>.filled(channelCount, null);
    final sums = List<double>.filled(channelCount, 0);
    final counts = List<int>.filled(channelCount, 0);

    for (
      var pointIndex = rangeStart;
      pointIndex <= rangeEnd;
      pointIndex += sampleStep
    ) {
      final values = valuesAt(pointIndex);
      if (values == null) continue;
      for (var channelIndex = 0; channelIndex < channelCount; channelIndex++) {
        if (!isChannelVisible(channelIndex) || channelIndex >= values.length) {
          continue;
        }
        final value = values[channelIndex];
        if (!value.isFinite) continue;
        maximums[channelIndex] =
            maximums[channelIndex] == null || value > maximums[channelIndex]!
                ? value
                : maximums[channelIndex];
        minimums[channelIndex] =
            minimums[channelIndex] == null || value < minimums[channelIndex]!
                ? value
                : minimums[channelIndex];
        sums[channelIndex] += value;
        counts[channelIndex]++;
      }
    }

    return PlotStatisticsResult(
      channels: List<PlotChannelStatistics?>.generate(channelCount, (index) {
        if (counts[index] == 0) return null;
        return PlotChannelStatistics(
          minimum: minimums[index]!,
          maximum: maximums[index]!,
          average: sums[index] / counts[index],
          sampleCount: counts[index],
        );
      }, growable: false),
      rangePointCount: pointCount,
      approximate: approximate,
      sampleLimit: exactPointLimit,
    );
  }
}
