typedef PlotTriggerMatcher = bool Function(double value, double? previousValue);

/// 单次触发条件评估结果，泛型负载由调用方定义。
class PlotTriggerEvaluation<T> {
  const PlotTriggerEvaluation({
    this.thresholdReached = false,
    this.limitReached = false,
    this.stopRequested = false,
    this.hitItems = const [],
  });

  final bool thresholdReached;
  final bool limitReached;
  final bool stopRequested;
  final List<T> hitItems;
}

/// 触发命中计数和延迟停止的纯状态机。
///
/// 通道取值、观察文本和页面停止动作由调用方负责；本类只拥有跨数据点延续的
/// previous/hit/limit 状态，因此可以脱离 PlotViewModel 单独验证。
class PlotTriggerRuntime<T> {
  final List<T> _hitItems = [];
  double? _previousValue;
  int _hitCount = 0;
  int _triggeredCount = 0;
  int? _stopItemsRemaining;
  bool _stopRequested = false;

  int get hitCount => _hitCount;
  int get triggeredCount => _triggeredCount;
  int? get stopItemsRemaining => _stopItemsRemaining;
  bool get stopRequested => _stopRequested;

  PlotTriggerEvaluation<T> process({
    required T item,
    required double? value,
    required bool enabled,
    required int hitThreshold,
    required int triggerLimit,
    required bool stopAtLimit,
    required int postStopItemCount,
    required PlotTriggerMatcher matches,
  }) {
    if (_stopItemsRemaining != null) {
      _previousValue = value;
      final remaining = _stopItemsRemaining! - 1;
      if (remaining <= 0) {
        _stopItemsRemaining = null;
        _stopRequested = true;
        return const PlotTriggerEvaluation(stopRequested: true);
      }
      _stopItemsRemaining = remaining;
      return const PlotTriggerEvaluation();
    }

    if (!enabled || _stopRequested || value == null) {
      _previousValue = value;
      return const PlotTriggerEvaluation();
    }

    final matched = matches(value, _previousValue);
    _previousValue = value;
    if (!matched) return const PlotTriggerEvaluation();

    _hitCount++;
    _hitItems.add(item);
    if (_hitCount < hitThreshold) return const PlotTriggerEvaluation();

    _triggeredCount++;
    final hits = List<T>.unmodifiable(_hitItems);
    _hitCount = 0;
    _hitItems.clear();
    final limitReached = _triggeredCount >= triggerLimit;
    var shouldStop = false;
    if (limitReached && stopAtLimit) {
      if (postStopItemCount > 0) {
        _stopItemsRemaining = postStopItemCount;
      } else {
        _stopRequested = true;
        shouldStop = true;
      }
    }
    return PlotTriggerEvaluation<T>(
      thresholdReached: true,
      limitReached: limitReached,
      stopRequested: shouldStop,
      hitItems: hits,
    );
  }

  bool requestStop() {
    if (_stopRequested) return false;
    _stopRequested = true;
    return true;
  }

  void reset() {
    _hitItems.clear();
    _previousValue = null;
    _hitCount = 0;
    _triggeredCount = 0;
    _stopItemsRemaining = null;
    _stopRequested = false;
  }
}
