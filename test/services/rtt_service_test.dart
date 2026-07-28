import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/probe_plot_config.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_receive_queue.dart';
import 'package:vscope_serial/services/rtt_service.dart';

void main() {
  final owners = ConnectionOwnerService();

  setUp(() {
    owners.reset();
  });

  tearDown(() {
    owners.reset();
  });

  test('CMSIS-DAP 自动模式只使用 OpenOCD', () async {
    final openocd = _FakeBackend('external-openocd');
    final bundled = _FakeBackend('bundled-openocd');
    final service = RttService(
      connectionOwners: owners,
      backends: [openocd, bundled],
    );
    await service.connect(_config(kind: RttProbeKind.cmsisDap, openOcd: true));

    expect(openocd.connectCount, 1);
    expect(bundled.connectCount, 0);
    expect(owners.owner, ConnectionOwner.rtt);
    await service.disconnect();
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('CMSIS-DAP 自动模式找不到外置 OpenOCD 时回退内置版本', () async {
    final external = _FakeBackend('external-openocd', available: false);
    final bundled = _FakeBackend('bundled-openocd');
    final service = RttService(
      connectionOwners: owners,
      backends: [external, bundled],
    );

    await service.connect(_config(kind: RttProbeKind.cmsisDap, openOcd: true));

    expect(external.connectCount, 0);
    expect(bundled.connectCount, 1);
    await service.disconnect();
    service.dispose();
  });

  test('RTT Viewer 与 RTT 绘图开始时分别传递独立轮询间隔', () async {
    final settings = AppSettings();
    final previousViewerInterval = settings.rttViewerPollingIntervalMs;
    final previousPlotInterval = settings.probeRttPollingIntervalMs;
    settings
      ..rttViewerPollingIntervalMs = 25
      ..probeRttPollingIntervalMs = 40;
    final backend = _FakeBackend('external-openocd');
    final service = RttService(connectionOwners: owners, backends: [backend]);
    addTearDown(() async {
      settings
        ..rttViewerPollingIntervalMs = previousViewerInterval
        ..probeRttPollingIntervalMs = previousPlotInterval;
      await service.disconnect();
      service.dispose();
    });
    await service.connect(
      _config(
        backend: RttBackendSelection.externalOpenocd,
        kind: RttProbeKind.cmsisDap,
        openOcd: true,
      ),
    );

    await service.startRttViewer();
    expect(backend.lastRttConfig?.pollingIntervalMs, 25);
    await service.stopActivity();

    await service.startRttProbePlot('JScope_i4');
    expect(backend.lastRttConfig?.pollingIntervalMs, 40);
  });

  test('CMSIS-DAP 自动模式在 OpenOCD 配置不完整时拒绝连接', () async {
    final openocd = _FakeBackend('external-openocd');
    final service = RttService(connectionOwners: owners, backends: [openocd]);

    await expectLater(
      service.connect(_config(kind: RttProbeKind.cmsisDap)),
      throwsA(isA<RttBackendUnavailableException>()),
    );

    expect(openocd.connectCount, 0);
    service.dispose();
  });

  test('已选中的自动候选连接失败时不静默切换后端', () async {
    final external = _FakeBackend(
      'external-jlink',
      connectError: StateError('目标错误'),
    );
    final service = RttService(connectionOwners: owners, backends: [external]);
    await expectLater(service.connect(_config()), throwsStateError);

    expect(external.connectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('显式选择不能保证非侵入式访问的后端时在连接前拒绝', () async {
    final unsafe = _FakeBackend('external-jlink', nonIntrusive: false);
    final service = RttService(connectionOwners: owners, backends: [unsafe]);

    await expectLater(
      service.connect(_config(backend: RttBackendSelection.externalJlink)),
      throwsA(
        isA<RttBackendUnavailableException>().having(
          (error) => error.message,
          'message',
          contains('非侵入式安全要求'),
        ),
      ),
    );

    expect(unsafe.connectCount, 0);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('串口持有应用连接时拒绝 RTT 连接', () async {
    expect(owners.tryAcquire(ConnectionOwner.serial), isTrue);
    final service = RttService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink'),
        _FakeBackend('external-openocd'),
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
      backends: [external, _FakeBackend('external-openocd')],
    );
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

  test('运行中后端断线会停止活动、清理连接并释放占用', () async {
    final external = _FakeBackend('external-jlink');
    final service = RttService(connectionOwners: owners, backends: [external]);
    await service.connect(_config());
    await service.startRttViewer();

    external.dropConnection('调试探针的 USB 连接已中断');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(service.state, RttConnectionState.disconnected);
    expect(service.activityOwner, ProbeActivityOwner.none);
    expect(service.lastError, '调试探针的 USB 连接已中断');
    expect(external.disconnectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('后端检测结果包含已检测工具的版本号', () async {
    final service = RttService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink', version: 'v8.24a'),
        _FakeBackend('bundled-openocd', version: 'v0.12.0-bundled'),
        _FakeBackend('external-openocd', version: 'v0.12.0'),
      ],
    );

    final result = await service.checkBackendAvailability();

    expect(result['external-jlink']?.version, 'v8.24a');
    expect(result['bundled-openocd']?.version, 'v0.12.0-bundled');
    expect(result['external-openocd']?.version, 'v0.12.0');
    service.dispose();
  });

  test('OpenOCD 不可用时预期后端报告不可用', () async {
    final service = RttService(
      connectionOwners: owners,
      backends: [_FakeBackend('external-openocd', available: false)],
    );
    await expectLater(
      service.expectedBackendName(RttProbeKind.cmsisDap),
      throwsA(isA<RttBackendUnavailableException>()),
    );
    service.dispose();
  });

  test('清空接收缓存会重置队列、过载和接收字节统计', () async {
    final external = _FakeBackend('external-jlink');
    final service = RttService(
      connectionOwners: owners,
      receiveQueue: RttReceiveQueue(maxBytes: 4),
      backends: [external, _FakeBackend('external-openocd', available: false)],
    );
    await service.connect(_config(backend: RttBackendSelection.externalJlink));
    await service.startRttViewer();

    external.addData([1, 2, 3, 4, 5]);
    await Future<void>.delayed(Duration.zero);
    expect(service.droppedBytes, 5);

    external.addData([1, 2, 3]);
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

  test('连接后和停止后不接收数据，只有开始 RTT Viewer 后才进入队列', () async {
    final backend = _FakeBackend('external-jlink');
    final service = RttService(
      connectionOwners: owners,
      backends: [backend, _FakeBackend('external-openocd', available: false)],
    );

    await service.connect(_config());
    backend.addData([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    expect(service.receivedBytes, 0);
    expect(service.queuedBytes, 0);

    await service.startRttViewer();
    backend.addData([4, 5, 6]);
    await Future<void>.delayed(Duration.zero);
    expect(service.receivedBytes, 3);
    expect(service.queuedBytes, 3);

    service.clearBufferedData();
    await service.stopActivity();
    backend.addData([7, 8, 9]);
    await Future<void>.delayed(Duration.zero);
    expect(service.receivedBytes, 0);
    expect(service.queuedBytes, 0);

    await service.disconnect();
    service.dispose();
  });

  test('J-Link 停止时进入重连状态，完成后恢复空闲连接', () async {
    final stopGate = Completer<void>();
    final backend = _FakeBackend('external-jlink', stopGate: stopGate);
    final service = RttService(connectionOwners: owners, backends: [backend]);

    await service.connect(_config(backend: RttBackendSelection.externalJlink));
    await service.startRttViewer();
    final stopping = service.stopActivity();
    await Future<void>.delayed(Duration.zero);

    expect(service.state, RttConnectionState.reconnecting);
    expect(service.isReconnecting, isTrue);
    expect(service.activityOwner, ProbeActivityOwner.rttViewer);

    stopGate.complete();
    await stopping;

    expect(service.state, RttConnectionState.connected);
    expect(service.activityOwner, ProbeActivityOwner.none);
    expect(owners.owner, ConnectionOwner.rtt);
    await service.disconnect();
    service.dispose();
  });
}

RttConnectionConfig _config({
  RttBackendSelection backend = RttBackendSelection.automatic,
  RttProbeKind kind = RttProbeKind.jlink,
  bool openOcd = false,
}) => RttConnectionConfig(
  backend: backend,
  probeKind: kind,
  target: 'TEST',
  controlBlockMode:
      openOcd ? RttControlBlockMode.address : RttControlBlockMode.automatic,
  controlBlockAddress: openOcd ? 0x20000000 : null,
  openOcdInterfaceConfig: openOcd ? 'interface/cmsis-dap.cfg' : '',
  openOcdTargetConfig: openOcd ? 'target/test.cfg' : '',
);

class _FakeBackend
    implements
        RttBackend,
        RttBackendVersionProvider,
        RttBackendFailureProvider,
        RttActivityBackend,
        RttControlBlockConfigurable,
        ProbePlotBackend {
  _FakeBackend(
    this.id, {
    this.available = true,
    this.nonIntrusive = true,
    this.connectError,
    this.version,
    this.stopGate,
  });

  @override
  final String id;
  final bool available;
  final bool nonIntrusive;
  final Object? connectError;
  final String? version;
  final Completer<void>? stopGate;
  int connectCount = 0;
  int disconnectCount = 0;
  bool _connected = false;
  String? _lastFailure;
  final StreamController<RttDataChunk> _data =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();
  final StreamController<ProbeSampleChunk> _samples =
      StreamController<ProbeSampleChunk>.broadcast();
  RttControlBlockConfig? lastRttConfig;

  @override
  Stream<RttDataChunk> get dataStream => _data.stream;
  @override
  Stream<String> get diagnosticStream => _diagnostics.stream;
  @override
  String get displayName => id;
  @override
  bool get guaranteesNonIntrusiveTargetAccess => nonIntrusive;
  @override
  String? get nonIntrusiveSafetyBlockReason =>
      nonIntrusive ? null : '$displayName 不满足非侵入式安全要求';
  @override
  bool get isConnected => _connected;
  @override
  String? get lastFailure => _lastFailure;
  @override
  Set<RttBackendCapability> get capabilities => {
    RttBackendCapability.independentActivity,
    RttBackendCapability.downChannel0,
    RttBackendCapability.memorySampling,
  };
  @override
  Stream<ProbeSampleChunk> get sampleStream => _samples.stream;
  @override
  bool get supportsAutomaticControlBlock => true;
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
    _lastFailure = null;
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

  void dropConnection(String failure) {
    _lastFailure = failure;
    _connected = false;
    _diagnostics.add(failure);
  }

  @override
  Future<void> startRttViewer() async {}

  @override
  Future<void> configureRttControlBlock(RttControlBlockConfig config) async {
    lastRttConfig = config;
  }

  @override
  Future<List<ProbeSymbolInfo>> readSymbols(String path) async => const [];

  @override
  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) async {}

  @override
  Future<void> startRttPlot(String channelName) async {}

  @override
  Future<void> stopActivity() async {
    await stopGate?.future;
  }

  @override
  Future<void> writeDownChannel0(Uint8List data) async {}

  @override
  Future<void> dispose() async {
    await _data.close();
    await _diagnostics.close();
    await _samples.close();
  }
}
