import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/probe_connection_config.dart';
import 'package:vscope_serial/services/rtt_receive_queue.dart';

void main() {
  RttDataChunk chunk(List<int> bytes) => RttDataChunk(
    channel: 0,
    data: Uint8List.fromList(bytes),
    monotonicUs: 1,
    wallClockUs: 2,
  );

  test('超限时丢弃最早完整数据块并保持剩余顺序', () {
    final queue = RttReceiveQueue(maxBytes: 5);

    expect(queue.add(chunk([1, 2, 3])), 0);
    expect(queue.add(chunk([4, 5, 6, 7])), 3);

    expect(queue.queuedBytes, 4);
    expect(queue.droppedBytes, 3);
    expect(queue.removeUpTo(5).single.data, [4, 5, 6, 7]);
  });

  test('单个大块仍作为完整块丢弃而不保留残片', () {
    final queue = RttReceiveQueue(maxBytes: 3);

    expect(queue.add(chunk([1, 2, 3, 4])), 4);
    expect(queue.queuedBytes, 0);
    expect(queue.isNotEmpty, isFalse);
  });
}
