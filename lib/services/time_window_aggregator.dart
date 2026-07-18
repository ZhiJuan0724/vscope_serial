import 'dart:async';
import 'dart:typed_data';

/// 时间窗口聚合器
///
/// 将高频、零散的数据按时间窗口聚合为完整的数据块。
/// 适用于底层串口读取不稳定（如 1B、3B、4B 零散读取）的场景。
class TimeWindowAggregator {
  /// 时间窗口粒度（微秒）
  final int windowUs;

  /// 窗口完成回调
  final void Function(DateTime timestamp, Uint8List data) onWindowComplete;

  final List<int> _buffer = [];
  DateTime? _windowStart;
  Timer? _flushTimer;

  TimeWindowAggregator({
    required this.windowUs,
    required this.onWindowComplete,
  });

  /// 喂入新数据
  ///
  /// [data]: 接收到的字节数据
  /// [receiveTime]: 接收时刻（DateTime，用于时间窗口计算）
  void feed(Uint8List data, DateTime receiveTime) {
    if (data.isEmpty) return;

    if (_windowStart == null) {
      _startWindow(receiveTime);
    }

    // 检查是否跨越了时间窗口边界
    final elapsedUs = receiveTime.difference(_windowStart!).inMicroseconds;

    if (elapsedUs >= windowUs && _buffer.isNotEmpty) {
      _emitWindow();
      _startWindow(receiveTime);
    }

    _buffer.addAll(data);
  }

  void _startWindow(DateTime receiveTime) {
    _windowStart = receiveTime;
    _flushTimer?.cancel();
    _flushTimer = Timer(Duration(microseconds: windowUs), _emitWindow);
  }

  void _emitWindow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final windowStart = _windowStart;
    if (_buffer.isNotEmpty && windowStart != null) {
      onWindowComplete(windowStart, Uint8List.fromList(_buffer));
    }
    _buffer.clear();
    _windowStart = null;
  }

  /// 强制刷新当前窗口（用于停止接收时发送剩余数据）
  void flush() {
    _emitWindow();
  }

  /// 重置状态
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _buffer.clear();
    _windowStart = null;
  }
}
