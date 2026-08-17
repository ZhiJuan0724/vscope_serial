import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/plot/plot_interaction_frame_pacer.dart';

void main() {
  int countSubmissions({
    required int targetFps,
    required Iterable<int> frameTimesMicros,
    bool Function(int timestampMicros)? hasPending,
  }) {
    final pacer = PlotInteractionFramePacer()..start(targetFps: targetFps);
    var count = 0;
    for (final timestamp in frameTimesMicros) {
      if (pacer.shouldSubmit(
        elapsedMicros: timestamp,
        hasPendingViewport: hasPending?.call(timestamp) ?? true,
      )) {
        count++;
      }
    }
    return count;
  }

  Iterable<int> fixedFrames(int hz, {int durationMicros = 1000000}) sync* {
    final period = Duration.microsecondsPerSecond / hz;
    var index = 0;
    while ((index * period).round() < durationMicros) {
      yield (index * period).round();
      index++;
    }
  }

  test('75Hz显示节奏下60fps目标不会退化为隔帧约35fps', () {
    final count = countSubmissions(
      targetFps: 60,
      frameTimesMicros: fixedFrames(75),
    );

    expect(count, inInclusiveRange(59, 61));
  });

  test('目标帧率高于显示节奏时每个有更新的显示帧最多提交一次', () {
    final frames = fixedFrames(75).toList();
    final count = countSubmissions(targetFps: 120, frameTimesMicros: frames);

    expect(count, frames.length);
  });

  test('60Hz显示节奏下30fps目标均匀提交约30帧', () {
    final count = countSubmissions(
      targetFps: 30,
      frameTimesMicros: fixedFrames(60),
    );

    expect(count, inInclusiveRange(29, 31));
  });

  test('抖动显示间隔不会因整数毫秒门限固定减半', () {
    final timestamps = <int>[0];
    const intervals = <int>[13000, 14000, 16000, 17000];
    var elapsed = 0;
    var index = 0;
    while (elapsed < Duration.microsecondsPerSecond) {
      elapsed += intervals[index++ % intervals.length];
      if (elapsed < Duration.microsecondsPerSecond) timestamps.add(elapsed);
    }

    final count = countSubmissions(targetFps: 60, frameTimesMicros: timestamps);

    expect(count, inInclusiveRange(57, 61));
  });

  test('没有新视口时不重复提交且恢复输入后立即跟上绝对截止时间', () {
    final frames = fixedFrames(60).toList();
    final count = countSubmissions(
      targetFps: 60,
      frameTimesMicros: frames,
      hasPending: (timestamp) => timestamp < 100000 || timestamp >= 500000,
    );

    expect(count, inInclusiveRange(35, 37));
  });

  test('长时间运行保持小数周期且不累计取整漂移', () {
    final count = countSubmissions(
      targetFps: 60,
      frameTimesMicros: fixedFrames(75, durationMicros: 10000000),
    );

    expect(count, inInclusiveRange(599, 601));
  });
}
