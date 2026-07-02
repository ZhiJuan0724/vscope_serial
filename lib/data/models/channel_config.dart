import 'package:flutter/material.dart';

/// 数据类型枚举
enum DataType {
  uint8('uint8', 1),
  uint16('uint16', 2),
  uint32('uint32', 4),
  int8('int8', 1),
  int16('int16', 2),
  int32('int32', 4),
  float('float', 4),
  double('double', 8);

  final String label;
  final int byteSize;

  const DataType(this.label, this.byteSize);

  static DataType fromLabel(String label) {
    return DataType.values.firstWhere(
      (t) => t.label == label,
      orElse: () => DataType.double,
    );
  }
}

/// 通道配置模型
class ChannelConfig {
  /// 通道索引 0-15
  final int index;

  /// 显示开关
  bool visible;

  /// 颜色
  Color color;

  /// 通道别名（用户自定义名称，空则显示默认 ChN）
  String alias;

  /// 连线开关（默认 true）
  bool showLine;

  /// 点直径
  double pointSize;

  /// 线粗细
  double lineWidth;

  /// Y 轴偏移（不改变实际值，仅用于显示）
  double yOffset;

  /// 偏移功能开关（开启后才应用 yOffset 并显示独立基准线）
  bool offsetEnabled;

  /// Y 轴缩放
  double yScale;

  /// 数据类型
  DataType dataType;

  ChannelConfig({
    required this.index,
    this.visible = true,
    required this.color,
    this.alias = '',
    this.showLine = true,
    this.pointSize = 3.0,
    this.lineWidth = 1.5,
    this.yOffset = 0.0,
    this.offsetEnabled = false,
    this.yScale = 1.0,
    this.dataType = DataType.double,
  });

  ChannelConfig copyWith({
    bool? visible,
    Color? color,
    String? alias,
    bool? showLine,
    double? pointSize,
    double? lineWidth,
    double? yOffset,
    bool? offsetEnabled,
    double? yScale,
    DataType? dataType,
  }) {
    return ChannelConfig(
      index: index,
      visible: visible ?? this.visible,
      color: color ?? this.color,
      alias: alias ?? this.alias,
      showLine: showLine ?? this.showLine,
      pointSize: pointSize ?? this.pointSize,
      lineWidth: lineWidth ?? this.lineWidth,
      yOffset: yOffset ?? this.yOffset,
      offsetEnabled: offsetEnabled ?? this.offsetEnabled,
      yScale: yScale ?? this.yScale,
      dataType: dataType ?? this.dataType,
    );
  }

  /// 黑底预设色。保留 15 个预设，颜色选择面板第 16 个位置用于自定义色。
  static final List<Color> darkPresetColors = [
    const Color(0xFFE6194B), // 红
    const Color(0xFF3CB44B), // 绿
    const Color(0xFFFFE119), // 黄
    const Color(0xFF5C7CFA), // 蓝
    const Color(0xFFF58231), // 橙
    const Color(0xFFB86BFF), // 紫
    const Color(0xFF42D4F4), // 青
    const Color(0xFFF032E6), // 品红
    const Color(0xFFBFEF45), // 黄绿
    const Color(0xFFFFA94D), // 暖橙
    const Color(0xFFFF6B6B), // 亮红
    const Color(0xFF38D9A9), // 青绿
    const Color(0xFF74C0FC), // 亮蓝
    const Color(0xFFE6BEFF), // 淡紫
    const Color(0xFFFFD43B), // 金黄
  ];

  /// 白底预设色。与 [darkPresetColors] 按索引一一对应。
  static final List<Color> lightPresetColors = [
    const Color(0xFFC9184A), // 红
    const Color(0xFF2B8A3E), // 绿
    const Color(0xFFE67700), // 黄/橙
    const Color(0xFF364FC7), // 蓝
    const Color(0xFFD9480F), // 橙
    const Color(0xFF862E9C), // 紫
    const Color(0xFF0B7285), // 青
    const Color(0xFFC2255C), // 品红
    const Color(0xFF5C940D), // 黄绿
    const Color(0xFFE8590C), // 暖橙
    const Color(0xFFE03131), // 亮红
    const Color(0xFF087F5B), // 青绿
    const Color(0xFF1971C2), // 亮蓝
    const Color(0xFF9C36B5), // 淡紫
    const Color(0xFFF08C00), // 金黄
  ];

  /// 默认颜色沿用黑底预设，兼容既有调用。
  static List<Color> get defaultColors => darkPresetColors;

  static List<Color> presetColorsForBackground(String background) {
    return background == 'light' ? lightPresetColors : darkPresetColors;
  }

  static Color colorForIndex(int index, String background) {
    final colors = presetColorsForBackground(background);
    return colors[index % colors.length];
  }

  static Color colorForBackground(Color color, String background) {
    final target = presetColorsForBackground(background);
    final source = background == 'light' ? darkPresetColors : lightPresetColors;
    final sourceIndex = _presetIndexOf(color, source);
    if (sourceIndex >= 0) return target[sourceIndex % target.length];

    final targetIndex = _presetIndexOf(color, target);
    if (targetIndex >= 0) return target[targetIndex];
    return color;
  }

  static int _presetIndexOf(Color color, List<Color> colors) {
    final value = color.toARGB32();
    return colors.indexWhere((preset) => preset.toARGB32() == value);
  }

  /// 创建默认 16 通道配置
  static List<ChannelConfig> createDefaults() {
    return List.generate(
      16,
      (i) => ChannelConfig(index: i, color: colorForIndex(i, 'dark')),
    );
  }
}
