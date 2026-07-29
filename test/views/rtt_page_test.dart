import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/constants/rtt_configuration.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/viewmodels/rtt_viewmodel.dart';
import 'package:vscope_serial/views/pages/rtt_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('RTT 窄窗口下显示完整工具栏与连接空态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = RttService(
      backends: const [
        _UnavailableBackend('external-jlink'),
        _UnavailableBackend('external-openocd'),
      ],
    );
    final viewModel = RttViewModel(service);
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RttService>.value(value: service),
          ChangeNotifierProvider<RttViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: RttPage())),
      ),
    );

    expect(find.text(AppStrings.rtt.connectHint), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.numbers), findsOneWidget);
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('时间戳'), findsOneWidget);
    expect(find.text('HEX显示'), findsOneWidget);
    expect(find.text('自动滚动'), findsOneWidget);
    final collapseButton = find.byKey(
      const ValueKey('rtt-terminal-panel-collapse-button'),
    );
    expect(collapseButton, findsOneWidget);
    expect(tester.getSize(collapseButton), const Size(34, 36));
    expect(
      find.descendant(of: collapseButton, matching: find.byType(IconButton)),
      findsNothing,
    );
    await tester.tap(collapseButton);
    await tester.pump();
    final expandButton = find.byKey(
      const ValueKey('rtt-terminal-panel-expand-button'),
    );
    expect(expandButton, findsOneWidget);
    expect(tester.getSize(expandButton), const Size(34, 36));
    expect(
      tester
          .widget<PopupMenuButton<bool>>(
            find.byKey(const ValueKey('rtt-export-button')),
          )
          .enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTT 设置复用 Shell 字体范围和字体调整样式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = RttService(
      backends: const [
        _UnavailableBackend('external-jlink'),
        _UnavailableBackend('external-openocd'),
      ],
    );
    final viewModel = RttViewModel(service);
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RttService>.value(value: service),
          ChangeNotifierProvider<RttViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: RttPage())),
      ),
    );

    await tester.tap(find.byTooltip('RTT Viewer 设置'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rtt-font-size-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('rtt-font-preview')), findsOneWidget);
    expect(find.text('默认调试接口'), findsNothing);
    expect(find.text('默认调试时钟'), findsNothing);
    expect(find.text('默认 RTT 控制块定位'), findsNothing);
    await tester.tap(find.text(viewModel.fontFamily).first);
    await tester.pumpAndSettle();
    expect(find.text('Sarasa Mono SC'), findsOneWidget);
    expect(find.text('SarasaUiSC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OpenOCD 的 RTT 活动齿轮不提供 Auto 控制块定位', (tester) async {
    final settings = AppSettings();
    final previousMode = settings.rttControlBlockMode;
    final previousBackend = settings.rttBackendSelection;
    final previousPollingInterval = settings.rttViewerPollingIntervalMs;
    settings
      ..rttControlBlockMode = RttControlBlockMode.automatic.value
      ..rttBackendSelection = RttBackendSelection.externalOpenocd.value
      ..rttViewerPollingIntervalMs = 10;
    final service = RttService(backends: const []);
    final viewModel = RttViewModel(service);
    addTearDown(() {
      settings.rttControlBlockMode = previousMode;
      settings.rttBackendSelection = previousBackend;
      settings.rttViewerPollingIntervalMs = previousPollingInterval;
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RttService>.value(value: service),
          ChangeNotifierProvider<RttViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: RttPage())),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('rtt-activity-settings-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('RTT Viewer 接收配置'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('rtt-activity-control-block-mode')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Auto'), findsNothing);
    expect(find.text('指定地址'), findsNWidgets(2));
    expect(find.text('指定范围'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('rtt-activity-polling-interval')),
      findsOneWidget,
    );
    expect(find.text('仅 OpenOCD 后端使用；J-Link 不传递此参数。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('RTT Viewer 启动过程显示启动中且停止过程显示停止中', (tester) async {
    ConnectionOwnerService().reset();
    final backend = _DeferredActivityBackend();
    final service = RttService(backends: [backend]);
    final viewModel = RttViewModel(service);
    await service.connect(
      const RttConnectionConfig(
        backend: RttBackendSelection.externalOpenocd,
        probeKind: RttProbeKind.cmsisDap,
        target: 'TEST',
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RttService>.value(value: service),
          ChangeNotifierProvider<RttViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: RttPage())),
      ),
    );
    await tester.tap(find.text('开始').first);
    await tester.pump();
    expect(find.text('启动中'), findsOneWidget);

    backend.startGate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('停止'), findsOneWidget);

    await tester.tap(find.text('停止').first);
    await tester.pump();
    expect(find.text('停止中'), findsOneWidget);

    backend.stopGate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('开始'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    service.dispose();
    ConnectionOwnerService().reset();
  }, timeout: const Timeout(Duration(seconds: 5)));

  testWidgets('All Terminals 前缀与左侧列表同色且右键可修改', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = RttService(
      backends: const [
        _UnavailableBackend('external-jlink'),
        _UnavailableBackend('external-openocd'),
      ],
    );
    final viewModel = _TerminalColorViewModel(service);
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RttService>.value(value: service),
          ChangeNotifierProvider<RttViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: RttPage())),
      ),
    );

    Text aggregateText(String expected) => tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.textSpan?.toPlainText() == expected,
      ),
    );
    Color aggregatePrefixColor(String expected) {
      final span = aggregateText(expected).textSpan! as TextSpan;
      return span.children!.first.style!.color!;
    }

    const initialText = '[Terminal 3] payload';
    final initialColor = Color(viewModel.terminalColorValue(3));
    expect(aggregatePrefixColor(initialText), initialColor);
    expect(
      tester.widget<Text>(find.text('Terminal 3')).style?.color,
      initialColor,
    );
    final span = aggregateText(initialText).textSpan! as TextSpan;
    expect(span.children![1].style?.color, isNull);

    final row = find.byKey(const ValueKey('rtt-terminal-row-3'));
    await tester.ensureVisible(row);
    expect(tester.widget<ListTile>(row).minTileHeight, 34);
    final position = tester.getCenter(row);
    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.addPointer(location: position);
    await secondary.down(position);
    await secondary.up();
    await secondary.removePointer();
    await tester.pumpAndSettle();

    expect(find.text('Terminal 3 标注设置'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('rtt-terminal-label-field')),
      '电机状态',
    );
    await tester.tap(find.byKey(const ValueKey('rtt-terminal-color-option-1')));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final changedColor = Color(RttConfiguration.defaultTerminalColors[1]);
    expect(viewModel.changedTerminal, 3);
    expect(viewModel.terminalLabel(3), '电机状态');
    expect(aggregatePrefixColor('[电机状态] payload'), changedColor);
    expect(tester.widget<Text>(find.text('电机状态')).style?.color, changedColor);
  });
}

class _TerminalColorViewModel extends RttViewModel {
  _TerminalColorViewModel(super.service);

  final List<int> _colors = List.of(RttConfiguration.defaultTerminalColors);
  final List<String> _labels = List.of(RttConfiguration.defaultTerminalLabels);
  int? changedTerminal;

  @override
  List<String> get lines => const ['[Terminal 3] payload'];

  @override
  String get partialLine => '';

  @override
  int get selectedTerminal => -1;

  @override
  bool get allTerminalsSelected => true;

  @override
  bool terminalHasData(int terminal) => terminal == 3;

  @override
  int terminalColorValue(int terminal) => _colors[terminal];

  @override
  String terminalLabel(int terminal) => _labels[terminal];

  @override
  void setTerminalAppearance(int terminal, String label, int colorValue) {
    changedTerminal = terminal;
    _labels[terminal] = label;
    _colors[terminal] = colorValue;
    notifyListeners();
  }
}

class _UnavailableBackend implements RttBackend {
  const _UnavailableBackend(this.id);

  @override
  final String id;
  @override
  String get displayName => id;
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  Stream<RttDataChunk> get dataStream => const Stream<RttDataChunk>.empty();
  @override
  Stream<String> get diagnosticStream => const Stream<String>.empty();
  @override
  bool get isConnected => false;
  @override
  Future<bool> isAvailable(RttProbeKind kind) async => false;
  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];
  @override
  Future<void> connect(RttConnectionConfig config) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {}
}

class _DeferredActivityBackend implements RttBackend, RttActivityBackend {
  final Completer<void> startGate = Completer<void>();
  final Completer<void> stopGate = Completer<void>();
  bool _connected = false;

  @override
  String get id => RttBackendSelection.externalOpenocd.value;
  @override
  String get displayName => '测试 OpenOCD';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get isConnected => _connected;
  @override
  Stream<RttDataChunk> get dataStream => const Stream.empty();
  @override
  Stream<String> get diagnosticStream => const Stream.empty();
  @override
  Set<RttBackendCapability> get capabilities => const {
    RttBackendCapability.independentActivity,
    RttBackendCapability.downChannel0,
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
  Future<void> startRttViewer() => startGate.future;
  @override
  Future<void> stopActivity() => stopGate.future;
  @override
  Future<void> writeDownChannel0(Uint8List data) async {}
  @override
  Future<void> dispose() async {}
}
