import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/viewmodels/plot_statistics_calculator.dart';

void main() {
  test('统计计算器忽略不可见和非有限值', () {
    const calculator = PlotStatisticsCalculator();
    final result = calculator.calculate(
      rangeStart: 0,
      rangeEnd: 2,
      channelCount: 2,
      isChannelVisible: (index) => index == 0,
      valuesAt: (index) => [index == 1 ? double.nan : index + 1.0, 99],
    );

    expect(result.approximate, isFalse);
    expect(result.rangePointCount, 3);
    expect(result.channels[0]?.minimum, 1);
    expect(result.channels[0]?.maximum, 3);
    expect(result.channels[0]?.average, 2);
    expect(result.channels[1], isNull);
  });

  test('统计计算器对大范围使用固定上限采样', () {
    const calculator = PlotStatisticsCalculator();
    final result = calculator.calculate(
      rangeStart: 0,
      rangeEnd: 999,
      channelCount: 1,
      isChannelVisible: (_) => true,
      valuesAt: (index) => [index.toDouble()],
      exactPointLimit: 100,
    );

    expect(result.approximate, isTrue);
    expect(result.channels.single?.sampleCount, 100);
  });
}
