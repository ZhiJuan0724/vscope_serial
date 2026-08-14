import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/plot/plot_frame_rate_counter.dart';

void main() {
  test('绘图帧率只按显式记录的绘图帧计算并在空闲后归零', () async {
    final counter = PlotFrameRateCounter(
      sampleWindow: const Duration(milliseconds: 10),
      idleTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(counter.dispose);

    counter.recordFrame(timestampMicros: 0);
    for (var index = 1; index <= 10; index++) {
      counter.recordFrame(timestampMicros: index * 1000);
    }

    expect(counter.fps.value, closeTo(1000, 0.01));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(counter.fps.value, 0);
  });
}
