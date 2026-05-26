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

  /// 默认 16 通道颜色
  static final List<Color> defaultColors = [
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
    const Color(0xFFFFFFFF), // 白
  ];

  /// 创建默认 16 通道配置
  static List<ChannelConfig> createDefaults() {
    return List.generate(
      16,
      (i) => ChannelConfig(index: i, color: defaultColors[i]),
    );
  }
}
