import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/rtt_backend.dart';
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
        _UnavailableBackend('external-pyocd'),
        _UnavailableBackend('builtin-probe-rs'),
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
    expect(find.byIcon(Icons.tag), findsOneWidget);
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTT 设置复用 Shell 字体范围和字体调整样式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = RttService(
      backends: const [
        _UnavailableBackend('external-jlink'),
        _UnavailableBackend('external-pyocd'),
        _UnavailableBackend('builtin-probe-rs'),
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

    await tester.tap(find.byTooltip('RTT设置'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rtt-font-size-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('rtt-font-preview')), findsOneWidget);
    await tester.tap(find.text(viewModel.fontFamily).first);
    await tester.pumpAndSettle();
    expect(find.text('Sarasa Mono SC'), findsOneWidget);
    expect(find.text('SarasaUiSC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _UnavailableBackend implements RttBackend {
  const _UnavailableBackend(this.id);

  @override
  final String id;
  @override
  String get displayName => id;
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
