import 'package:flutter/material.dart';

import '../../core/constants/plot_configuration.dart';
import 'channel_config.dart';

class MathChannelConfig {
  static const int maxCount = PlotConfiguration.mathChannelCount;

  final int index;
  bool enabled;
  String expression;
  ChannelConfig display;

  MathChannelConfig({
    required this.index,
    this.enabled = false,
    this.expression = '',
    ChannelConfig? display,
  }) : display =
           display ??
           ChannelConfig(
             index: PlotConfiguration.rawChannelCount + index,
             color: ChannelConfig.colorForIndex(
               PlotConfiguration.rawChannelCount + index,
               'dark',
             ),
             alias: 'Math${index + 1}',
           );

  String get name => 'Math${index + 1}';

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'enabled': enabled,
      'expression': expression,
      'color': display.color.toARGB32(),
      'visible': display.visible,
      'showLine': display.showLine,
      'pointSize': display.pointSize,
      'lineWidth': display.lineWidth,
    };
  }

  factory MathChannelConfig.fromJson(Map<String, dynamic> json) {
    final index = ((json['index'] as num?)?.toInt() ?? 0).clamp(
      0,
      maxCount - 1,
    );
    final colorValue =
        (json['color'] as num?)?.toInt() ??
        ChannelConfig.colorForIndex(
          PlotConfiguration.rawChannelCount + index,
          'dark',
        ).toARGB32();
    return MathChannelConfig(
      index: index,
      enabled: json['enabled'] as bool? ?? false,
      expression: json['expression'] as String? ?? '',
      display: ChannelConfig(
        index: PlotConfiguration.rawChannelCount + index,
        color: Color(colorValue),
        alias: 'Math${index + 1}',
        visible: json['visible'] as bool? ?? true,
        showLine: json['showLine'] as bool? ?? true,
        pointSize: ((json['pointSize'] as num?)?.toDouble() ?? 3.0).clamp(
          0.5,
          12.0,
        ),
        lineWidth: ((json['lineWidth'] as num?)?.toDouble() ?? 1.5).clamp(
          0.5,
          8.0,
        ),
        dataType: DataType.double,
      ),
    );
  }

  static List<MathChannelConfig> createDefaults() {
    return List.generate(maxCount, (index) => MathChannelConfig(index: index));
  }

  static List<MathChannelConfig> normalizeList(Object? value) {
    final result = createDefaults();
    if (value is List) {
      for (final item in value) {
        if (item is! Map) continue;
        final parsed = MathChannelConfig.fromJson(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (parsed.index >= 0 && parsed.index < maxCount) {
          result[parsed.index] = parsed;
        }
      }
    }
    return result;
  }
}
