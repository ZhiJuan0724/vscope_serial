import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/data/models/probe_connection_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/probe_backend.dart';
import 'package:vscope_serial/services/probe_connection_service.dart';
import 'package:vscope_serial/views/dialogs/probe_connection_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('RTT 连接过程中可以取消并关闭窗口', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousTarget = settings.rttTarget;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    settings
      ..rttProbeKind = ProbeKind.jlink.value
      ..rttBackendSelection = ProbeBackendSelection.externalJlink.value
      ..rttTarget = 'TEST'
      ..rttAutoDetectTarget = false;
    final backend = _DelayedConnectBackend('external-jlink');
    final service = ProbeConnectionService(backends: [backend]);
    addTearDown(() async {
      await service.shutdown();
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttTarget = previousTarget
        ..rttAutoDetectTarget = previousAutoDetect;
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接').last);
    await tester.pump();

    expect(find.text('取消连接'), findsOneWidget);
    await tester.tap(find.text('取消连接'));
    await tester.pumpAndSettle();

    expect(find.text('探针连接'), findsNothing);
  });

  testWidgets('RTT 连接仅手动刷新且刷新期间仍可关闭窗口', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    final previousTargetConfig = settings.rttOpenocdTargetConfig;
    settings
      ..rttProbeKind = ProbeKind.jlink.value
      ..rttBackendSelection = ProbeBackendSelection.automatic.value
      ..rttAutoDetectTarget = false
      ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg';
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttAutoDetectTarget = previousAutoDetect
        ..rttOpenocdTargetConfig = previousTargetConfig;
    });

    final jlink = _DiscoveryBackend('external-jlink');
    final openocd = _DiscoveryBackend('external-openocd');
    final service = ProbeConnectionService(backends: [jlink, openocd]);
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('探针连接'), findsOneWidget);
    expect(find.text('预计使用后端：external-jlink（自动选择）'), findsOneWidget);

    expect(jlink.discoveryCount, 0);
    await tester.tap(find.text('J-Link').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CMSIS-DAP').last);
    await tester.pumpAndSettle();
    expect(find.text('预计使用后端：external-openocd（自动选择）'), findsOneWidget);
    expect(openocd.discoveryCount, 0);

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
    expect(openocd.discoveryCount, 1);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('探针连接'), findsNothing);

    openocd.completeDiscovery();
    await tester.pump();
  });

  testWidgets('目标芯片弹窗支持模糊搜索并回填型号', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    final previousTarget = settings.rttTarget;
    settings
      ..rttProbeKind = ProbeKind.jlink.value
      ..rttBackendSelection = ProbeBackendSelection.automatic.value
      ..rttAutoDetectTarget = false
      ..rttTarget = '';
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttAutoDetectTarget = previousAutoDetect
        ..rttTarget = previousTarget;
    });

    final jlink = _TargetBackend('external-jlink');
    final service = ProbeConnectionService(
      backends: [jlink, _TargetBackend('external-openocd', available: false)],
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
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

  testWidgets('探针未刷新时默认自动选择且刷新后仍可切回自动', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousProbeId = settings.rttLastProbeId;
    settings
      ..rttProbeKind = ProbeKind.jlink.value
      ..rttBackendSelection = ProbeBackendSelection.automatic.value
      ..rttLastProbeId = 'OLD-PROBE';
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttLastProbeId = previousProbeId;
    });

    final service = ProbeConnectionService(
      backends: [
        _ImmediateProbeBackend('external-jlink'),
        _ImmediateProbeBackend('external-openocd', available: false),
      ],
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('自动选择'), findsOneWidget);
    expect(find.text('OLD-PROBE'), findsNothing);

    await tester.tap(find.byTooltip('刷新探针'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rtt-probe-field')));
    await tester.pumpAndSettle();
    expect(find.text('J-Link Probe A'), findsOneWidget);
    expect(find.text('自动选择'), findsNWidgets(2));

    await tester.tap(find.text('J-Link Probe A'));
    await tester.pumpAndSettle();
    expect(find.text('J-Link Probe A'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rtt-probe-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动选择').last);
    await tester.pumpAndSettle();
    expect(find.text('自动选择'), findsOneWidget);
  });

  testWidgets('后端选择优先联动探针类型', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousControlBlockMode = settings.rttControlBlockMode;
    settings
      ..rttProbeKind = ProbeKind.jlink.value
      ..rttBackendSelection = ProbeBackendSelection.automatic.value
      ..rttControlBlockMode = RttControlBlockMode.automatic.value;
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttControlBlockMode = previousControlBlockMode;
    });

    final service = ProbeConnectionService(
      backends: [
        _ImmediateProbeBackend('external-jlink'),
        _ImmediateProbeBackend('external-openocd'),
      ],
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rtt-backend-field')));
    await tester.pumpAndSettle();
    expect(find.text('外部 J-Link'), findsOneWidget);
    expect(find.text('内置 OpenOCD'), findsOneWidget);
    expect(find.text('外置 OpenOCD'), findsOneWidget);
    expect(find.text('外置 pyOCD'), findsOneWidget);
    await tester.tap(find.text('外部 J-Link'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rtt-probe-kind-field')));
    await tester.pumpAndSettle();
    expect(find.text('J-Link'), findsNWidgets(2));
    expect(find.text('CMSIS-DAP'), findsNothing);
    await tester.tap(find.text('J-Link').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rtt-backend-field')));
    await tester.pumpAndSettle();
    expect(find.text('外部 J-Link'), findsNWidgets(2));
    expect(find.text('内置 OpenOCD'), findsOneWidget);
    expect(find.text('外置 OpenOCD'), findsOneWidget);
    expect(find.text('外置 pyOCD'), findsOneWidget);
    await tester.tap(find.text('外置 OpenOCD').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rtt-probe-kind-field')));
    await tester.pumpAndSettle();
    expect(find.text('J-Link'), findsNothing);
    expect(find.text('CMSIS-DAP'), findsNWidgets(2));
    await tester.tap(find.text('CMSIS-DAP').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('rtt-control-block-mode-field')),
      findsNothing,
    );
    expect(find.text('Auto'), findsNothing);
    expect(find.text('指定地址'), findsNothing);
    expect(find.text('指定范围'), findsNothing);
  });

  testWidgets('外置 pyOCD 可显式选择仅 v1 或仅 v2', (tester) async {
    final settings = AppSettings();
    final previousBackend = settings.rttBackendSelection;
    final previousVersion = settings.rttPyocdCmsisDapVersion;
    settings
      ..rttBackendSelection = ProbeBackendSelection.externalPyocd.value
      ..rttPyocdCmsisDapVersion = PyOcdCmsisDapVersion.automatic.value;
    addTearDown(() {
      settings
        ..rttBackendSelection = previousBackend
        ..rttPyocdCmsisDapVersion = previousVersion;
    });

    final service = ProbeConnectionService(
      backends: [_ImmediateProbeBackend('external-pyocd')],
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder: (_) => const ProbeConnectionDialog(),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('rtt-pyocd-cmsis-dap-version'));
    expect(field, findsOneWidget);
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.text('仅 v1'), findsOneWidget);
    expect(find.text('仅 v2'), findsOneWidget);
    await tester.tap(find.text('仅 v2'));
    await tester.pumpAndSettle();
    expect(find.text('仅 v2'), findsOneWidget);
  });

  testWidgets('OpenOCD 配置可直接输入或通过右侧按钮选择文件', (tester) async {
    final settings = AppSettings();
    final previousBackend = settings.rttBackendSelection;
    final previousInterfaceConfig = settings.rttOpenocdInterfaceConfig;
    final previousTargetConfig = settings.rttOpenocdTargetConfig;
    settings
      ..rttBackendSelection = ProbeBackendSelection.externalOpenocd.value
      ..rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg'
      ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg';
    addTearDown(() {
      settings
        ..rttBackendSelection = previousBackend
        ..rttOpenocdInterfaceConfig = previousInterfaceConfig
        ..rttOpenocdTargetConfig = previousTargetConfig;
    });

    final service = ProbeConnectionService(
      backends: [_TargetBackend('external-openocd')],
    );
    addTearDown(service.dispose);
    const interfacePath = r'C:\OpenOCD\scripts\interface\cmsis-dap.cfg';
    const targetPath = r'C:\OpenOCD\scripts\target\stm32f4x.cfg';

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbeConnectionService>.value(
        value: service,
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => ProbeConnectionDialog(
                              openOcdConfigDirectoryResolver:
                                  (_, category) async =>
                                      'C:\\OpenOCD\\scripts\\$category',
                              openOcdConfigFilePicker: (
                                dialogTitle,
                                initialDirectory,
                              ) async {
                                expect(
                                  initialDirectory,
                                  dialogTitle.contains('接口')
                                      ? r'C:\OpenOCD\scripts\interface'
                                      : r'C:\OpenOCD\scripts\target',
                                );
                                return dialogTitle.contains('接口')
                                    ? interfacePath
                                    : targetPath;
                              },
                            ),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final interfaceFieldFinder = find.byKey(
      const ValueKey('rtt-openocd-interface-field'),
    );
    final targetFieldFinder = find.byKey(
      const ValueKey('rtt-openocd-target-field'),
    );
    expect(tester.widget<TextField>(interfaceFieldFinder).readOnly, isFalse);
    expect(tester.widget<TextField>(targetFieldFinder).readOnly, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('rtt-openocd-interface-file-button')),
          )
          .splashRadius,
      18,
    );

    await tester.enterText(interfaceFieldFinder, 'interface/stlink.cfg');
    expect(
      tester.widget<TextField>(interfaceFieldFinder).controller?.text,
      'interface/stlink.cfg',
    );
    await tester.tap(
      find.byKey(const ValueKey('rtt-openocd-interface-file-button')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(interfaceFieldFinder).controller?.text,
      interfacePath,
    );
    expect(
      tester.widget<TextField>(targetFieldFinder).controller?.text,
      'target/stm32f4x.cfg',
    );

    await tester.ensureVisible(targetFieldFinder);
    await tester.tap(
      find.byKey(const ValueKey('rtt-openocd-target-file-button')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(targetFieldFinder).readOnly, isFalse);
    expect(
      tester.widget<TextField>(targetFieldFinder).controller?.text,
      targetPath,
    );
  });
}

class _DiscoveryBackend implements ProbeBackend {
  _DiscoveryBackend(this.id);

  @override
  final String id;
  final Completer<List<ProbeInfo>> _probes = Completer();
  final Completer<List<ProbeTargetInfo>> _targets = Completer();
  int discoveryCount = 0;

  @override
  String get displayName => id;
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get isConnected => false;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  Future<bool> isAvailable(ProbeKind kind) async => true;
  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) {
    discoveryCount++;
    return _probes.future;
  }

  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) {
    discoveryCount++;
    return _targets.future;
  }

  void completeDiscovery() {
    if (!_probes.isCompleted) _probes.complete(const []);
    if (!_targets.isCompleted) _targets.complete(const []);
  }

  @override
  Future<void> connect(ProbeConnectionConfig config) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async => completeDiscovery();
}

class _TargetBackend implements ProbeBackend {
  _TargetBackend(this.id, {this.available = true});

  @override
  final String id;
  final bool available;

  @override
  String get displayName => id;
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get isConnected => false;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  Future<bool> isAvailable(ProbeKind kind) async => available;
  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async => const [];
  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) async => const [
    ProbeTargetInfo(
      name: 'STM32F407VG',
      vendor: 'STMicroelectronics',
      source: '内置目标',
    ),
    ProbeTargetInfo(
      name: 'nRF52840_xxAA',
      vendor: 'Nordic Semiconductor',
      source: '内置目标',
    ),
  ];
  @override
  Future<void> connect(ProbeConnectionConfig config) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}

class _ImmediateProbeBackend extends _TargetBackend {
  _ImmediateProbeBackend(super.id, {super.available});

  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async => const [
    ProbeInfo(id: 'JLINK-A', name: 'J-Link Probe A', kind: ProbeKind.jlink),
  ];
}

class _DelayedConnectBackend extends _TargetBackend {
  _DelayedConnectBackend(super.id);

  final Completer<void> _connectGate = Completer<void>();
  int disconnectCount = 0;

  @override
  Future<void> connect(ProbeConnectionConfig config) => _connectGate.future;

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    if (!_connectGate.isCompleted) _connectGate.complete();
  }
}
