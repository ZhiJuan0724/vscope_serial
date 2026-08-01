import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/app_logger.dart';
import '../data/models/ssh_connection_config.dart';
import 'connection_owner_service.dart';

enum SshConnectionState { disconnected, connecting, connected, disconnecting }

/// SSH 握手获得了尚未被用户信任或已经变化的主机密钥。
class SshHostKeyVerificationRequired implements Exception {
  const SshHostKeyVerificationRequired({
    required this.algorithm,
    required this.fingerprint,
    required this.changed,
  });

  final String algorithm;
  final String fingerprint;
  final bool changed;

  @override
  String toString() => changed ? 'SSH 主机密钥与已信任记录不一致' : '需要确认 SSH 主机密钥';
}

class SshConnectionSecrets {
  const SshConnectionSecrets({this.password, this.privateKeyPassphrase});
  final String? password;
  final String? privateKeyPassphrase;
}

/// 便于测试替换 dartssh2 的最小客户端边界。
abstract interface class SshClientAdapter {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  bool get shellOpen;

  Future<void> startShell({required int columns, required int rows});
  Future<void> stopShell();
  Future<void> write(Uint8List data);
  void resize(int columns, int rows, {int pixelWidth = 0, int pixelHeight = 0});
  Future<void> close();
}

typedef SshAdapterConnector =
    Future<SshClientAdapter> Function(
      SshConnectionConfig config,
      SshConnectionSecrets secrets,
      SshKnownHost? trustedHost,
    );

/// SSH 认证连接与 PTY Shell 生命周期。
class SshConnectionService extends ChangeNotifier {
  SshConnectionService({
    ConnectionOwnerService? connectionOwners,
    SshAdapterConnector? connector,
  }) : _connectionOwners = connectionOwners ?? ConnectionOwnerService(),
       _connector = connector ?? _connectDartSsh;

  final ConnectionOwnerService _connectionOwners;
  final SshAdapterConnector _connector;
  final StreamController<Uint8List> _dataController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();
  SshClientAdapter? _client;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  int _generation = 0;
  bool _disposed = false;

  SshConnectionState state = SshConnectionState.disconnected;
  SshConnectionConfig? activeConfig;
  SshConnectionSecrets? _lastSecrets;
  SshKnownHost? _trustedHost;

  Stream<Uint8List> get dataStream => _dataController.stream;
  Stream<Object> get errorStream => _errorController.stream;
  bool get isConnected => state == SshConnectionState.connected;
  bool get isConnecting => state == SshConnectionState.connecting;
  bool get isRunning => _client?.shellOpen ?? false;

  Future<void> connect(
    SshConnectionConfig config,
    SshConnectionSecrets secrets, {
    SshKnownHost? trustedHost,
  }) async {
    if (state != SshConnectionState.disconnected) return;
    if (!_connectionOwners.tryAcquire(ConnectionOwner.data)) {
      throw StateError('已有其他数据或探针连接，请先断开');
    }
    final generation = ++_generation;
    state = SshConnectionState.connecting;
    notifyListeners();
    try {
      final client = await _connector(config, secrets, trustedHost);
      if (generation != _generation) {
        await client.close();
        return;
      }
      _client = client;
      activeConfig = config;
      _lastSecrets = secrets;
      _trustedHost = trustedHost;
      _stdoutSubscription = client.stdout.listen(_dataController.add);
      _stderrSubscription = client.stderr.listen(_dataController.add);
      unawaited(
        client.done.then(
          (_) => _handleRemoteClosed(generation, null),
          onError:
              (Object error, StackTrace _) =>
                  _handleRemoteClosed(generation, error),
        ),
      );
      state = SshConnectionState.connected;
      AppLogger().info(
        'SSH 已连接：${config.host}:${config.port}',
        category: 'SSH',
      );
    } catch (_) {
      _connectionOwners.release(ConnectionOwner.data);
      state = SshConnectionState.disconnected;
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> reconnect() async {
    final config = activeConfig;
    final secrets = _lastSecrets;
    final trustedHost = _trustedHost;
    if (config == null || secrets == null) throw StateError('没有可重连的 SSH 参数');
    await disconnect();
    await connect(config, secrets, trustedHost: trustedHost);
  }

  Future<void> startShell({int columns = 80, int rows = 24}) async {
    final client = _client;
    if (client == null || !isConnected) throw StateError('SSH 尚未连接');
    if (client.shellOpen) return;
    await client.startShell(columns: columns, rows: rows);
    notifyListeners();
  }

  Future<void> stopShell() async {
    await _client?.stopShell();
    if (!_disposed) notifyListeners();
  }

  Future<void> write(Uint8List data) async {
    final client = _client;
    if (client == null || !client.shellOpen) throw StateError('SSH Shell 尚未开始');
    await client.write(data);
  }

  void resizeTerminal(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) => _client?.resize(
    columns,
    rows,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

  Future<void> disconnect() async {
    if (state == SshConnectionState.disconnected) return;
    final client = _client;
    ++_generation;
    state = SshConnectionState.disconnecting;
    notifyListeners();
    _client = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await client?.close();
    state = SshConnectionState.disconnected;
    _connectionOwners.release(ConnectionOwner.data);
    if (!_disposed) notifyListeners();
  }

  void _handleRemoteClosed(int generation, Object? error) {
    if (generation != _generation || _client == null) return;
    if (error != null) _errorController.add(error);
    unawaited(disconnect());
  }

  Future<void> shutdown() => disconnect();

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    unawaited(_dataController.close());
    unawaited(_errorController.close());
    super.dispose();
  }
}

Future<SshClientAdapter> _connectDartSsh(
  SshConnectionConfig config,
  SshConnectionSecrets secrets,
  SshKnownHost? trustedHost,
) async {
  String? receivedAlgorithm;
  String? receivedFingerprint;
  final identities =
      config.authenticationMode == SshAuthenticationMode.privateKey
          ? await _loadPrivateKey(
            config.privateKeyPath,
            secrets.privateKeyPassphrase,
          )
          : null;
  SSHClient? client;
  try {
    client = SSHClient(
      await SSHSocket.connect(
        config.host,
        config.port,
        timeout: const Duration(seconds: 8),
      ),
      username: config.username,
      identities: identities,
      onPasswordRequest:
          config.authenticationMode == SshAuthenticationMode.password
              ? () => secrets.password
              : null,
      onVerifyHostKey: (algorithm, fingerprintBytes) {
        receivedAlgorithm = algorithm;
        receivedFingerprint = utf8.decode(fingerprintBytes);
        return trustedHost != null &&
            trustedHost.algorithm == receivedAlgorithm &&
            trustedHost.fingerprint == receivedFingerprint;
      },
      handshakeTimeout: const Duration(seconds: 10),
      authTimeout: const Duration(seconds: 15),
      ident: 'SerialTools_1.0',
    );
    await client.authenticated;
    return _DartSshClientAdapter(client);
  } catch (error) {
    client?.close();
    final algorithm = receivedAlgorithm;
    final fingerprint = receivedFingerprint;
    if (algorithm != null && fingerprint != null) {
      throw SshHostKeyVerificationRequired(
        algorithm: algorithm,
        fingerprint: fingerprint,
        changed: trustedHost != null,
      );
    }
    rethrow;
  }
}

Future<List<SSHKeyPair>> _loadPrivateKey(
  String path,
  String? passphrase,
) async {
  if (path.trim().isEmpty) throw StateError('请选择 SSH 私钥文件');
  final pem = await File(path).readAsString();
  return Isolate.run(() => SSHKeyPair.fromPem(pem, passphrase));
}

class _DartSshClientAdapter implements SshClientAdapter {
  _DartSshClientAdapter(this._client);

  final SSHClient _client;
  final StreamController<Uint8List> _stdout = StreamController.broadcast();
  final StreamController<Uint8List> _stderr = StreamController.broadcast();
  SSHSession? _session;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _client.done;
  @override
  bool get shellOpen => _session != null;

  @override
  Future<void> startShell({required int columns, required int rows}) async {
    if (_session != null) return;
    final session = await _client.shell(
      pty: SSHPtyConfig(type: 'xterm-256color', width: columns, height: rows),
      environment: const {'TERM': 'xterm-256color'},
    );
    _session = session;
    _stdoutSubscription = session.stdout.listen(_stdout.add);
    _stderrSubscription = session.stderr.listen(_stderr.add);
    unawaited(session.done.whenComplete(() => stopShell()));
  }

  @override
  Future<void> stopShell() async {
    final session = _session;
    _session = null;
    session?.close();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  @override
  Future<void> write(Uint8List data) async {
    final session = _session;
    if (session == null) throw StateError('SSH Shell 尚未开始');
    session.write(data);
    await session.flush();
  }

  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    _session?.resizeTerminal(columns, rows, pixelWidth, pixelHeight);
  }

  @override
  Future<void> close() async {
    await stopShell();
    _client.close();
    await _stdout.close();
    await _stderr.close();
  }
}
