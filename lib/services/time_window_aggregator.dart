import 'dart:typed_data';

/// 时间窗口聚合器
///
/// 将高频、零散的数据按时间窗口聚合为完整的数据块。
/// 适用于底层串口读取不稳定（如 1B、3B、4B 零散读取）的场景。
class TimeWindowAggregator {
  /// 时间窗口粒度（毫秒）
  final int windowMs;

  /// 窗口完成回调
  final void Function(DateTime timestamp, Uint8List data) onWindowComplete;

  final List<int> _buffer = [];
  DateTime? _windowStart;

  TimeWindowAggregator({
    required this.windowMs,
    required this.onWindowComplete,
  });

  /// 喂入新数据
  ///
  /// [data]: 接收到的字节数据
  /// [receiveTime]: 接收时刻（DateTime，用于时间窗口计算）
  void feed(Uint8List data, DateTime receiveTime) {
    _windowStart ??= receiveTime;

    // 检查是否跨越了时间窗口边界
    final elapsedMs = receiveTime.difference(_windowStart!).inMilliseconds;

    if (elapsedMs >= windowMs && _buffer.isNotEmpty) {
      // 完成当前窗口，发送聚合数据
      onWindowComplete(_windowStart!, Uint8List.fromList(_buffer));
      _buffer.clear();
      _windowStart = receiveTime;
    }

    _buffer.addAll(data);
  }

  /// 强制刷新当前窗口（用于停止接收时发送剩余数据）
  void flush() {
    if (_buffer.isNotEmpty && _windowStart != null) {
      onWindowComplete(_windowStart!, Uint8List.fromList(_buffer));
      _buffer.clear();
      _windowStart = null;
    }
  }

  /// 重置状态
  void reset() {
    _buffer.clear();
    _windowStart = null;
  }
}
