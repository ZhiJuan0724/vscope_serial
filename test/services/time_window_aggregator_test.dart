import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/time_window_aggregator.dart';

void main() {
  test('持续来包时按最后一包重新计算空闲超时', () {
    final output = <List<int>>[];
    final start = DateTime(2026);
    final aggregator = TimeWindowAggregator(
      idleTimeoutUs: const Duration(seconds: 10).inMicroseconds,
      maxBufferBytes: 1024,
      onWindowComplete: (_, data) => output.add(data),
    );

    aggregator.feed(Uint8List.fromList([1]), start);
    aggregator.feed(
      Uint8List.fromList([2]),
      start.add(const Duration(seconds: 6)),
    );
    aggregator.feed(
      Uint8List.fromList([3]),
      start.add(const Duration(seconds: 12)),
    );

    expect(output, isEmpty);
    aggregator.flush();
    expect(output, [
      [1, 2, 3],
    ]);
  });

  test('相邻两包超时时结束上一个聚合块', () {
    final output = <List<int>>[];
    final start = DateTime(2026);
    final aggregator = TimeWindowAggregator(
      idleTimeoutUs: const Duration(seconds: 10).inMicroseconds,
      maxBufferBytes: 1024,
      onWindowComplete: (_, data) => output.add(data),
    );

    aggregator.feed(Uint8List.fromList([1]), start);
    aggregator.feed(
      Uint8List.fromList([2]),
      start.add(const Duration(seconds: 11)),
    );

    expect(output, [
      [1],
    ]);
    aggregator.flush();
    expect(output, [
      [1],
      [2],
    ]);
  });

  test('连续数据达到内置容量上限时强制结束', () {
    final output = <List<int>>[];
    final aggregator = TimeWindowAggregator(
      idleTimeoutUs: const Duration(seconds: 10).inMicroseconds,
      maxBufferBytes: 4,
      onWindowComplete: (_, data) => output.add(data),
    );

    aggregator.feed(Uint8List.fromList([1, 2, 3, 4, 5, 6]), DateTime(2026));

    expect(output, [
      [1, 2, 3, 4],
    ]);
    aggregator.flush();
    expect(output, [
      [1, 2, 3, 4],
      [5, 6],
    ]);
  });
}
