import 'dart:async';
import 'dart:typed_data';

/// 包间空闲超时聚合器
///
/// 持续到达的数据归入同一块；只有相邻两包的间隔达到设定值，
/// 或累计数据达到内置上限时，才结束当前块。
class TimeWindowAggregator {
  /// 相邻数据包的空闲超时（微秒）。
  final int idleTimeoutUs;

  /// 单个聚合块允许的最大字节数。
  final int maxBufferBytes;

  /// 窗口完成回调
  final void Function(DateTime timestamp, Uint8List data) onWindowComplete;

  final List<int> _buffer = [];
  DateTime? _windowStart;
  DateTime? _lastReceiveTime;
  Timer? _flushTimer;

  TimeWindowAggregator({
    required this.idleTimeoutUs,
    required this.maxBufferBytes,
    required this.onWindowComplete,
  }) : assert(idleTimeoutUs > 0),
       assert(maxBufferBytes > 0);

  /// 喂入新数据
  ///
  /// [data]: 接收到的字节数据
  /// [receiveTime]: 接收时刻（DateTime，用于时间窗口计算）
  void feed(Uint8List data, DateTime receiveTime) {
    if (data.isEmpty) return;

    final lastReceiveTime = _lastReceiveTime;
    if (_buffer.isNotEmpty &&
        lastReceiveTime != null &&
        receiveTime.difference(lastReceiveTime).inMicroseconds >=
            idleTimeoutUs) {
      _emitWindow();
    }

    var offset = 0;
    while (offset < data.length) {
      _windowStart ??= receiveTime;
      final copyLength = (maxBufferBytes - _buffer.length).clamp(
        0,
        data.length - offset,
      );
      _buffer.addAll(data.sublist(offset, offset + copyLength));
      offset += copyLength;

      if (_buffer.length >= maxBufferBytes) {
        _emitWindow();
      }
    }

    if (_buffer.isNotEmpty) {
      _lastReceiveTime = receiveTime;
      _restartIdleTimer();
    }
  }

  void _restartIdleTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer(Duration(microseconds: idleTimeoutUs), _emitWindow);
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
    _lastReceiveTime = null;
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
    _lastReceiveTime = null;
  }
}
