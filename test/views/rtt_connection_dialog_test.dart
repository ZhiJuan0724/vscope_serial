import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/views/dialogs/rtt_connection_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('RTT 连接仅手动刷新且刷新期间仍可关闭窗口', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousMode = settings.rttBackendMode;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    settings
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendMode = RttBackendMode.automatic.value
      ..rttAutoDetectTarget = false;
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendMode = previousMode
        ..rttAutoDetectTarget = previousAutoDetect;
    });

    final jlink = _DiscoveryBackend('external-jlink');
    final cmsisDap = _DiscoveryBackend('external-pyocd');
    final builtin = _DiscoveryBackend('builtin-probe-rs', available: false);
    final service = RttService(backends: [jlink, cmsisDap, builtin]);
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RttService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const RttConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('预计使用后端：external-jlink（自动选择）'), findsOneWidget);

    expect(jlink.discoveryCount, 0);
    await tester.tap(find.text('J-Link').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CMSIS-DAP').last);
    await tester.pumpAndSettle();
    expect(find.text('预计使用后端：external-pyocd（自动选择）'), findsOneWidget);
    expect(cmsisDap.discoveryCount, 0);

    final probeHeight =
        tester
            .getSize(find.byKey(const ValueKey('rtt-probe-kind-field')))
            .height;
    expect(
      tester.getSize(find.byKey(const ValueKey('rtt-target-field'))).height,
      probeHeight,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('rtt-clock-field'))).height,
      probeHeight,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('rtt-target-field'))).width,
      lessThan(400),
    );
    expect(find.byTooltip('检索支持的芯片'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新探针'));
    await tester.pump();
    expect(cmsisDap.discoveryCount, 1);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('RTT 连接'), findsNothing);

    cmsisDap.completeDiscovery();
    await tester.pump();
  });

  testWidgets('目标芯片弹窗支持模糊搜索并回填型号', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousMode = settings.rttBackendMode;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    final previousTarget = settings.rttTarget;
    settings
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendMode = RttBackendMode.automatic.value
      ..rttAutoDetectTarget = false
      ..rttTarget = '';
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendMode = previousMode
        ..rttAutoDetectTarget = previousAutoDetect
        ..rttTarget = previousTarget;
    });

    final jlink = _TargetBackend('external-jlink');
    final service = RttService(
      backends: [
        jlink,
        _TargetBackend('external-pyocd', available: false),
        _TargetBackend('builtin-probe-rs', available: false),
      ],
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RttService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const RttConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('检索支持的芯片'));
    await tester.pumpAndSettle();

    expect(find.text('STM32F407VG'), findsOneWidget);
    expect(find.text('nRF52840_xxAA'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('rtt-target-search-field')),
      'f47',
    );
    await tester.pump();
    expect(find.text('STM32F407VG'), findsOneWidget);
    expect(find.text('nRF52840_xxAA'), findsNothing);

    await tester.tap(find.text('STM32F407VG'));
    await tester.pumpAndSettle();
    final targetField = tester.widget<TextField>(
      find.byKey(const ValueKey('rtt-target-field')),
    );
    expect(targetField.controller?.text, 'STM32F407VG');
  });
}

class _DiscoveryBackend implements RttBackend {
  _DiscoveryBackend(this.id, {this.available = true});

  @override
  final String id;
  final bool available;
  final Completer<List<RttProbeInfo>> _probes = Completer();
  final Completer<List<RttTargetInfo>> _targets = Completer();
  int discoveryCount = 0;

  @override
  String get displayName => id;
  @override
  bool get isConnected => false;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  Future<bool> isAvailable(RttProbeKind kind) async => available;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) {
    discoveryCount++;
    return _probes.future;
  }

  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) {
    discoveryCount++;
    return _targets.future;
  }

  void completeDiscovery() {
    if (!_probes.isCompleted) _probes.complete(const []);
    if (!_targets.isCompleted) _targets.complete(const []);
  }

  @override
  Future<void> connect(RttConnectionConfig config) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async => completeDiscovery();
}

class _TargetBackend implements RttBackend {
  _TargetBackend(this.id, {this.available = true});

  @override
  final String id;
  final bool available;

  @override
  String get displayName => id;
  @override
  bool get isConnected => false;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  Future<bool> isAvailable(RttProbeKind kind) async => available;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [
    RttTargetInfo(
      name: 'STM32F407VG',
      vendor: 'STMicroelectronics',
      source: '内置目标',
    ),
    RttTargetInfo(
      name: 'nRF52840_xxAA',
      vendor: 'Nordic Semiconductor',
      source: '内置目标',
    ),
  ];
  @override
  Future<void> connect(RttConnectionConfig config) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}
