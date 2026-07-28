import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/probe_plot_config.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/viewmodels/probe_plot_viewmodel.dart';
import 'package:vscope_serial/views/plot/plot_render_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final owners = ConnectionOwnerService();

  setUp(owners.reset);
  tearDown(owners.reset);

  test('首次开始自动选择 J-Scope Up 通道并忽略其他 Up 数据', () async {
    final backend = _PlotBackend();
    final service = RttService(connectionOwners: owners, backends: [backend]);
    final viewModel = ProbePlotViewModel(service);
    var notifications = 0;
    viewModel.addListener(() => notifications++);

    await service.connect(
      const RttConnectionConfig(
        backend: RttBackendSelection.externalOpenocd,
        probeKind: RttProbeKind.cmsisDap,
        target: '',
      ),
    );
    expect(notifications, greaterThan(0));
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.activeChannelCount, 2);

    // 不打开设置弹窗、不重复切换 HSS/RTT，首次点击即读取控制块元数据。
    await viewModel.start();
    expect(backend.startedChannel, 'JScope_i4u4');
    expect(viewModel.rttChannelName, 'JScope_i4u4');
    expect(viewModel.running, isTrue);

    // Up 0 文本恰好也是一个 i4u4 包长，若未按通道过滤会产生伪样本。
    backend.addRtt(0, Uint8List.fromList('ABCDEFGH'.codeUnits));
    final packet =
        ByteData(8)
          ..setInt32(0, -123, Endian.little)
          ..setUint32(4, 42, Endian.little);
    backend.addRtt(1, packet.buffer.asUint8List());
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.pointCount, 1);
    expect(viewModel.points.single.values, [-123, 42]);
    expect(viewModel.activeChannelCount, 2);

    viewModel.setVCursorEnabled(true);
    viewModel.updateCursor(
      CursorState(x: 0.2, screenPosition: const Offset(100, 100)),
    );
    expect(viewModel.cursor?.x, 0);
    expect(viewModel.cursor?.channelValues, [-123, 42]);

    final zoomed = viewModel.viewport.zoomX(
      0.8,
      viewModel.viewport.xMin + viewModel.viewport.xRange / 2,
    );
    viewModel.updateViewport(zoomed);
    expect(viewModel.follow, isTrue);
    final draggedZoom = viewModel.viewport.zoomY(
      0.8,
      viewModel.viewport.yMin + viewModel.viewport.yRange / 2,
    );
    viewModel.updateViewport(draggedZoom, fromDrag: true);
    expect(viewModel.follow, isTrue);
    final dragged = viewModel.viewport.panX(20, 1000);
    viewModel.updateViewport(dragged, fromDrag: true);
    expect(viewModel.follow, isFalse);

    await viewModel.stop();
    expect(viewModel.running, isFalse);
    expect(viewModel.operationPending, isFalse);

    await viewModel.start();
    expect(viewModel.pointCount, 0);
    await viewModel.stop();

    viewModel.dispose();
    await service.disconnect();
    service.dispose();
  });

  test('HSS 每组采样按包序号递增且通道数量与 ELF 变量一致', () async {
    final backend = _PlotBackend();
    final service = RttService(connectionOwners: owners, backends: [backend]);
    final viewModel = ProbePlotViewModel(service)..setMode(ProbePlotMode.hss);

    viewModel.addHssVariable(
      const ProbeSampleVariable(
        name: 'speed',
        address: 0x20000000,
        type: ProbeScalarType.float32,
      ),
    );
    viewModel.addHssVariable(
      const ProbeSampleVariable(
        name: 'counter',
        address: 0x20000004,
        type: ProbeScalarType.uint32,
      ),
    );

    expect(viewModel.activeChannelCount, 2);
    expect(viewModel.channels.take(2).map((item) => item.alias), [
      'speed',
      'counter',
    ]);

    await service.connect(
      const RttConnectionConfig(
        backend: RttBackendSelection.externalOpenocd,
        probeKind: RttProbeKind.cmsisDap,
        target: '',
      ),
    );
    await viewModel.start();
    backend
      ..addSample(1000, [1, 10])
      ..addSample(2000, [2, 20])
      ..addSample(3000, [3, 30]);
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.points.map((point) => point.index), [0, 1, 2]);
    expect(viewModel.minJumpPacketIndex, 0);
    expect(viewModel.maxJumpPacketIndex, 2);
    viewModel.jumpToPacketIndex(1);
    expect(
      viewModel.viewport.xMin + viewModel.viewport.xRange / 2,
      closeTo(1, 1e-9),
    );
    expect(viewModel.follow, isTrue);

    viewModel.setVCursorEnabled(true);
    final dataRevision = viewModel.revision;
    final oldOverlayRevision = viewModel.overlayRevision;
    var cursorNotifications = 0;
    void countCursorNotification() => cursorNotifications++;
    viewModel.addListener(countCursorNotification);
    for (var index = 0; index < 1000; index++) {
      viewModel.updateCursor(
        CursorState(
          x: (index % 3).toDouble(),
          screenPosition: Offset(index.toDouble(), 100),
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    viewModel.removeListener(countCursorNotification);
    expect(viewModel.revision, dataRevision);
    expect(viewModel.overlayRevision, greaterThan(oldOverlayRevision));
    expect(cursorNotifications, lessThanOrEqualTo(2));
    expect(viewModel.cursor?.x, 0);

    await viewModel.stop();
    viewModel.removeHssVariable(0);
    expect(viewModel.activeChannelCount, 1);
    expect(viewModel.channels.first.alias, 'counter');

    viewModel.dispose();
    await service.disconnect();
    service.dispose();
  });

  test('RTT 绘图断开后保留历史数据与活动通道数量', () async {
    final backend = _PlotBackend();
    final service = RttService(connectionOwners: owners, backends: [backend]);
    final viewModel = ProbePlotViewModel(service);

    await service.connect(
      const RttConnectionConfig(
        backend: RttBackendSelection.externalOpenocd,
        probeKind: RttProbeKind.cmsisDap,
        target: '',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await viewModel.start();

    final packet =
        ByteData(8)
          ..setInt32(0, 123, Endian.little)
          ..setUint32(4, 456, Endian.little);
    backend.addRtt(1, packet.buffer.asUint8List());
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.pointCount, 1);
    expect(viewModel.activeChannelCount, 2);

    await service.disconnect();

    expect(viewModel.running, isFalse);
    expect(viewModel.pointCount, 1);
    expect(viewModel.points.single.values, [123, 456]);
    expect(viewModel.activeChannelCount, 2);

    viewModel.dispose();
    service.dispose();
  });
}

class _PlotBackend
    implements
        RttBackend,
        RttActivityBackend,
        ProbePlotBackend,
        RttChannelMetadataProvider {
  final StreamController<RttDataChunk> _data =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();
  final StreamController<ProbeSampleChunk> _samples =
      StreamController<ProbeSampleChunk>.broadcast();
  bool _connected = false;
  String? startedChannel;

  @override
  String get id => 'external-openocd';
  @override
  String get displayName => 'OpenOCD test';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get isConnected => _connected;
  @override
  Stream<RttDataChunk> get dataStream => _data.stream;
  @override
  Stream<String> get diagnosticStream => _diagnostics.stream;
  @override
  Stream<ProbeSampleChunk> get sampleStream => _samples.stream;
  @override
  Set<RttBackendCapability> get capabilities => {
    RttBackendCapability.independentActivity,
    RttBackendCapability.memorySampling,
    RttBackendCapability.channelMetadata,
  };

  @override
  Future<bool> isAvailable(RttProbeKind kind) async => true;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];
  @override
  Future<void> connect(RttConnectionConfig config) async => _connected = true;
  @override
  Future<void> disconnect() async => _connected = false;
  @override
  Future<void> startRttViewer() async {}
  @override
  Future<void> stopActivity() async {}
  @override
  Future<void> writeDownChannel0(Uint8List data) async {}
  @override
  Future<List<ProbeSymbolInfo>> readSymbols(String path) async => const [];
  @override
  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) async {}
  @override
  Future<void> startRttPlot(String channelName) async {
    startedChannel = channelName;
  }

  @override
  Future<List<RttChannelInfo>> listRttUpChannels() async => const [
    RttChannelInfo(index: 0, name: 'Terminal', size: 1024, flags: 0),
    RttChannelInfo(index: 1, name: 'JScope_i4u4', size: 4096, flags: 0),
  ];

  void addRtt(int channel, Uint8List data) {
    _data.add(
      RttDataChunk(
        channel: channel,
        data: data,
        monotonicUs: 1,
        wallClockUs: 1,
      ),
    );
  }

  void addSample(int monotonicUs, List<num> values) {
    _samples.add(
      ProbeSampleChunk(
        monotonicUs: monotonicUs,
        values: Float64List.fromList(
          values.map((value) => value.toDouble()).toList(),
        ),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _data.close();
    await _diagnostics.close();
    await _samples.close();
  }
}
