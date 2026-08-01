import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/ssh_connection_config.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/ssh_connection_service.dart';

void main() {
  final owners = ConnectionOwnerService();

  setUp(owners.reset);
  tearDown(owners.reset);

  test('SSH 认证连接与 PTY Shell 启停相互独立', () async {
    final adapter = _FakeSshAdapter();
    final service = SshConnectionService(
      connectionOwners: owners,
      connector: (config, secrets, trustedHost) async => adapter,
    );
    addTearDown(service.dispose);

    await service.connect(
      const SshConnectionConfig(host: 'device.local'),
      const SshConnectionSecrets(password: 'secret'),
    );

    expect(service.isConnected, isTrue);
    expect(service.isRunning, isFalse);
    expect(owners.owner, ConnectionOwner.data);

    await service.startShell(columns: 120, rows: 40);
    expect(service.isRunning, isTrue);
    expect(adapter.lastColumns, 120);
    expect(adapter.lastRows, 40);

    await service.write(Uint8List.fromList([1, 2, 3]));
    expect(adapter.writes.single, [1, 2, 3]);

    await service.stopShell();
    expect(service.isConnected, isTrue);
    expect(service.isRunning, isFalse);

    await service.disconnect();
    expect(service.isConnected, isFalse);
    expect(owners.owner, ConnectionOwner.none);
  });

  test('已有探针连接时 SSH 在调用连接器前拒绝', () async {
    owners.tryAcquire(ConnectionOwner.probe);
    var connectorCalled = false;
    final service = SshConnectionService(
      connectionOwners: owners,
      connector: (config, secrets, trustedHost) async {
        connectorCalled = true;
        return _FakeSshAdapter();
      },
    );
    addTearDown(service.dispose);

    await expectLater(
      service.connect(
        const SshConnectionConfig(),
        const SshConnectionSecrets(password: 'secret'),
      ),
      throwsStateError,
    );
    expect(connectorCalled, isFalse);
  });

  test('SSH 配置不序列化密码并规范化端口', () {
    final config = SshConnectionConfig.fromJson({
      'host': ' device ',
      'port': 70000,
      'username': ' user ',
      'authenticationMode': 'privateKey',
      'privateKeyPath': r'C:\keys\id_ed25519',
      'password': 'must-not-survive',
    });

    expect(config.host, 'device');
    expect(config.port, 65535);
    expect(config.username, 'user');
    expect(config.authenticationMode, SshAuthenticationMode.privateKey);
    expect(config.toJson().containsKey('password'), isFalse);
  });
}

class _FakeSshAdapter implements SshClientAdapter {
  final StreamController<Uint8List> _stdout = StreamController.broadcast();
  final StreamController<Uint8List> _stderr = StreamController.broadcast();
  final Completer<void> _done = Completer<void>();
  final List<List<int>> writes = [];
  int? lastColumns;
  int? lastRows;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Future<void> get done => _done.future;
  @override
  bool shellOpen = false;

  @override
  Future<void> startShell({required int columns, required int rows}) async {
    shellOpen = true;
    lastColumns = columns;
    lastRows = rows;
  }

  @override
  Future<void> stopShell() async => shellOpen = false;

  @override
  Future<void> write(Uint8List data) async => writes.add(data.toList());

  @override
  void resize(
    int columns,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    lastColumns = columns;
    lastRows = rows;
  }

  @override
  Future<void> close() async {
    shellOpen = false;
    if (!_done.isCompleted) _done.complete();
    await _stdout.close();
    await _stderr.close();
  }
}
