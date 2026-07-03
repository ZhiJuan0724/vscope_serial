import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

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

  testWidgets('长通道名称提供悬浮完整文本', (tester) async {
    final vm = PlotViewModel(serialService);
    const longName = '这是一个很长的通道名称';
    vm.setChannelAlias(0, longName);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    expect(find.byTooltip(longName), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('JustFloat配合R协议选择预设后立即刷新名称和地址', (tester) async {
    final vm = PlotViewModel(serialService);
    vm.setParserType(ParserType.justFloat);
    vm.updateParserConfig(ParserConfig.justFloatDefault());
    vm.setSendProtocolType(SendProtocolType.rProtocol);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    vm.applyRProtocolPresetToChannel(
      0,
      AddressChannelPreset(
        name: '电机反馈',
        address: 16,
        addressFormat: AddressValueFormat.decimal,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('电机反馈'), findsOneWidget);
    expect(find.widgetWithText(TextField, '16'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('通道列表空白处右键显示重置全部通道', (tester) async {
    final vm = PlotViewModel(serialService);

    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    final list = find.byType(ListView).first;
    final blankPosition = tester.getBottomLeft(list) + const Offset(100, -16);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(blankPosition);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.resetAllChannels), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('偏置通道右键可打开绑定偏置设置', (tester) async {
    final vm = PlotViewModel(serialService);
    vm.setChannelOffsetEnabled(0, true);
    vm.setChannelOffsetEnabled(1, true);

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

    expect(find.text(AppStrings.plot.offsetBinding), findsOneWidget);

    await tester.tap(find.text(AppStrings.plot.offsetBinding));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(AppStrings.plot.offsetBindingTitle),
      findsOneWidget,
    );
    expect(find.widgetWithText(CheckboxListTile, 'Ch1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('未开启偏置的通道右键不显示绑定偏置', (tester) async {
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
    expect(find.text(AppStrings.plot.offsetBinding), findsNothing);

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

    expect(find.text(AppStrings.plot.liveValues), findsOneWidget);
    expect(find.text('暂无数据').evaluate().length, emptyTextCountBefore);
    expect(
      find.byKey(const ValueKey('plot-live-values-content')),
      findsNothing,
    );

    vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 4));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.plot.liveValues), findsNWidgets(2));
    final liveValuesContent = tester.widget<SizedBox>(
      find.byKey(const ValueKey('plot-live-values-content')),
    );
    expect(liveValuesContent.width, 120);

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

  testWidgets('绘图运行时禁用数据导入和导出', (tester) async {
    final vm = PlotViewModel(serialService);
    vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 4));

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    IconButton importButton() => tester.widget<IconButton>(
      find.byKey(const ValueKey('plot-import-data-button')),
    );
    IconButton exportButton() => tester.widget<IconButton>(
      find.byKey(const ValueKey('plot-export-data-button')),
    );

    expect(importButton().onPressed, isNotNull);
    expect(exportButton().onPressed, isNotNull);

    vm.setPlottingForTest(true);
    vm.notifyListeners();
    await tester.pump();

    expect(importButton().onPressed, isNull);
    expect(exportButton().onPressed, isNull);

    vm.setPlottingForTest(false);
    vm.notifyListeners();
    await tester.pump();

    expect(importButton().onPressed, isNotNull);
    expect(exportButton().onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('绘图运行时锁定随机源开关、协议及配置入口', (tester) async {
    final vm = PlotViewModel(serialService);
    vm.setParserType(ParserType.fireWater);
    vm.setSendProtocolType(SendProtocolType.rProtocol);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    T keyed<T extends Widget>(String key) =>
        tester.widget<T>(find.byKey(ValueKey(key)));

    expect(keyed<Checkbox>('plot-random-source-checkbox').onChanged, isNotNull);
    expect(
      keyed<NoAnimDropdown<ParserType>>('plot-parser-selector').onChanged,
      isNotNull,
    );
    expect(keyed<IconButton>('plot-parser-config-button').onPressed, isNotNull);
    expect(
      keyed<NoAnimDropdown<SendProtocolType>>(
        'plot-send-protocol-selector',
      ).onChanged,
      isNotNull,
    );
    expect(
      keyed<IconButton>('send-protocol-config-button').onPressed,
      isNotNull,
    );
    expect(
      keyed<NoAnimDropdown<String?>>('plot-r-profile-selector').onChanged,
      isNotNull,
    );

    vm.setPlottingForTest(true);
    vm.notifyListeners();
    await tester.pump();

    expect(keyed<Checkbox>('plot-random-source-checkbox').onChanged, isNull);
    expect(
      keyed<NoAnimDropdown<ParserType>>('plot-parser-selector').onChanged,
      isNull,
    );
    expect(keyed<IconButton>('plot-parser-config-button').onPressed, isNull);
    expect(
      keyed<NoAnimDropdown<SendProtocolType>>(
        'plot-send-protocol-selector',
      ).onChanged,
      isNull,
    );
    expect(keyed<IconButton>('send-protocol-config-button').onPressed, isNull);
    expect(
      keyed<NoAnimDropdown<String?>>('plot-r-profile-selector').onChanged,
      isNull,
    );
    expect(keyed<InkWell>('plot-create-r-profile-button').onTap, isNull);
    expect(keyed<InkWell>('plot-edit-r-profile-button').onTap, isNull);
    expect(keyed<InkWell>('plot-random-frequency-button').onTap, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('未开始绘图时背景跟随暗色和亮色设置', (tester) async {
    final vm = PlotViewModel(serialService);
    vm.setPlotBackground('dark');

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    ColoredBox emptyBackground() => tester.widget<ColoredBox>(
      find.byKey(const ValueKey('plot-empty-background')),
    );

    expect(emptyBackground().color, const Color(0xFF1A1A2E));

    vm.setPlotBackground('light');
    await tester.pumpAndSettle();

    expect(emptyBackground().color, const Color(0xFFF8FAFC));

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}
