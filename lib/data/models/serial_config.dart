/// 串口配置模型
abstract final class SerialParity {
  static const int none = 0;
  static const int odd = 1;
  static const int even = 2;
}

/// 串口打开所需的持久化参数，不包含连接句柄和临时状态。
class SerialConfig {
  String? port;
  int baudRate;
  int dataBits;
  int stopBits;
  int parity;
  bool rts;
  bool dtr;

  SerialConfig({
    this.port,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = SerialParity.none,
    this.rts = false,
    this.dtr = false,
  });

  SerialConfig copyWith({
    String? port,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
    bool? rts,
    bool? dtr,
  }) {
    return SerialConfig(
      port: port ?? this.port,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      stopBits: stopBits ?? this.stopBits,
      parity: parity ?? this.parity,
      rts: rts ?? this.rts,
      dtr: dtr ?? this.dtr,
    );
  }

  Map<String, Object?> toJson() => {
    'port': port,
    'baudRate': baudRate,
    'dataBits': dataBits,
    'stopBits': stopBits,
    'parity': parity,
    'rts': rts,
    'dtr': dtr,
  };

  static SerialConfig fromJson(Object? value, {SerialConfig? fallback}) {
    final base = fallback ?? SerialConfig();
    final json = value is Map ? value : const <Object?, Object?>{};
    return SerialConfig(
      port: json['port'] as String? ?? base.port,
      baudRate: (json['baudRate'] as num?)?.toInt() ?? base.baudRate,
      dataBits: (json['dataBits'] as num?)?.toInt() ?? base.dataBits,
      stopBits: (json['stopBits'] as num?)?.toInt() ?? base.stopBits,
      parity: (json['parity'] as num?)?.toInt() ?? base.parity,
      rts: json['rts'] as bool? ?? base.rts,
      dtr: json['dtr'] as bool? ?? base.dtr,
    );
  }
}
