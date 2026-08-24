import '../core/constants/plot_configuration.dart';
import '../data/models/math_channel_config.dart';
import '../data/models/plot_data.dart';
import 'plot_math_engine.dart';

/// 将原始通道和数学通道结果组装为观察快照。
///
/// 只处理数值顺序和 NaN 规则，不持有观察列表或页面交互状态。
class PlotObservationAssembler {
  const PlotObservationAssembler();

  List<double> fromPoint({
    required PlotDataPoint point,
    required int rawChannelCount,
    required Iterable<MathChannelConfig> mathChannels,
    required PlotMathEngine mathEngine,
  }) {
    final rawCount = rawChannelCount.clamp(
      0,
      PlotConfiguration.rawChannelCount,
    );
    final values = List<double>.generate(
      rawCount,
      (index) => index < point.values.length ? point.values[index] : double.nan,
      growable: true,
    );
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      final expression = mathEngine.expressionFor(channel.index);
      if (expression == null || expression.hasChannelOffset) {
        values.add(double.nan);
      } else {
        values.add(mathEngine.evaluateValues(channel.index, point.values));
      }
    }
    return values;
  }
}
