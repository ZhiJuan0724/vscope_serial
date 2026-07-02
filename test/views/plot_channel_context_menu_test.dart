import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';

void main() {
  final serialService = SerialService();

  tearDownAll(serialService.dispose);

  testWidgets('普通通道右键菜单可打开通道高级设置', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    final channelCenter = tester.getCenter(find.text('Ch0'));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(channelCenter);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.editChannel), findsOneWidget);

    await tester.tap(find.text(AppStrings.plot.editChannel));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.editChannelTitle(0)), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('发送协议配置只在显式选择r协议时可打开', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    Finder configIconButton() =>
        find.byKey(const ValueKey('send-protocol-config-button'));

    final configButton = tester.widget<IconButton>(configIconButton());
    expect(configButton.onPressed, isNull);

    vm.setSendProtocolType(SendProtocolType.rProtocol);
    await tester.pumpAndSettle();

    final enabledConfigButton = tester.widget<IconButton>(configIconButton());
    expect(enabledConfigButton.onPressed, isNotNull);

    await tester.tap(find.byTooltip(AppStrings.plot.sendProtocolConfig));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.rProtocolLooseChannelSettings), findsOne);

    await tester.tap(find.text(AppStrings.common.close));
    await tester.pumpAndSettle();

    vm.setParserType(ParserType.zobow);
    await tester.pumpAndSettle();

    expect(vm.sendProtocolType, SendProtocolType.rProtocol);
    expect(vm.effectiveSendProtocolType, SendProtocolType.zobowBuiltIn);
    final zobowConfigButton = tester.widget<IconButton>(configIconButton());
    expect(zobowConfigButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('通道显示开关使用眼睛图标并可切换显示状态', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    expect(vm.channels[0].visible, isTrue);
    expect(find.byIcon(Icons.visibility_outlined), findsWidgets);

    await tester.tap(find.byTooltip(AppStrings.plot.hideChannel).first);
    await tester.pumpAndSettle();

    expect(vm.channels[0].visible, isFalse);
    expect(find.byIcon(Icons.visibility_off_outlined), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('表头显示图标在全部通道隐藏后才变为闭眼', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    await tester.tap(find.byTooltip(AppStrings.plot.hideChannel).first);
    await tester.pumpAndSettle();

    expect(vm.channels[0].visible, isFalse);
    expect(find.byTooltip(AppStrings.plot.hideAllChannels), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.plot.hideAllChannels));
    await tester.pumpAndSettle();

    expect(vm.channels.every((channel) => !channel.visible), isTrue);
    expect(find.byTooltip(AppStrings.plot.showAllChannels), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('实时值按钮可打开最新值浮窗', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    expect(find.text(AppStrings.plot.liveValues), findsOneWidget);
    final emptyTextCountBefore = find.text('暂无数据').evaluate().length;

    await tester.tap(find.byTooltip(AppStrings.plot.liveValues));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.liveValues), findsNWidgets(2));
    expect(find.text('暂无数据').evaluate().length, emptyTextCountBefore + 1);

    vm.setPlotBackground('light');
    await tester.pumpAndSettle();

    final liveValueTitle = find.text(AppStrings.plot.liveValues).last;
    final liveValueContainers = tester.widgetList<Container>(
      find.ancestor(of: liveValueTitle, matching: find.byType(Container)),
    );
    expect(
      liveValueContainers.any(
        (container) =>
            container.decoration is BoxDecoration &&
            (container.decoration! as BoxDecoration).color ==
                Colors.white.withValues(alpha: vm.floatingPanelOpacity),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}
