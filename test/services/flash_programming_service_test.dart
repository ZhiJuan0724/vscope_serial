import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/flash_programming_models.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/flash_programming_backend.dart';
import 'package:vscope_serial/services/flash_programming_service.dart';

class _FakeBackend implements FlashProgrammingBackend {
  _FakeBackend(this.selection, {this.available = true});

  @override
  final ProgrammingBackendSelection selection;
  bool available;
  bool connected = false;
  bool failOperation = false;
  int connectCount = 0;
  int programCount = 0;
  Completer<void>? programGate;
  // ignore: close_sinks
  final outputController = StreamController<String>.broadcast();

  @override
  String get displayName => selection.label;

  @override
  bool get isConnected => connected;

  @override
  Stream<String> get output => outputController.stream;

  @override
  Future<bool> isAvailable(FlashConnectionConfig config) async => available;

  @override
  Future<void> connect(FlashConnectionConfig config) async {
    connectCount++;
    connected = true;
  }

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<void> erase(
    FlashEraseRequest request,
    FlashProgressCallback onProgress,
  ) async {
    if (failOperation) throw StateError('erase failed');
  }

  @override
  Future<void> program(
    FlashProgramRequest request,
    FlashProgressCallback onProgress,
  ) async {
    programCount++;
    await programGate?.future;
    if (failOperation) throw StateError('program failed');
  }

  @override
  Future<void> read(
    FlashReadRequest request,
    FlashProgressCallback onProgress,
  ) async {}

  @override
  Future<void> forceTerminate() async => connected = false;
}

void main() {
  final owners = ConnectionOwnerService();
  const config = FlashConnectionConfig(
    probeKind: FlashProbeKind.cmsisDap,
    target: 'stm32f407',
    openOcdInterfaceConfig: 'interface/cmsis-dap.cfg',
    openOcdTargetConfig: 'target/stm32f4x.cfg',
  );

  setUp(owners.reset);
  tearDown(owners.reset);

  test('自动模式只因工具不可用回退并锁定已连接后端', () async {
    final external = _FakeBackend(
      ProgrammingBackendSelection.externalOpenocd,
      available: false,
    );
    final bundled = _FakeBackend(ProgrammingBackendSelection.bundledOpenocd);
    addTearDown(external.outputController.close);
    addTearDown(bundled.outputController.close);
    final service = FlashProgrammingService(
      owners: owners,
      backendBuilder:
          (selection) =>
              selection == ProgrammingBackendSelection.externalOpenocd
                  ? external
                  : bundled,
    );
    await service.connect(config);
    expect(service.activeBackend, ProgrammingBackendSelection.bundledOpenocd);
    expect(owners.owner, ConnectionOwner.programming);

    bundled.failOperation = true;
    await expectLater(
      service.program(const FlashProgramRequest(filePath: 'firmware.elf')),
      throwsStateError,
    );
    expect(external.connectCount, 0);
    expect(bundled.connectCount, 1);
    await service.disconnect();
    expect(owners.owner, ConnectionOwner.none);
  });

  test('编程会话与数据及探针所有权互斥', () async {
    owners.tryAcquire(ConnectionOwner.data);
    final backend = _FakeBackend(ProgrammingBackendSelection.externalJlink);
    addTearDown(backend.outputController.close);
    final service = FlashProgrammingService(
      owners: owners,
      backendBuilder: (_) => backend,
    );
    await expectLater(
      service.connect(
        const FlashConnectionConfig(
          backend: ProgrammingBackendSelection.externalJlink,
          probeKind: FlashProbeKind.jlink,
          target: 'STM32F407ZG',
        ),
      ),
      throwsStateError,
    );
    expect(backend.connectCount, 0);
  });

  test('活动期间普通断开被拒绝，强制终止释放所有权', () async {
    final backend = _FakeBackend(ProgrammingBackendSelection.externalJlink)
      ..programGate = Completer<void>();
    addTearDown(backend.outputController.close);
    final service = FlashProgrammingService(
      owners: owners,
      backendBuilder: (_) => backend,
    );
    await service.connect(
      const FlashConnectionConfig(
        backend: ProgrammingBackendSelection.externalJlink,
        probeKind: FlashProbeKind.jlink,
        target: 'STM32F407ZG',
      ),
    );
    final operation = service.program(
      const FlashProgramRequest(filePath: 'firmware.elf'),
    );
    await Future<void>.delayed(Duration.zero);
    await expectLater(service.disconnect(), throwsStateError);
    await service.forceTerminate();
    backend.programGate!.complete();
    await operation;
    expect(owners.owner, ConnectionOwner.none);
    expect(service.state, FlashOperationState.unknown);
  });
}
