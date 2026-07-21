import 'dart:collection';

import '../core/constants/rtt_configuration.dart';
import '../data/models/rtt_config.dart';

/// RTT 页面尚未消费的有界数据块队列。
class RttReceiveQueue {
  static const int defaultMaxBytes = RttConfiguration.receiveQueueLimitBytes;

  RttReceiveQueue({this.maxBytes = defaultMaxBytes}) : assert(maxBytes > 0);

  final int maxBytes;
  final Queue<RttDataChunk> _chunks = Queue<RttDataChunk>();
  int _queuedBytes = 0;
  int _droppedBytes = 0;

  int get queuedBytes => _queuedBytes;
  int get droppedBytes => _droppedBytes;
  bool get isNotEmpty => _chunks.isNotEmpty;

  int add(RttDataChunk chunk) {
    if (chunk.data.isEmpty) return 0;
    _chunks.add(chunk);
    _queuedBytes += chunk.data.length;
    var dropped = 0;
    while (_queuedBytes > maxBytes && _chunks.isNotEmpty) {
      final removed = _chunks.removeFirst();
      _queuedBytes -= removed.data.length;
      dropped += removed.data.length;
    }
    _droppedBytes += dropped;
    return dropped;
  }

  List<RttDataChunk> removeUpTo(int byteLimit) {
    if (byteLimit <= 0) return const [];
    final result = <RttDataChunk>[];
    var remaining = byteLimit;
    while (_chunks.isNotEmpty) {
      final next = _chunks.first;
      if (result.isNotEmpty && next.data.length > remaining) break;
      _chunks.removeFirst();
      _queuedBytes -= next.data.length;
      result.add(next);
      remaining -= next.data.length;
      if (remaining <= 0) break;
    }
    return result;
  }

  void clear({bool resetDropped = false}) {
    _chunks.clear();
    _queuedBytes = 0;
    if (resetDropped) _droppedBytes = 0;
  }
}
