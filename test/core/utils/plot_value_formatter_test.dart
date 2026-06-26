import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/plot_value_formatter.dart';

void main() {
  group('formatPlotValue', () {
    test('hides binary floating point tail noise', () {
      expect(formatPlotValue(5784.3 + 19555.85), '25340.15');
      expect(formatPlotValue(25340.149999999998), '25340.15');
    });

    test('keeps integers compact and finite special values explicit', () {
      expect(formatPlotValue(12.000000000000002), '12');
      expect(formatPlotValue(double.nan), 'NaN');
      expect(formatPlotValue(double.infinity), 'Infinity');
    });
  });
}
