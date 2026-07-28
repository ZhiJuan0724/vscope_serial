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
    final previousBackend = settings.rttBackendSelection;
    final previousAutoDetect = settings.rttAutoDetectTarget;
    final previousTargetConfig = settings.rttOpenocdTargetConfig;
    settings
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendSelection = RttBackendSelection.automatic.value
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
    final service = RttService(backends: [jlink, openocd]);
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
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendSelection = RttBackendSelection.automatic.value
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
    final service = RttService(
      backends: [jlink, _TargetBackend('external-openocd', available: false)],
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

  testWidgets('探针未刷新时默认自动选择且刷新后仍可切回自动', (tester) async {
    final settings = AppSettings();
    final previousKind = settings.rttProbeKind;
    final previousBackend = settings.rttBackendSelection;
    final previousProbeId = settings.rttLastProbeId;
    settings
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendSelection = RttBackendSelection.automatic.value
      ..rttLastProbeId = 'OLD-PROBE';
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttLastProbeId = previousProbeId;
    });

    final service = RttService(
      backends: [
        _ImmediateProbeBackend('external-jlink'),
        _ImmediateProbeBackend('external-openocd', available: false),
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
      ..rttProbeKind = RttProbeKind.jlink.value
      ..rttBackendSelection = RttBackendSelection.automatic.value
      ..rttControlBlockMode = RttControlBlockMode.automatic.value;
    addTearDown(() {
      settings
        ..rttProbeKind = previousKind
        ..rttBackendSelection = previousBackend
        ..rttControlBlockMode = previousControlBlockMode;
    });

    final service = RttService(
      backends: [
        _ImmediateProbeBackend('external-jlink'),
        _ImmediateProbeBackend('external-openocd'),
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

    await tester.tap(find.byKey(const ValueKey('rtt-backend-field')));
    await tester.pumpAndSettle();
    expect(find.text('外部 J-Link'), findsOneWidget);
    expect(find.text('内置 OpenOCD'), findsOneWidget);
    expect(find.text('外置 OpenOCD'), findsOneWidget);
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

  testWidgets('OpenOCD 配置可直接输入或通过右侧按钮选择文件', (tester) async {
    final settings = AppSettings();
    final previousBackend = settings.rttBackendSelection;
    final previousInterfaceConfig = settings.rttOpenocdInterfaceConfig;
    final previousTargetConfig = settings.rttOpenocdTargetConfig;
    settings
      ..rttBackendSelection = RttBackendSelection.externalOpenocd.value
      ..rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg'
      ..rttOpenocdTargetConfig = 'target/stm32f4x.cfg';
    addTearDown(() {
      settings
        ..rttBackendSelection = previousBackend
        ..rttOpenocdInterfaceConfig = previousInterfaceConfig
        ..rttOpenocdTargetConfig = previousTargetConfig;
    });

    final service = RttService(backends: [_TargetBackend('external-openocd')]);
    addTearDown(service.dispose);
    const interfacePath = r'C:\OpenOCD\scripts\interface\cmsis-dap.cfg';
    const targetPath = r'C:\OpenOCD\scripts\target\stm32f4x.cfg';

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
                        builder:
                            (_) => RttConnectionDialog(
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

class _DiscoveryBackend implements RttBackend {
  _DiscoveryBackend(this.id);

  @override
  final String id;
  final Completer<List<RttProbeInfo>> _probes = Completer();
  final Completer<List<RttTargetInfo>> _targets = Completer();
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
  Future<bool> isAvailable(RttProbeKind kind) async => true;
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

class _ImmediateProbeBackend extends _TargetBackend {
  _ImmediateProbeBackend(super.id, {super.available});

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [
    RttProbeInfo(
      id: 'JLINK-A',
      name: 'J-Link Probe A',
      kind: RttProbeKind.jlink,
    ),
  ];
}
