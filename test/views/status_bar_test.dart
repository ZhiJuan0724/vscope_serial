import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/widgets/status_bar.dart';

void main() {
  testWidgets('状态栏按页面标识串口或探针连接状态', (tester) async {
    final serialService = SerialService();
    final plotViewModel = PlotViewModel(serialService);
    final rttService = RttService();
    final previousNetworkEnabled = AppSettings().networkConnectionsEnabled;
    addTearDown(() {
      AppSettings().networkConnectionsEnabled = previousNetworkEnabled;
    });

    Widget app(String pageId) => MultiProvider(
      providers: [
        ChangeNotifierProvider<SerialService>.value(value: serialService),
        ChangeNotifierProvider<PlotViewModel>.value(value: plotViewModel),
        ChangeNotifierProvider<RttService>.value(value: rttService),
      ],
      child: MaterialApp(
        home: Scaffold(body: StatusBar(currentPageId: pageId)),
      ),
    );

    await tester.pumpWidget(app('rawData'));
    expect(find.text('串口未连接'), findsOneWidget);

    serialService.setNetworkConnectionsEnabled(true);
    await tester.pump();
    expect(find.text('串口/网络未连接'), findsOneWidget);

    await tester.pumpWidget(app('rtt'));
    expect(find.text('探针未连接'), findsOneWidget);
    expect(
      connectionStatusLabel(isProbe: false, connected: true, connecting: false),
      '串口已连接',
    );
    expect(
      connectionStatusLabel(isProbe: true, connected: false, connecting: true),
      '探针连接中...',
    );
    expect(
      connectionStatusLabel(isProbe: true, connected: true, connecting: false),
      '探针已连接',
    );
    expect(
      connectionStatusLabel(
        isProbe: true,
        connected: false,
        connecting: true,
        reconnecting: true,
      ),
      '探针重连中...',
    );

    // 定时刷新器必须在 Widget 测试结束前释放，避免残留 FakeTimer。
    await tester.pumpWidget(const SizedBox.shrink());
    rttService.dispose();
    plotViewModel.dispose();
  });

  testWidgets('随机源状态仅在 FireWater 协议下显示', (tester) async {
    final service = SerialService();
    final plotViewModel = PlotViewModel(service);
    plotViewModel.setParserType(ParserType.fireWater);
    plotViewModel.setUseRandomSource(true);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SerialService>.value(value: service),
          ChangeNotifierProvider<PlotViewModel>.value(value: plotViewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: StatusBar())),
      ),
    );
    await tester.pump();

    expect(find.text('随机源'), findsOneWidget);

    plotViewModel.setParserType(ParserType.justFloat);
    await tester.pump();
    await tester.pump();

    expect(find.text('随机源'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    plotViewModel.dispose();
  });

  testWidgets('应用信息和高级设置使用独立入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = SerialService();
    final plotViewModel = PlotViewModel(service);
    final rttService = RttService(
      backends: [
        _VersionBackend('external-jlink', 'v8.24a'),
        _VersionBackend('external-openocd', 'v0.12.0-external'),
        _VersionBackend('bundled-openocd', 'v0.12.0-bundled'),
      ],
    );
    final previousAggregation = AppSettings().plotReceiveAggregationEnabled;
    final previousDiagnostic = AppSettings().diagnosticLoggingEnabled;
    final previousShortcuts = AppSettings().connectionShortcutsEnabled;
    final previousCrashDump = AppSettings().crashDumpEnabled;
    final previousRttEnabled = AppSettings().rttPageEnabled;
    AppSettings().plotReceiveAggregationEnabled = false;
    AppSettings().diagnosticLoggingEnabled = false;
    AppSettings().connectionShortcutsEnabled = true;
    AppSettings().crashDumpEnabled = true;
    AppSettings().rttPageEnabled = true;
    AppLogger().setDiagnosticEnabled(false);
    addTearDown(() {
      AppSettings().plotReceiveAggregationEnabled = previousAggregation;
      AppSettings().diagnosticLoggingEnabled = previousDiagnostic;
      AppSettings().connectionShortcutsEnabled = previousShortcuts;
      AppSettings().crashDumpEnabled = previousCrashDump;
      AppSettings().rttPageEnabled = previousRttEnabled;
      AppLogger().setDiagnosticEnabled(previousDiagnostic);
      rttService.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SerialService>.value(value: service),
          ChangeNotifierProvider<PlotViewModel>.value(value: plotViewModel),
          ChangeNotifierProvider<RttService>.value(value: rttService),
        ],
        child: const MaterialApp(home: Scaffold(body: StatusBar())),
      ),
    );

    expect(
      find.byKey(const ValueKey('app-advanced-settings-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('app-info-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-info-button')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.appInfo.title), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-build-time')), findsOneWidget);
    expect(
      find.text(AppStrings.appInfo.updateChannelAndSourceTitle),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('update-channel-and-source')),
      findsOneWidget,
    );
    final checkButton = find.byKey(const ValueKey('check-for-update-button'));
    final downloadButton = find.byKey(
      const ValueKey('download-and-install-button'),
    );
    expect(checkButton, findsOneWidget);
    expect(downloadButton, findsOneWidget);
    expect(
      find.ancestor(of: checkButton, matching: find.byType(Scrollable)),
      findsNothing,
    );
    expect(
      find.ancestor(of: downloadButton, matching: find.byType(Scrollable)),
      findsNothing,
    );
    expect(find.text(AppStrings.common.advancedSettings), findsNothing);

    await tester.tap(find.text(AppStrings.common.close));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('app-advanced-settings-button')),
    );
    await tester.pump();
    expect(find.text(AppStrings.common.advancedSettings), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-navigation-view')),
      findsOneWidget,
    );
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('快捷键'), findsOneWidget);
    expect(find.text('页面'), findsOneWidget);
    expect(find.text('探针后端'), findsOneWidget);
    expect(find.text(AppStrings.appInfo.receivePerformance), findsOneWidget);
    expect(find.text(AppStrings.appInfo.memoryLimits), findsOneWidget);
    expect(find.text('版本回退'), findsWidgets);
    expect(find.text('重置设置'), findsWidgets);
    expect(find.text(AppStrings.appInfo.disableNotifications), findsOneWidget);
    expect(find.text(AppStrings.appInfo.crashDump), findsOneWidget);
    expect(
      find.byKey(const ValueKey('debug-trigger-native-crash-button')),
      findsOneWidget,
    );
    final shortcutToggle = find.ancestor(
      of: find.text('启用连接快捷键'),
      matching: find.byType(SwitchListTile),
    );
    expect(shortcutToggle, findsOneWidget);
    await tester.tap(shortcutToggle);
    await tester.pump();
    expect(AppSettings().connectionShortcutsEnabled, isFalse);
    final diagnosticToggle = find.ancestor(
      of: find.text(AppStrings.appInfo.diagnosticLogging),
      matching: find.byType(SwitchListTile),
    );
    expect(diagnosticToggle, findsOneWidget);
    expect(AppSettings().diagnosticLoggingEnabled, isFalse);
    await tester.tap(diagnosticToggle);
    await tester.pump();
    expect(AppSettings().diagnosticLoggingEnabled, isTrue);
    expect(AppLogger().diagnosticEnabled, isTrue);
    final aggregationToggle = find.ancestor(
      of: find.text(AppStrings.appInfo.plotReceiveAggregation),
      matching: find.byType(SwitchListTile),
    );
    expect(aggregationToggle, findsOneWidget);
    expect(AppSettings().plotReceiveAggregationEnabled, isFalse);
    await tester.ensureVisible(aggregationToggle);
    await tester.tap(aggregationToggle);
    await tester.pump();
    expect(AppSettings().plotReceiveAggregationEnabled, isTrue);
    final plotMemoryField = find.byKey(
      const ValueKey('app-plot-history-memory-limit'),
    );
    expect(plotMemoryField, findsOneWidget);
    expect(tester.widget<TextField>(plotMemoryField), isA<TextField>());
    expect(
      find.text(AppStrings.appInfo.rawRetentionMemoryLimit),
      findsOneWidget,
    );
    expect(find.text(AppStrings.appInfo.shellQueueMemoryLimit), findsOneWidget);
    expect(
      find.text(AppStrings.appInfo.ymodemQueueMemoryLimit),
      findsOneWidget,
    );
    expect(find.textContaining('当前占用: 0 B / 512 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 128 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 256 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 4 MiB'), findsOneWidget);

    await tester.tap(find.text('探针后端'));
    await tester.pumpAndSettle();
    expect(find.textContaining('内置 OpenOCD: v0.12.0-bundled'), findsOneWidget);
    expect(find.textContaining('外置 OpenOCD: v0.12.0-external'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    plotViewModel.dispose();
  });
}

class _VersionBackend implements RttBackend, RttBackendVersionProvider {
  const _VersionBackend(this.id, this.version);

  @override
  final String id;
  final String version;

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
  Future<String?> detectVersion(RttProbeKind kind) async => version;
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
