/// 连续绘图交互使用的显示帧节拍器。
///
/// 指针事件只负责更新最新目标视口；本类根据显示帧时间决定当前帧是否
/// 应提交。周期使用微秒小数并按绝对截止时间推进，避免 60 fps 被取整为
/// 17 ms 后与 13～16 ms 的输入事件发生混叠。
class PlotInteractionFramePacer {
  static const double _deadlineToleranceMicros = 1;

  PlotInteractionFramePacer({int targetFps = 60})
    : _targetFps = _normalizeFps(targetFps);

  int _targetFps;
  bool _active = false;
  double? _nextDeadlineMicros;

  int get targetFps => _targetFps;
  bool get isActive => _active;
  double get _periodMicros => Duration.microsecondsPerSecond / _targetFps;

  void start({required int targetFps}) {
    _targetFps = _normalizeFps(targetFps);
    _active = true;
    _nextDeadlineMicros = 0;
  }

  void updateTargetFps(int targetFps) {
    final normalized = _normalizeFps(targetFps);
    if (_targetFps == normalized) return;
    _targetFps = normalized;
    if (_active) _nextDeadlineMicros = null;
  }

  /// 当前显示帧是否可以提交最新目标。
  ///
  /// [elapsedMicros] 必须来自同一次连续交互的单调时钟。落后多个周期时
  /// 直接跨过过期截止时间，调用方只提交最新目标，不补画历史中间帧。
  bool shouldSubmit({
    required int elapsedMicros,
    required bool hasPendingViewport,
  }) {
    if (!_active || !hasPendingViewport) return false;

    var deadline = _nextDeadlineMicros ?? elapsedMicros.toDouble();
    if (elapsedMicros + _deadlineToleranceMicros < deadline) return false;

    final period = _periodMicros;
    final overdueMicros = elapsedMicros - deadline;
    final elapsedPeriods =
        overdueMicros < 0 ? 1 : (overdueMicros / period).floor() + 1;
    deadline += elapsedPeriods * period;
    _nextDeadlineMicros = deadline;
    return true;
  }

  void stop() {
    _active = false;
    _nextDeadlineMicros = null;
  }

  static int _normalizeFps(int value) => value.clamp(1, 1000);
}
