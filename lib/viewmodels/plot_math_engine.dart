import '../core/utils/math_expression.dart';
import '../data/models/math_channel_config.dart';

/// 无 UI 依赖的数学通道编译与求值组件。
///
/// 表达式缓存只由本类拥有；调用方负责提供历史值读取函数，不允许组件反向读取
/// PlotViewModel 或页面状态。
class PlotMathEngine {
  final Map<int, MathExpression> _expressions = {};

  MathExpression? expressionFor(int channelIndex) => _expressions[channelIndex];

  String? validate(String expression) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) return '表达式不能为空';
    try {
      MathExpression.parse(trimmed);
      return null;
    } catch (error) {
      return error is FormatException ? error.message : '表达式格式错误';
    }
  }

  void rebuild(Iterable<MathChannelConfig> channels) {
    _expressions.clear();
    for (final channel in channels) {
      compile(channel);
    }
  }

  void compile(MathChannelConfig channel) {
    _expressions.remove(channel.index);
    if (!channel.enabled || channel.expression.trim().isEmpty) return;
    try {
      _expressions[channel.index] = MathExpression.parse(channel.expression);
    } catch (_) {
      // 配置可以暂时保留无效表达式；对应通道统一输出 NaN。
    }
  }

  void remove(int channelIndex) => _expressions.remove(channelIndex);

  void clear() => _expressions.clear();

  int futureLookahead(Iterable<MathChannelConfig> channels) {
    var result = 0;
    for (final channel in channels) {
      if (!channel.enabled) continue;
      final expression = _expressions[channel.index];
      if (expression != null && expression.futureLookahead > result) {
        result = expression.futureLookahead;
      }
    }
    return result;
  }

  double evaluateValues(int channelIndex, List<double> values) {
    return _expressions[channelIndex]?.evaluate(values) ?? double.nan;
  }

  double evaluateAt({
    required int channelIndex,
    required int currentIndex,
    required int pointCount,
    required double Function(int pointIndex, int channelIndex) valueAt,
  }) {
    final expression = _expressions[channelIndex];
    if (expression == null) return double.nan;
    return expression.evaluateWithContext(
      MathEvalContext(
        currentIndex: currentIndex,
        pointCount: pointCount,
        valueAt: valueAt,
      ),
    );
  }
}
