/// Shell 页面的连接模式。
enum ShellConnectionMode {
  normal('normal', '普通'),
  ssh('ssh', 'SSH');

  const ShellConnectionMode(this.value, this.label);
  final String value;
  final String label;

  static ShellConnectionMode fromString(String? value) =>
      value == 'ssh' ? ssh : normal;
}

/// SSH 认证方式。
enum SshAuthenticationMode {
  password('password', '密码'),
  privateKey('privateKey', '私钥');

  const SshAuthenticationMode(this.value, this.label);
  final String value;
  final String label;

  static SshAuthenticationMode fromString(String? value) =>
      value == 'privateKey' ? privateKey : password;
}

/// SSH 连接参数。密码本身不进入该持久化模型，只记录是否从系统凭据库读取。
class SshConnectionConfig {
  const SshConnectionConfig({
    this.host = '127.0.0.1',
    this.port = 22,
    this.username = 'root',
    this.authenticationMode = SshAuthenticationMode.password,
    this.privateKeyPath = '',
    this.savePassword = false,
    this.keepAliveEnabled = true,
  });

  final String host;
  final int port;
  final String username;
  final SshAuthenticationMode authenticationMode;
  final String privateKeyPath;
  final bool savePassword;

  /// 是否启用 dartssh2 的 OpenSSH keepalive 请求；只参与当前连接，不写入连接 JSON。
  final bool keepAliveEnabled;

  String get endpointKey => '${host.trim().toLowerCase()}:$port';

  SshConnectionConfig copyWith({
    String? host,
    int? port,
    String? username,
    SshAuthenticationMode? authenticationMode,
    String? privateKeyPath,
    bool? savePassword,
    bool? keepAliveEnabled,
  }) => SshConnectionConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authenticationMode: authenticationMode ?? this.authenticationMode,
    privateKeyPath: privateKeyPath ?? this.privateKeyPath,
    savePassword: savePassword ?? this.savePassword,
    keepAliveEnabled: keepAliveEnabled ?? this.keepAliveEnabled,
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'authenticationMode': authenticationMode.value,
    'privateKeyPath': privateKeyPath,
    'savePassword': savePassword,
  };

  static SshConnectionConfig fromJson(Object? value) {
    final json = value is Map ? value : const <Object?, Object?>{};
    final host = '${json['host'] ?? ''}'.trim();
    final username = '${json['username'] ?? ''}'.trim();
    return SshConnectionConfig(
      host: host.isEmpty ? '127.0.0.1' : host,
      port: ((json['port'] as num?)?.toInt() ?? 22).clamp(1, 65535),
      username: username.isEmpty ? 'root' : username,
      authenticationMode: SshAuthenticationMode.fromString(
        json['authenticationMode'] as String?,
      ),
      privateKeyPath: '${json['privateKeyPath'] ?? ''}',
      savePassword: json['savePassword'] == true,
    );
  }
}

/// 已确认的 SSH 主机密钥，仅保存公开指纹。
class SshKnownHost {
  const SshKnownHost({required this.algorithm, required this.fingerprint});

  final String algorithm;
  final String fingerprint;

  Map<String, String> toJson() => {
    'algorithm': algorithm,
    'fingerprint': fingerprint,
  };

  static SshKnownHost? fromJson(Object? value) {
    if (value is! Map) return null;
    final algorithm = '${value['algorithm'] ?? ''}'.trim();
    final fingerprint = '${value['fingerprint'] ?? ''}'.trim();
    if (algorithm.isEmpty || fingerprint.isEmpty) return null;
    return SshKnownHost(algorithm: algorithm, fingerprint: fingerprint);
  }
}
