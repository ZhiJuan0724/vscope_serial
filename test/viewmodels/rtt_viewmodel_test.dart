import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_receive_queue.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/viewmodels/rtt_viewmodel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _DataBackend backend;
  late RttService service;
  late RttViewModel viewModel;
  late String previousEncoding;
  late String previousMode;

  setUp(() async {
    ConnectionOwnerService().reset();
    previousEncoding = AppSettings().rttEncoding;
    previousMode = AppSettings().rttDisplayMode;
    AppSettings()
      ..rttBackendMode = RttBackendMode.builtin.value
      ..rttEncoding = 'UTF-8'
      ..rttDisplayMode = RttDisplayMode.text.value;
    backend = _DataBackend();
    service = RttService(
      receiveQueue: RttReceiveQueue(maxBytes: 1024),
      backends: [
        _UnavailableBackend('external-jlink'),
        _UnavailableBackend('external-pyocd'),
        backend,
      ],
    );
    viewModel = RttViewModel(service);
    await service.connect(
      const RttConnectionConfig(probeKind: RttProbeKind.jlink, target: 'TEST'),
    );
  });

  tearDown(() async {
    viewModel.dispose();
    await service.disconnect();
    service.dispose();
    AppSettings()
      ..rttEncoding = previousEncoding
      ..rttDisplayMode = previousMode;
    ConnectionOwnerService().reset();
  });

  test('UTF-8 字符跨块解码且无换行尾部也立即可见', () async {
    final bytes = utf8.encode('中文');
    backend.add(bytes.sublist(0, 2));
    backend.add(bytes.sublist(2));
    await _settleTimers();

    expect(viewModel.lines, isEmpty);
    expect(viewModel.partialLine, '中文');
  });

  test('暂停只冻结显示，恢复后展示暂停期间收到的数据', () async {
    backend.add(utf8.encode('first\n'));
    await _settleTimers();
    viewModel.togglePaused();

    backend.add(utf8.encode('second\n'));
    await _settleTimers();

    expect(viewModel.lines, ['first']);
    expect(viewModel.pausedBytes, greaterThan(0));
    viewModel.togglePaused();
    expect(viewModel.lines, ['first', 'second']);
  });

  test('切换 HEX 后按批次从原始历史重建', () async {
    backend.add([0x41, 0x42]);
    await _settleTimers();

    viewModel.setDisplayMode(RttDisplayMode.hex);
    await _settleTimers();

    expect(viewModel.rebuilding, isFalse);
    expect(viewModel.lines, ['41 42']);
  });

  test('清空会同时释放显示历史、原始历史和待处理队列', () async {
    backend.add(utf8.encode('history\n'));
    await _settleTimers();
    expect(viewModel.rawHistoryBytes, greaterThan(0));

    viewModel.clear();

    expect(viewModel.lines, isEmpty);
    expect(viewModel.partialLine, isEmpty);
    expect(viewModel.rawHistoryBytes, 0);
    expect(service.queuedBytes, 0);
  });

  test('单个超大数据块全部丢弃时仍显示过载提示', () async {
    backend.add(List<int>.filled(1025, 0x41));
    await _settleTimers();

    expect(viewModel.lines.single, contains('RTT 接收过载'));
    expect(service.queuedBytes, 0);
    expect(service.droppedBytes, 1025);
  });
}

Future<void> _settleTimers() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _DataBackend implements RttBackend {
  final StreamController<RttDataChunk> _data =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();
  bool _connected = false;

  @override
  String get id => 'builtin-probe-rs';
  @override
  String get displayName => 'fake';
  @override
  Stream<RttDataChunk> get dataStream => _data.stream;
  @override
  Stream<String> get diagnosticStream => _diagnostics.stream;
  @override
  bool get isConnected => _connected;
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

  void add(List<int> bytes) {
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

class _UnavailableBackend implements RttBackend {
  _UnavailableBackend(this.id);
  @override
  final String id;
  @override
  String get displayName => id;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  bool get isConnected => false;
  @override
  Future<bool> isAvailable(RttProbeKind kind) async => false;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];
  @override
  Future<void> connect(RttConnectionConfig config) =>
      throw UnimplementedError();
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}
