import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/probe_plot_config.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/rtt_service.dart';
import 'package:vscope_serial/viewmodels/probe_plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/probe_plot_page.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

class _JumpProbePlotViewModel extends ProbePlotViewModel {
  _JumpProbePlotViewModel(super.service) {
    pointCount = 10;
  }

  int? jumpedIndex;

  @override
  int? get minJumpPacketIndex => 0;

  @override
  int? get maxJumpPacketIndex => 9;

  @override
  bool canJumpToPacketIndex(int index) => index >= 0 && index <= 9;

  @override
  void jumpToPacketIndex(int index) {
    jumpedIndex = index;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HSS 导入 ELF 后显示可搜索变量列表并可直接添加', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = RttService(
      connectionOwners: ConnectionOwnerService(),
      backends: [],
    );
    final viewModel =
        ProbePlotViewModel(service)
          ..setMode(ProbePlotMode.hss)
          ..programPath = 'sample.elf'
          ..symbols = const [
            ProbeSymbolInfo(name: 'motor_speed', address: 0x20000000, size: 4),
            ProbeSymbolInfo(
              name: 'sample_counter',
              address: 0x20000004,
              size: 4,
            ),
          ];
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: const MaterialApp(home: Scaffold(body: ProbePlotPage())),
      ),
    );

    await tester.tap(find.byTooltip('HSS 数据配置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hss-symbol-search')), findsOneWidget);
    expect(find.text('motor_speed'), findsOneWidget);
    expect(find.text('sample_counter'), findsOneWidget);
    for (final key in [
      'hss-frequency-field',
      'hss-symbol-search',
      'hss-name-field',
      'hss-address-field',
      'hss-type-dropdown',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        kSecondaryDialogControlHeight,
      );
    }

    await tester.enterText(
      find.byKey(const ValueKey('hss-symbol-search')),
      'motor',
    );
    await tester.pump();
    expect(find.text('motor_speed'), findsOneWidget);
    expect(find.text('sample_counter'), findsNothing);

    await tester.tap(find.text('motor_speed'));
    await tester.pump();
    expect(viewModel.hssVariables.single.name, 'motor_speed');
    expect(viewModel.activeChannelCount, 1);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('motor_speed'), findsOneWidget);
    expect(find.text('Value 2'), findsNothing);

    final modeSelector = find.byType(SegmentedButton<ProbePlotMode>);
    expect(tester.getSize(modeSelector).height, lessThanOrEqualTo(24));
    final modeRect = tester.getRect(modeSelector);
    final hssCenter = tester.getCenter(find.text('HSS'));
    final rttCenter = tester.getCenter(find.text('RTT'));
    expect((hssCenter.dx + rttCenter.dx) / 2, closeTo(modeRect.center.dx, 1));
    // 字形边界与 24px SegmentedButton 的视觉中心存在少量字体度量差异；
    // 控件通过 1px 光学校正后允许不同测试字体环境保留 3px 以内偏差。
    expect(hssCenter.dy, closeTo(modeRect.center.dy, 3.1));
    expect(rttCenter.dy, closeTo(modeRect.center.dy, 3.1));
    expect(find.byTooltip(AppStrings.plot.measureXxTooltip), findsOneWidget);
    expect(find.byTooltip(AppStrings.plot.measureYyTooltip), findsOneWidget);
    expect(find.text(AppStrings.plot.cursor), findsNothing);
    expect(find.text(AppStrings.plot.measureXx), findsNothing);
    expect(find.text(AppStrings.plot.measureYy), findsNothing);
    expect(find.text(AppStrings.plot.follow), findsNothing);
    expect(find.byTooltip(AppStrings.plot.fitY), findsNothing);
    expect(
      tester.getCenter(find.byTooltip(AppStrings.plot.verticalCursor)).dx,
      lessThan(tester.getCenter(find.byTooltip(AppStrings.plot.zoomXIn)).dx),
    );
    expect(
      tester.getCenter(find.byTooltip(AppStrings.plot.followTooltip)).dx,
      lessThan(tester.getCenter(find.byTooltip(AppStrings.plot.zoomXIn)).dx),
    );

    await tester.tap(find.byTooltip(AppStrings.plot.collapseChannelPanel));
    await tester.pump();
    expect(find.byTooltip(AppStrings.plot.expandChannelPanel), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.plot.legend));
    await tester.pump();
    expect(find.byKey(const ValueKey('probe-plot-legend-box')), findsOneWidget);
    expect(find.byTooltip(AppStrings.plot.liveValues), findsOneWidget);

    viewModel.pointCount = 1;
    viewModel.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('RTT'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将清空当前绘图数据'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(viewModel.mode, ProbePlotMode.hss);
    expect(viewModel.pointCount, 1);

    await tester.tap(find.text('RTT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空并切换'));
    await tester.pumpAndSettle();
    expect(viewModel.mode, ProbePlotMode.rtt);
    expect(viewModel.pointCount, 0);
  });

  testWidgets('光标右键跳转在弹窗关闭后更新页面且不触发生命周期异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = RttService(
      connectionOwners: ConnectionOwnerService(),
      backends: [],
    );
    final viewModel = _JumpProbePlotViewModel(service);
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbePlotViewModel>.value(
        value: viewModel,
        child: const MaterialApp(home: Scaffold(body: ProbePlotPage())),
      ),
    );

    final cursorButton = find.byTooltip(AppStrings.plot.verticalCursor);
    final position = tester.getCenter(cursorButton);
    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.addPointer(location: position);
    await secondary.down(position);
    await secondary.up();
    await secondary.removePointer();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('probe-cursor-jump-input')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('probe-cursor-jump-input')),
      '7',
    );
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();

    expect(viewModel.jumpedIndex, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTT 数据配置集中控制块、通道和格式，右侧仅保留绘图设置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = RttService(
      connectionOwners: ConnectionOwnerService(),
      backends: const [],
    );
    final viewModel = ProbePlotViewModel(service);
    addTearDown(() {
      viewModel.dispose();
      service.dispose();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ProbePlotViewModel>.value(
        value: viewModel,
        child: const MaterialApp(home: Scaffold(body: ProbePlotPage())),
      ),
    );

    await tester.tap(find.byTooltip('RTT 数据配置'));
    await tester.pumpAndSettle();
    expect(find.text('RTT 数据配置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('probe-rtt-control-block-mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('probe-rtt-refresh-channels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('probe-rtt-polling-interval')),
      findsOneWidget,
    );
    expect(find.text('J-Scope 数据格式'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('探针绘图设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsNavigationView), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).shape,
      kAdvancedSettingsDialogShape,
    );
    for (final category in ['外观', '性能', '文字', '视口', '交互', '数据']) {
      expect(find.text(category), findsOneWidget);
    }
    expect(find.text('精确窗口点数上限'), findsOneWidget);
    expect(find.text(AppStrings.plot.plotHistoryMemoryLimit), findsOneWidget);
    expect(find.text(AppStrings.plot.lodQuality), findsOneWidget);
    expect(
      find.byKey(const ValueKey('probe-plot-lod-quality-selector')),
      findsOneWidget,
    );
    expect(find.text(AppStrings.plot.floatingPanelOpacity), findsOneWidget);
    expect(find.text('跟随位置'), findsOneWidget);
    expect(find.text(AppStrings.plot.observationClickToPlace), findsOneWidget);
    for (final key in [
      'probe-floating-panel-opacity-field',
      'probe-follow-position-field',
      'probe-history-memory-limit-field',
      'probe-window-point-limit-field',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        kSecondaryDialogControlHeight,
      );
    }
    await tester.enterText(
      find.byKey(const ValueKey('probe-floating-panel-opacity-field')),
      '75',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(viewModel.floatingPanelOpacity, 0.75);
    await tester.tap(find.text(AppStrings.common.close));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byTooltip('探针绘图设置'),
        matching: find.byIcon(Icons.tune),
      ),
      findsOneWidget,
    );
  });
}
