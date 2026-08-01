/// 数据收发和串口绘图支持的连接类型。
enum DataConnectionType {
  serial('serial', '串口'),
  tcpClient('tcpClient', 'TCP 客户端'),
  tcpServer('tcpServer', 'TCP 服务端'),
  udp('udp', 'UDP');

  const DataConnectionType(this.value, this.label);
  final String value;
  final String label;

  static DataConnectionType fromString(String? value) => switch (value) {
    'tcpClient' => tcpClient,
    'tcpServer' => tcpServer,
    'udp' => udp,
    _ => serial,
  };
}

/// 单个页面持久化的网络连接参数。
class NetworkConnectionConfig {
  const NetworkConnectionConfig({
    this.type = DataConnectionType.tcpClient,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.localPort,
  });

  final DataConnectionType type;
  final String host;
  final int port;
  final int? localPort;

  NetworkConnectionConfig copyWith({
    DataConnectionType? type,
    String? host,
    int? port,
    int? localPort,
    bool clearLocalPort = false,
  }) => NetworkConnectionConfig(
    type: type ?? this.type,
    host: host ?? this.host,
    port: port ?? this.port,
    localPort: clearLocalPort ? null : localPort ?? this.localPort,
  );

  Map<String, Object?> toJson() => {
    'type': type.value,
    'host': host,
    'port': port,
    'localPort': localPort,
  };

  static NetworkConnectionConfig fromJson(Object? value) {
    final json = value is Map ? value : const <Object?, Object?>{};
    final port = (json['port'] as num?)?.toInt() ?? 8080;
    final localPort = (json['localPort'] as num?)?.toInt();
    return NetworkConnectionConfig(
      type: DataConnectionType.fromString(json['type'] as String?),
      host:
          (json['host'] as String?)?.trim().isNotEmpty == true
              ? (json['host'] as String).trim()
              : '127.0.0.1',
      port: port.clamp(1, 65535),
      localPort: localPort?.clamp(1, 65535),
    );
  }
}
