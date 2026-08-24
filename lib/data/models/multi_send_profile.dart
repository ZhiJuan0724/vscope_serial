import 'dart:convert';

/// 普通收发页的可复用发送条目。
class MultiSendEntry {
  static const int minIntervalMs = 1;
  static const int maxIntervalMs = 3600000;

  final String id;
  final String name;
  final String content;
  final bool enabled;
  final bool isHex;

  /// 文本条目专用行尾；空字符串表示不追加。
  final String textLineEnding;
  final int intervalMs;

  const MultiSendEntry({
    required this.id,
    required this.name,
    required this.content,
    this.enabled = true,
    this.isHex = false,
    this.textLineEnding = '',
    this.intervalMs = 1000,
  });

  factory MultiSendEntry.fromJson(Map<String, dynamic> json) {
    return MultiSendEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名条目',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      isHex: json['isHex'] as bool? ?? false,
      textLineEnding: switch (json['textLineEnding'] as String?) {
        '\r' || '\n' || '\r\n' => json['textLineEnding'] as String,
        _ => '',
      },
      intervalMs: ((json['intervalMs'] as num?)?.toInt() ?? 1000).clamp(
        minIntervalMs,
        maxIntervalMs,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'content': content,
    'enabled': enabled,
    'isHex': isHex,
    'textLineEnding': textLineEnding,
    'intervalMs': intervalMs,
  };

  MultiSendEntry copyWith({
    String? id,
    String? name,
    String? content,
    bool? enabled,
    bool? isHex,
    String? textLineEnding,
    int? intervalMs,
  }) => MultiSendEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    content: content ?? this.content,
    enabled: enabled ?? this.enabled,
    isHex: isHex ?? this.isHex,
    textLineEnding: textLineEnding ?? this.textLineEnding,
    intervalMs: (intervalMs ?? this.intervalMs).clamp(
      minIntervalMs,
      maxIntervalMs,
    ),
  );
}

/// 可独立保存和导入的多条发送配置。
class MultiSendProfile {
  static const int formatVersion = 1;
  static const String documentType = 'vscope_multi_send_profile';

  final String id;
  final String name;
  final List<MultiSendEntry> entries;

  const MultiSendProfile({
    required this.id,
    required this.name,
    this.entries = const [],
  });

  factory MultiSendProfile.empty(String id, {String name = '新发送配置'}) =>
      MultiSendProfile(id: id, name: name);

  factory MultiSendProfile.fromJson(Map<String, dynamic> json) {
    if (json['type'] != documentType) {
      throw const FormatException('不是多条发送配置文件');
    }
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version < 1 || version > formatVersion) {
      throw const FormatException('不支持的多条发送配置版本');
    }
    final rawEntries = json['entries'];
    return MultiSendProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名配置',
      entries:
          rawEntries is List
              ? rawEntries
                  .whereType<Map>()
                  .map(
                    (item) => MultiSendEntry.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .toList()
              : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'type': documentType,
    'version': formatVersion,
    'id': id,
    'name': name,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  MultiSendProfile copyWith({
    String? id,
    String? name,
    List<MultiSendEntry>? entries,
  }) => MultiSendProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    entries: entries ?? this.entries,
  );
}
