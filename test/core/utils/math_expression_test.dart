import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/math_expression.dart';

void main() {
  group('MathExpression', () {
    test('支持通道四则运算和优先级', () {
      expect(MathExpression.parse('CH0+CH1').evaluate([2, 3]), 5);
      expect(MathExpression.parse('CH0-CH1').evaluate([2, 3]), -1);
      expect(MathExpression.parse('CH0*CH1').evaluate([2, 3]), 6);
      expect(MathExpression.parse('CH0/CH1').evaluate([6, 3]), 2);
      expect(MathExpression.parse('CH0+CH1*CH2').evaluate([2, 3, 4]), 14);
    });

    test('支持括号、小数、一元符号、abs 和大小写', () {
      expect(
        MathExpression.parse('(ch0 + 1.5) * -CH1').evaluate([2, 3]),
        -10.5,
      );
      expect(MathExpression.parse('abs(CH2)').evaluate([0, 0, -4]), 4);
      expect(MathExpression.parse('+CH0').evaluate([7]), 7);
    });

    test('无效运行结果返回 NaN', () {
      expect(MathExpression.parse('CH0/CH1').evaluate([1, 0]).isNaN, true);
      expect(MathExpression.parse('CH2').evaluate([1, 2]).isNaN, true);
      expect(
        MathExpression.parse('CH0+CH1').evaluate([1, double.nan]).isNaN,
        true,
      );
    });

    test('拒绝非法表达式', () {
      expect(() => MathExpression.parse(''), throwsFormatException);
      expect(() => MathExpression.parse('CH16'), throwsFormatException);
      expect(() => MathExpression.parse('Math1+CH0'), throwsFormatException);
      expect(() => MathExpression.parse('CH0+'), throwsFormatException);
      expect(() => MathExpression.parse('sin(CH0)'), throwsFormatException);
    });
  });
}
