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

enum AddressValueFormat {
  hexadecimal('hex'),
  decimal('decimal');

  final String id;

  const AddressValueFormat(this.id);

  static AddressValueFormat fromJsonValue(Object? value) {
    return value == decimal.id ? decimal : hexadecimal;
  }
}

/// 地址通道预设：名称、地址数值及其文本进制。
class AddressChannelPreset {
  /// 预设名称（如 "温度传感器"、"压力传感器"）
  String name;

  /// 32 位无符号地址数值。
  int address;

  /// 地址在配置界面中的显示和输入格式。
  AddressValueFormat addressFormat;

  AddressChannelPreset({
    required this.name,
    required this.address,
    this.addressFormat = AddressValueFormat.hexadecimal,
  });

  static AddressChannelPreset? tryParseAddress({
    required String name,
    required String text,
    required AddressProfileProtocolType protocolType,
  }) {
    final input = text.trim();
    final hasHexPrefix = input.startsWith('0x') || input.startsWith('0X');
    final digits = hasHexPrefix ? input.substring(2) : input;
    final isDecimal =
        protocolType == AddressProfileProtocolType.rProtocol && !hasHexPrefix;
    final pattern = isDecimal ? RegExp(r'^[0-9]+$') : RegExp(r'^[0-9a-fA-F]+$');
    if (!pattern.hasMatch(digits)) return null;

    final address = int.tryParse(digits, radix: isDecimal ? 10 : 16);
    if (address == null || address > 0xFFFFFFFF) return null;
    return AddressChannelPreset(
      name: name,
      address: address,
      addressFormat:
          isDecimal
              ? AddressValueFormat.decimal
              : AddressValueFormat.hexadecimal,
    );
  }

  /// 从JSON映射创建
  factory AddressChannelPreset.fromJson(Map<String, dynamic> json) {
    return AddressChannelPreset(
      name: json['name'] as String? ?? '',
      address: (json['address'] as num?)?.toInt() ?? 0,
      addressFormat: AddressValueFormat.fromJsonValue(json['addressFormat']),
    );
  }

  /// 转换为JSON映射
  Map<String, dynamic> toJson() => {
    'name': name,
    'address': address,
    'addressFormat': addressFormat.id,
  };

  String formatAddress({bool compactHex = false}) {
    final value = address & 0xFFFFFFFF;
    if (addressFormat == AddressValueFormat.decimal) return '$value';
    final digits = value.toRadixString(16).toUpperCase();
    return '0x${compactHex ? digits : digits.padLeft(8, '0')}';
  }

  AddressChannelPreset copyWith({
    String? name,
    int? address,
    AddressValueFormat? addressFormat,
  }) {
    return AddressChannelPreset(
      name: name ?? this.name,
      address: address ?? this.address,
      addressFormat: addressFormat ?? this.addressFormat,
    );
  }
}

/// Zobow/r 协议共用的地址配置文件。
class AddressConfigProfile {
  /// 配置所属协议。旧版 JSON 缺少该字段时默认按 Zobow 处理。
  AddressProfileProtocolType protocolType;

  /// 配置文件唯一标识（文件名，不含扩展名）
  String id;

  /// 配置文件显示名称
  String name;

  /// 预设列表（名称+地址键值对）
  List<AddressChannelPreset> presets;

  AddressConfigProfile({
    required this.id,
    required this.name,
    this.protocolType = AddressProfileProtocolType.zobow,
    List<AddressChannelPreset>? presets,
  }) : presets = presets ?? [];

  /// 创建默认空配置文件
  factory AddressConfigProfile.empty(
    String id, {
    String? name,
    AddressProfileProtocolType protocolType = AddressProfileProtocolType.zobow,
  }) {
    return AddressConfigProfile(
      id: id,
      name: name ?? '未命名配置',
      protocolType: protocolType,
      presets: [],
    );
  }

  /// 从JSON映射创建
  factory AddressConfigProfile.fromJson(Map<String, dynamic> json) {
    final presetsList =
        (json['presets'] as List<dynamic>?)
            ?.map(
              (e) => AddressChannelPreset.fromJson(e as Map<String, dynamic>),
            )
            .toList();
    return AddressConfigProfile(
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

  AddressConfigProfile copyWith({
    String? id,
    String? name,
    AddressProfileProtocolType? protocolType,
    List<AddressChannelPreset>? presets,
  }) {
    return AddressConfigProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      protocolType: protocolType ?? this.protocolType,
      presets: presets ?? List.from(this.presets),
    );
  }
}

/// 通道名称来自地址预设选择时的绑定信息。
///
/// 绑定只用于恢复“由配置项带入的名称”。用户手动修改地址时，如果当前
/// 地址不再匹配绑定地址，就会清空绑定和名称，避免旧名称残留到新地址。
class ChannelPresetBinding {
  AddressProfileProtocolType protocolType;
  int channelIndex;
  String addressKey;
  String name;
  String profileId;

  ChannelPresetBinding({
    required this.protocolType,
    required this.channelIndex,
    required this.addressKey,
    required this.name,
    required this.profileId,
  });

  factory ChannelPresetBinding.fromJson(Map<String, dynamic> json) {
    return ChannelPresetBinding(
      protocolType: AddressProfileProtocolType.fromJsonValue(
        json['protocolType'],
      ),
      channelIndex: (json['channelIndex'] as num?)?.toInt() ?? -1,
      addressKey: json['addressKey'] as String? ?? '',
      name: json['name'] as String? ?? '',
      profileId: json['profileId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'protocolType': protocolType.id,
    'channelIndex': channelIndex,
    'addressKey': addressKey,
    'name': name,
    'profileId': profileId,
  };
}
