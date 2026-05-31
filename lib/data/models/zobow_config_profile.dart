import 'dart:convert';

enum AddressProfileProtocolType {
  zobow('zobow'),
  rProtocol('rProtocol');

  final String id;

  const AddressProfileProtocolType(this.id);

  static AddressProfileProtocolType fromJsonValue(Object? value) {
    return value == rProtocol.id ? rProtocol : zobow;
  }
}

/// Zobow通道预设：名称 + 地址（键值对）
class ZobowChannelPreset {
  /// 预设名称（如 "温度传感器"、"压力传感器"）
  String name;

  /// 通道地址（4字节16进制值，如 0x00000001）
  int address;

  ZobowChannelPreset({required this.name, required this.address});

  /// 从JSON映射创建
  factory ZobowChannelPreset.fromJson(Map<String, dynamic> json) {
    return ZobowChannelPreset(
      name: json['name'] as String? ?? '',
      address: (json['address'] as num?)?.toInt() ?? 0,
    );
  }

  /// 转换为JSON映射
  Map<String, dynamic> toJson() => {'name': name, 'address': address};

  ZobowChannelPreset copyWith({String? name, int? address}) {
    return ZobowChannelPreset(
      name: name ?? this.name,
      address: address ?? this.address,
    );
  }
}

/// 众邦电控配置文件
class ZobowConfigProfile {
  /// 配置所属协议。旧版 JSON 缺少该字段时默认按 Zobow 处理。
  AddressProfileProtocolType protocolType;

  /// 配置文件唯一标识（文件名，不含扩展名）
  String id;

  /// 配置文件显示名称
  String name;

  /// 预设列表（名称+地址键值对）
  List<ZobowChannelPreset> presets;

  ZobowConfigProfile({
    required this.id,
    required this.name,
    this.protocolType = AddressProfileProtocolType.zobow,
    List<ZobowChannelPreset>? presets,
  }) : presets = presets ?? [];

  /// 创建默认空配置文件
  factory ZobowConfigProfile.empty(
    String id, {
    String? name,
    AddressProfileProtocolType protocolType = AddressProfileProtocolType.zobow,
  }) {
    return ZobowConfigProfile(
      id: id,
      name: name ?? '未命名配置',
      protocolType: protocolType,
      presets: [],
    );
  }

  /// 从JSON映射创建
  factory ZobowConfigProfile.fromJson(Map<String, dynamic> json) {
    final presetsList =
        (json['presets'] as List<dynamic>?)
            ?.map((e) => ZobowChannelPreset.fromJson(e as Map<String, dynamic>))
            .toList();
    return ZobowConfigProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名配置',
      protocolType: AddressProfileProtocolType.fromJsonValue(
        json['protocolType'],
      ),
      presets: presetsList ?? [],
    );
  }

  /// 转换为JSON映射
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocolType': protocolType.id,
    'presets': presets.map((p) => p.toJson()).toList(),
  };

  /// 转换为JSON字符串
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  ZobowConfigProfile copyWith({
    String? id,
    String? name,
    AddressProfileProtocolType? protocolType,
    List<ZobowChannelPreset>? presets,
  }) {
    return ZobowConfigProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      protocolType: protocolType ?? this.protocolType,
      presets: presets ?? List.from(this.presets),
    );
  }
}
