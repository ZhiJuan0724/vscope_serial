import 'dart:collection';
import 'dart:typed_data';

/// Shell 接收侧的有界块队列。
///
/// 队列按串口回调块保留边界；达到上限时丢弃最旧的完整待处理块，避免
/// 高频输入长期快于界面消费速度时无限占用内存。
class ShellReceiveQueue {
  /// Shell UI 尚未消费的接收数据默认上限。
  static const int defaultMaxBytes = 256 * 1024 * 1024;

  ShellReceiveQueue({required this.maxBytes})
    : assert(maxBytes > 0, 'maxBytes must be positive');

  final int maxBytes;
  final Queue<_QueuedChunk> _chunks = Queue<_QueuedChunk>();

  int _queuedBytes = 0;
  int _droppedBytes = 0;

  int get queuedBytes => _queuedBytes;
  int get droppedBytes => _droppedBytes;
  bool get isNotEmpty => _chunks.isNotEmpty;

  /// 追加一个接收块，并返回本次为满足上限而丢弃的字节数。
  int add(Uint8List data) {
    if (data.isEmpty) return 0;
    var droppedNow = 0;
    var retained = data;
    if (retained.length > maxBytes) {
      final prefixLength = retained.length - maxBytes;
      retained = Uint8List.sublistView(retained, prefixLength);
      droppedNow += prefixLength;
    }

    _chunks.add(_QueuedChunk(retained));
    _queuedBytes += retained.length;
    while (_queuedBytes > maxBytes && _chunks.isNotEmpty) {
      final removed = _chunks.removeFirst().remaining;
      _queuedBytes -= removed;
      droppedNow += removed;
    }
    _droppedBytes += droppedNow;
    return droppedNow;
  }

  /// 按原块边界取出不超过 [maxBytes] 的数据视图。
  List<Uint8List> removeUpTo(int maxBytes) {
    if (maxBytes <= 0 || _chunks.isEmpty) return const [];
    final result = <Uint8List>[];
    var remaining = maxBytes;
    while (remaining > 0 && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final count = chunk.remaining.clamp(0, remaining);
      if (count == 0) break;
      result.add(
        Uint8List.sublistView(chunk.data, chunk.offset, chunk.offset + count),
      );
      chunk.offset += count;
      _queuedBytes -= count;
      remaining -= count;
      if (chunk.remaining == 0) _chunks.removeFirst();
    }
    return result;
  }

  /// 开始新会话时同时清空积压和本会话丢弃统计。
  void reset() {
    _chunks.clear();
    _queuedBytes = 0;
    _droppedBytes = 0;
  }
}

class _QueuedChunk {
  _QueuedChunk(this.data);

  final Uint8List data;
  int offset = 0;

  int get remaining => data.length - offset;
}
