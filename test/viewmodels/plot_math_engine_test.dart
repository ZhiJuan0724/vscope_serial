import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/math_channel_config.dart';
import 'package:vscope_serial/viewmodels/plot_math_engine.dart';

void main() {
  test('数学引擎独立编译、上下文求值并计算未来依赖', () {
    final engine = PlotMathEngine();
    final channel = MathChannelConfig(
      index: 0,
      enabled: true,
      expression: 'CH0[-1] + CH1',
    );

    engine.compile(channel);

    expect(engine.validate('CH0 +'), isNotNull);
    expect(engine.futureLookahead([channel]), 1);
    expect(
      engine.evaluateAt(
        channelIndex: 0,
        currentIndex: 1,
        pointCount: 3,
        valueAt: (pointIndex, channelIndex) {
          const values = [
            [1.0, 10.0],
            [2.0, 20.0],
            [3.0, 30.0],
          ];
          return values[pointIndex][channelIndex];
        },
      ),
      23,
    );
  });
}
