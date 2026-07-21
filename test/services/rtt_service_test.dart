import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_receive_queue.dart';
import 'package:vscope_serial/services/rtt_service.dart';

void main() {
  final owners = ConnectionOwnerService();
  late String previousMode;

  setUp(() {
    owners.reset();
    previousMode = AppSettings().rttBackendMode;
  });

  tearDown(() {
    AppSettings().rttBackendMode = previousMode;
    owners.reset();
  });

  test('自动模式仅在外部后端不可用时回退内置后端', () async {
    final external = _FakeBackend('external-jlink', available: false);
    final pyocd = _FakeBackend('external-pyocd', available: false);
    final builtin = _FakeBackend('builtin-probe-rs');
    final service = RttService(
      connectionOwners: owners,
      backends: [external, pyocd, builtin],
    );
    AppSettings().rttBackendMode = RttBackendMode.automatic.value;

    await service.connect(_config());

    expect(builtin.connectCount, 1);
    expect(external.connectCount, 0);
    expect(owners.owner, ConnectionOwner.rtt);
    await service.disconnect();
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('外部后端存在但连接失败时不静默回退内置后端', () async {
    final external = _FakeBackend(
      'external-jlink',
      connectError: StateError('目标错误'),
    );
    final builtin = _FakeBackend('builtin-probe-rs');
    final service = RttService(
      connectionOwners: owners,
      backends: [
        external,
        _FakeBackend('external-pyocd', available: false),
        builtin,
      ],
    );
    AppSettings().rttBackendMode = RttBackendMode.automatic.value;

    await expectLater(service.connect(_config()), throwsStateError);

    expect(external.connectCount, 1);
    expect(builtin.connectCount, 0);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('串口持有应用连接时拒绝 RTT 连接', () async {
    expect(owners.tryAcquire(ConnectionOwner.serial), isTrue);
    final service = RttService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink'),
        _FakeBackend('external-pyocd'),
        _FakeBackend('builtin-probe-rs'),
      ],
    );

    await expectLater(service.connect(_config()), throwsStateError);
    expect(owners.owner, ConnectionOwner.serial);
    service.dispose();
  });

  test('活动连接期间刷新探针不会伪造断开状态', () async {
    final external = _FakeBackend('external-jlink');
    final service = RttService(
      connectionOwners: owners,
      backends: [
        external,
        _FakeBackend('external-pyocd'),
        _FakeBackend('builtin-probe-rs'),
      ],
    );
    AppSettings().rttBackendMode = RttBackendMode.automatic.value;

    await service.connect(_config());
    await service.listProbes(RttProbeKind.jlink);

    expect(service.isConnected, isTrue);
    expect(owners.owner, ConnectionOwner.rtt);
    expect(external.disconnectCount, 0);

    await service.disconnect();
    expect(external.disconnectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('后端检测结果包含已检测工具的版本号', () async {
    final service = RttService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink', version: 'v8.24a'),
        _FakeBackend('external-pyocd', version: 'v0.44.0'),
        _FakeBackend('builtin-probe-rs', version: 'v1.0.0'),
      ],
    );

    final result = await service.checkBackendAvailability();

    expect(result['external-jlink']?.version, 'v8.24a');
    expect(result['external-pyocd']?.version, 'v0.44.0');
    expect(result['builtin-probe-rs']?.version, 'v1.0.0');
    service.dispose();
  });

  test('预期后端与自动模式正式连接使用相同的回退规则', () async {
    final service = RttService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink', available: false),
        _FakeBackend('external-pyocd', available: false),
        _FakeBackend('builtin-probe-rs'),
      ],
    );
    AppSettings().rttBackendMode = RttBackendMode.automatic.value;

    expect(
      await service.expectedBackendName(RttProbeKind.jlink),
      'builtin-probe-rs',
    );
    service.dispose();
  });

  test('清空接收缓存会重置队列、过载和接收字节统计', () async {
    final builtin = _FakeBackend('builtin-probe-rs');
    final service = RttService(
      connectionOwners: owners,
      receiveQueue: RttReceiveQueue(maxBytes: 4),
      backends: [
        _FakeBackend('external-jlink', available: false),
        _FakeBackend('external-pyocd', available: false),
        builtin,
      ],
    );
    AppSettings().rttBackendMode = RttBackendMode.builtin.value;
    await service.connect(_config());

    builtin.addData([1, 2, 3, 4, 5]);
    await Future<void>.delayed(Duration.zero);
    expect(service.droppedBytes, 5);

    builtin.addData([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    expect(service.queuedBytes, 3);
    expect(service.receivedBytes, 8);

    service.clearBufferedData();

    expect(service.queuedBytes, 0);
    expect(service.droppedBytes, 0);
    expect(service.receivedBytes, 0);
    await service.disconnect();
    service.dispose();
  });
}

RttConnectionConfig _config() =>
    const RttConnectionConfig(probeKind: RttProbeKind.jlink, target: 'TEST');

class _FakeBackend implements RttBackend, RttBackendVersionProvider {
  _FakeBackend(
    this.id, {
    this.available = true,
    this.connectError,
    this.version,
  });

  @override
  final String id;
  final bool available;
  final Object? connectError;
  final String? version;
  int connectCount = 0;
  int disconnectCount = 0;
  bool _connected = false;
  final StreamController<RttDataChunk> _data =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();

  @override
  Stream<RttDataChunk> get dataStream => _data.stream;
  @override
  Stream<String> get diagnosticStream => _diagnostics.stream;
  @override
  String get displayName => id;
  @override
  bool get isConnected => _connected;
  @override
  Future<bool> isAvailable(RttProbeKind kind) async => available;
  @override
  Future<String?> detectVersion(RttProbeKind kind) async => version;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];

  @override
  Future<void> connect(RttConnectionConfig config) async {
    connectCount++;
    if (connectError case final error?) throw error;
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    _connected = false;
  }

  void addData(List<int> bytes) {
    _data.add(
      RttDataChunk(
        channel: 0,
        data: Uint8List.fromList(bytes),
        monotonicUs: 1,
        wallClockUs: DateTime.now().microsecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _data.close();
    await _diagnostics.close();
  }
}
