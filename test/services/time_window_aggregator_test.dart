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

    aggregator.feed(Uint8List.fromList([1]), 0, start);
    aggregator.feed(
      Uint8List.fromList([2]),
      const Duration(seconds: 6).inMicroseconds,
      start.add(const Duration(seconds: 6)),
    );
    aggregator.feed(
      Uint8List.fromList([3]),
      const Duration(seconds: 12).inMicroseconds,
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

    aggregator.feed(Uint8List.fromList([1]), 0, start);
    aggregator.feed(
      Uint8List.fromList([2]),
      const Duration(seconds: 11).inMicroseconds,
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

    aggregator.feed(Uint8List.fromList([1, 2, 3, 4, 5, 6]), 0, DateTime(2026));

    expect(output, [
      [1, 2, 3, 4],
    ]);
    aggregator.flush();
    expect(output, [
      [1, 2, 3, 4],
      [5, 6],
    ]);
  });

  test('墙钟回拨不影响单调时间分包', () {
    final timestamps = <DateTime>[];
    final output = <List<int>>[];
    final start = DateTime(2026);
    final aggregator = TimeWindowAggregator(
      idleTimeoutUs: const Duration(seconds: 10).inMicroseconds,
      maxBufferBytes: 1024,
      onWindowComplete: (timestamp, data) {
        timestamps.add(timestamp);
        output.add(data);
      },
    );

    aggregator.feed(Uint8List.fromList([1]), 0, start);
    aggregator.feed(
      Uint8List.fromList([2]),
      const Duration(seconds: 11).inMicroseconds,
      start.subtract(const Duration(days: 1)),
    );

    expect(output, [
      [1],
    ]);
    expect(timestamps.single, start);
  });

  test('超过30天的单调时间仍按微秒间隔正确分包', () {
    final output = <List<int>>[];
    final aggregator = TimeWindowAggregator(
      idleTimeoutUs: 1000,
      maxBufferBytes: 1024,
      onWindowComplete: (_, data) => output.add(data),
    );
    final afterThirtyDays = const Duration(days: 31).inMicroseconds;

    aggregator.feed(Uint8List.fromList([1]), afterThirtyDays, DateTime(2026));
    aggregator.feed(
      Uint8List.fromList([2]),
      afterThirtyDays + 999,
      DateTime(2026),
    );
    aggregator.feed(
      Uint8List.fromList([3]),
      afterThirtyDays + 2000,
      DateTime(2026),
    );

    expect(output, [
      [1, 2],
    ]);
  });
}
