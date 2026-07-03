import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/math_channel_config.dart';

void main() {
  group('MathChannelConfig', () {
    test('toJson不持久化运行时偏移和缩放', () {
      final channel =
          MathChannelConfig(index: 0)
            ..enabled = true
            ..expression = 'CH0 + CH1';
      channel.display
        ..yOffset = 123.0
        ..offsetEnabled = true
        ..yScale = 2.5;

      final json = channel.toJson();

      expect(json.containsKey('yOffset'), false);
      expect(json.containsKey('offsetEnabled'), false);
      expect(json.containsKey('yScale'), false);
    });

    test('fromJson忽略旧配置中的运行时偏移和缩放', () {
      final channel = MathChannelConfig.fromJson({
        'index': 0,
        'enabled': true,
        'expression': 'CH0 + CH1',
        'yOffset': 123.0,
        'offsetEnabled': true,
        'yScale': 2.5,
      });

      expect(channel.display.yOffset, 0.0);
      expect(channel.display.offsetEnabled, false);
      expect(channel.display.yScale, 1.0);
    });
  });
}
