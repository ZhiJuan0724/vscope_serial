import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/probe_plot_config.dart';
import 'package:vscope_serial/data/models/probe_connection_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/probe_backend.dart';
import 'package:vscope_serial/services/rtt_receive_queue.dart';
import 'package:vscope_serial/services/probe_connection_service.dart';

void main() {
  test('快捷连接参数恢复最近配置并按显式后端约束探针类型', () {
    final settings =
        AppSettings()
          ..rttBackendSelection = ProbeBackendSelection.externalOpenocd.value
          ..rttProbeKind = ProbeKind.jlink.value
          ..rttLastProbeId = 'CMSIS-DAP-V2'
          ..rttTarget = 'stm32f407zgtx'
          ..rttAutoDetectTarget = true
          ..rttWireProtocol = ProbeWireProtocol.jtag.value
          ..rttClockKhz = 8000
          ..rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg'
          ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg'
          ..rttPyocdCmsisDapVersion = PyOcdCmsisDapVersion.v2.value;

    final config = savedProbeConnectionConfig(settings);

    expect(config.backend, ProbeBackendSelection.externalOpenocd);
    expect(config.probeKind, ProbeKind.cmsisDap);
    expect(config.probeId, 'CMSIS-DAP-V2');
    expect(config.target, 'stm32f407zgtx');
    expect(config.autoDetectTarget, isTrue);
    expect(config.wireProtocol, ProbeWireProtocol.jtag);
    expect(config.clockKhz, 8000);
    expect(config.openOcdTargetConfig, 'target/stm32f4x.cfg');
    expect(config.pyOcdCmsisDapVersion, PyOcdCmsisDapVersion.v2);
  });

  final owners = ConnectionOwnerService();

  setUp(() {
    owners.reset();
  });

  tearDown(() {
    owners.reset();
  });

  test('CMSIS-DAP 自动模式优先使用外置 OpenOCD', () async {
    final openocd = _FakeBackend('external-openocd');
    final bundled = _FakeBackend('bundled-openocd');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [openocd, bundled],
    );
    await service.connect(_config(kind: ProbeKind.cmsisDap, openOcd: true));

    expect(openocd.connectCount, 1);
    expect(bundled.connectCount, 0);
    expect(owners.owner, ConnectionOwner.probe);
    await service.disconnect();
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('两个 OpenOCD 候选不可用时自动回退外置 pyOCD', () async {
    final external = _FakeBackend('external-openocd', available: false);
    final bundled = _FakeBackend('bundled-openocd', available: false);
    final pyocd = _FakeBackend('external-pyocd');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [external, bundled, pyocd],
    );

    await service.connect(_config(kind: ProbeKind.cmsisDap, openOcd: true));

    expect(external.connectCount, 0);
    expect(bundled.connectCount, 0);
    expect(pyocd.connectCount, 1);
    await service.disconnect();
    service.dispose();
  });

  test('OpenOCD 配置不完整时自动模式可以直接选择外置 pyOCD', () async {
    final external = _FakeBackend('external-openocd');
    final bundled = _FakeBackend('bundled-openocd');
    final pyocd = _FakeBackend('external-pyocd');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [external, bundled, pyocd],
    );

    await service.connect(_config(kind: ProbeKind.cmsisDap));

    expect(external.connectCount, 0);
    expect(bundled.connectCount, 0);
    expect(pyocd.connectCount, 1);
    await service.disconnect();
    service.dispose();
  });

  test('显式选择外置 pyOCD 时不会尝试 OpenOCD', () async {
    final openocd = _FakeBackend('external-openocd');
    final pyocd = _FakeBackend('external-pyocd');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [openocd, pyocd],
    );

    await service.connect(
      _config(
        backend: ProbeBackendSelection.externalPyocd,
        kind: ProbeKind.cmsisDap,
      ),
    );

    expect(openocd.connectCount, 0);
    expect(pyocd.connectCount, 1);
    await service.disconnect();
    service.dispose();
  });

  test('CMSIS-DAP 自动模式找不到外置 OpenOCD 时回退内置版本', () async {
    final external = _FakeBackend('external-openocd', available: false);
    final bundled = _FakeBackend('bundled-openocd');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [external, bundled],
    );

    await service.connect(_config(kind: ProbeKind.cmsisDap, openOcd: true));

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
    final service = ProbeConnectionService(connectionOwners: owners, backends: [backend]);
    addTearDown(() async {
      settings
        ..rttViewerPollingIntervalMs = previousViewerInterval
        ..probeRttPollingIntervalMs = previousPlotInterval;
      await service.disconnect();
      service.dispose();
    });
    await service.connect(
      _config(
        backend: ProbeBackendSelection.externalOpenocd,
        kind: ProbeKind.cmsisDap,
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
    final service = ProbeConnectionService(connectionOwners: owners, backends: [openocd]);

    await expectLater(
      service.connect(_config(kind: ProbeKind.cmsisDap)),
      throwsA(isA<ProbeBackendUnavailableException>()),
    );

    expect(openocd.connectCount, 0);
    service.dispose();
  });

  test('已选中的自动候选连接失败时不静默切换后端', () async {
    final external = _FakeBackend(
      'external-jlink',
      connectError: StateError('目标错误'),
    );
    final service = ProbeConnectionService(connectionOwners: owners, backends: [external]);
    await expectLater(service.connect(_config()), throwsStateError);

    expect(external.connectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('连接中断开按取消收敛且不记录连接失败', () async {
    final connectGate = Completer<void>();
    final backend = _FakeBackend('external-jlink', connectGate: connectGate);
    final service = ProbeConnectionService(connectionOwners: owners, backends: [backend]);

    final connecting = service.connect(
      _config(backend: ProbeBackendSelection.externalJlink),
    );
    while (backend.connectCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await service.disconnect();

    await expectLater(connecting, throwsA(anything));
    expect(service.state, ProbeConnectionState.disconnected);
    expect(service.lastError, isNull);
    expect(owners.owner, ConnectionOwner.none);
    await service.shutdown();
  });

  test('shutdown 等待后端异步释放完成', () async {
    final disposeGate = Completer<void>();
    final backend = _FakeBackend('external-jlink', disposeGate: disposeGate);
    final service = ProbeConnectionService(connectionOwners: owners, backends: [backend]);
    var completed = false;

    final shutdown = service.shutdown().then((_) => completed = true);
    while (!backend.disposeStarted) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(completed, isFalse);

    disposeGate.complete();
    await shutdown;
    expect(completed, isTrue);
  });

  test('显式选择不能保证非侵入式访问的后端时在连接前拒绝', () async {
    final unsafe = _FakeBackend('external-jlink', nonIntrusive: false);
    final service = ProbeConnectionService(connectionOwners: owners, backends: [unsafe]);

    await expectLater(
      service.connect(_config(backend: ProbeBackendSelection.externalJlink)),
      throwsA(
        isA<ProbeBackendUnavailableException>().having(
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
    expect(owners.tryAcquire(ConnectionOwner.data), isTrue);
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [
        _FakeBackend('external-jlink'),
        _FakeBackend('external-openocd'),
      ],
    );

    await expectLater(service.connect(_config()), throwsStateError);
    expect(owners.owner, ConnectionOwner.data);
    service.dispose();
  });

  test('活动连接期间刷新探针不会伪造断开状态', () async {
    final external = _FakeBackend('external-jlink');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [external, _FakeBackend('external-openocd')],
    );
    await service.connect(_config());
    await service.listProbes(ProbeKind.jlink);

    expect(service.isConnected, isTrue);
    expect(owners.owner, ConnectionOwner.probe);
    expect(external.disconnectCount, 0);

    await service.disconnect();
    expect(external.disconnectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('运行中后端断线会停止活动、清理连接并释放占用', () async {
    final external = _FakeBackend('external-jlink');
    final service = ProbeConnectionService(connectionOwners: owners, backends: [external]);
    await service.connect(_config());
    await service.startRttViewer();

    external.dropConnection('调试探针的 USB 连接已中断');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(service.state, ProbeConnectionState.disconnected);
    expect(service.activityOwner, ProbeActivityOwner.none);
    expect(service.lastError, '调试探针的 USB 连接已中断');
    expect(external.disconnectCount, 1);
    expect(owners.owner, ConnectionOwner.none);
    service.dispose();
  });

  test('后端检测结果包含已检测工具的版本号', () async {
    final service = ProbeConnectionService(
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
    final service = ProbeConnectionService(
      connectionOwners: owners,
      backends: [_FakeBackend('external-openocd', available: false)],
    );
    await expectLater(
      service.expectedBackendName(ProbeKind.cmsisDap),
      throwsA(isA<ProbeBackendUnavailableException>()),
    );
    service.dispose();
  });

  test('清空接收缓存会重置队列、过载和接收字节统计', () async {
    final external = _FakeBackend('external-jlink');
    final service = ProbeConnectionService(
      connectionOwners: owners,
      receiveQueue: RttReceiveQueue(maxBytes: 4),
      backends: [external, _FakeBackend('external-openocd', available: false)],
    );
    await service.connect(_config(backend: ProbeBackendSelection.externalJlink));
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
    final service = ProbeConnectionService(
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
    final service = ProbeConnectionService(connectionOwners: owners, backends: [backend]);

    await service.connect(_config(backend: ProbeBackendSelection.externalJlink));
    await service.startRttViewer();
    final stopping = service.stopActivity();
    await Future<void>.delayed(Duration.zero);

    expect(service.state, ProbeConnectionState.reconnecting);
    expect(service.isReconnecting, isTrue);
    expect(service.activityOwner, ProbeActivityOwner.rttViewer);

    stopGate.complete();
    await stopping;

    expect(service.state, ProbeConnectionState.connected);
    expect(service.activityOwner, ProbeActivityOwner.none);
    expect(owners.owner, ConnectionOwner.probe);
    await service.disconnect();
    service.dispose();
  });
}

ProbeConnectionConfig _config({
  ProbeBackendSelection backend = ProbeBackendSelection.automatic,
  ProbeKind kind = ProbeKind.jlink,
  bool openOcd = false,
}) => ProbeConnectionConfig(
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
        ProbeBackend,
        ProbeBackendVersionProvider,
        ProbeBackendFailureProvider,
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
    this.connectGate,
    this.disposeGate,
  });

  @override
  final String id;
  final bool available;
  final bool nonIntrusive;
  final Object? connectError;
  final String? version;
  final Completer<void>? stopGate;
  final Completer<void>? connectGate;
  final Completer<void>? disposeGate;
  int connectCount = 0;
  int disconnectCount = 0;
  bool disposeStarted = false;
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
  Set<ProbeBackendCapability> get capabilities => {
    ProbeBackendCapability.independentActivity,
    ProbeBackendCapability.downChannel0,
    ProbeBackendCapability.memorySampling,
  };
  @override
  Stream<ProbeSampleChunk> get sampleStream => _samples.stream;
  @override
  bool get supportsAutomaticControlBlock => true;
  @override
  Future<bool> isAvailable(ProbeKind kind) async => available;
  @override
  Future<String?> detectVersion(ProbeKind kind) async => version;
  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async => const [];
  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) async => const [];

  @override
  Future<void> connect(ProbeConnectionConfig config) async {
    connectCount++;
    if (connectError case final error?) throw error;
    await connectGate?.future;
    _lastFailure = null;
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    if (connectGate case final gate? when !gate.isCompleted) gate.complete();
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
    disposeStarted = true;
    await disposeGate?.future;
    await _data.close();
    await _diagnostics.close();
    await _samples.close();
  }
}
