import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/constants/plot_configuration.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/core/theme/app_theme.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';
import 'package:vscope_serial/data/models/math_channel_config.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';
import 'package:vscope_serial/data/models/plot_render_engine.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';
import 'package:vscope_serial/views/widgets/plot_status_bar.dart';

void main() {
  final connectionService = DataConnectionService();

  setUp(() {
    final settings = AppSettings();
    settings.parserType = 'fireWater';
    settings.sendProtocolType = 'none';
    settings.plotRenderEngine = 'canvas';
    settings.rChannelAddresses = List.filled(16, '');
    settings.rProtocolLooseChannelSettings = false;
    settings.plotLodQuality = 'performance';
    settings.plotReceiveAggregationEnabled = false;
    settings.plotHistoryMemoryLimitGiB = 2;
    settings.xMeasurementLine1Color = null;
    settings.xMeasurementLine2Color = null;
    settings.yMeasurementLine1Color = null;
    settings.yMeasurementLine2Color = null;
    settings.xMeasurementLine1Opacity = 1;
    settings.xMeasurementLine2Opacity = 1;
    settings.yMeasurementLine1Opacity = 1;
    settings.yMeasurementLine2Opacity = 1;
    settings.yMeasurementSnapEnabled = true;
    settings.mathChannels = MathChannelConfig.createDefaults();
    settings.zobowChannelIds = List.generate(
      ParserConfig.maxZobowChannelCount,
      (index) => index + 1,
    );
    settings.channelPresetBindings = [];
  });

  tearDownAll(connectionService.dispose);

  testWidgets('绘图状态栏在窄窗口中单行截断长文本', (tester) async {
    final vm = PlotViewModel(connectionService);
    for (var i = 0; i < 32; i++) {
      vm.ingestParsedResultForTest(
        ParseResult.ok([i.toDouble()], bytesConsumed: 4),
      );
    }
    vm.setVCursorEnabled(true);
    vm.updateCursor(CursorState(x: 10, y: 10, hasData: true));

    await tester.binding.setSurfaceSize(const Size(280, 80));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: PlotStatusBar()),
        ),
      ),
    );

    final status = tester.widget<Text>(
      find.byKey(const ValueKey('plot-status-text')),
    );
    expect(status.maxLines, 1);
    expect(status.overflow, TextOverflow.ellipsis);
    expect(find.textContaining('Ch0:'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump();
  });

  testWidgets('统计浮窗通道名称使用对应通道颜色', (tester) async {
    final vm = PlotViewModel(connectionService);
    vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 4));
    vm.ingestParsedResultForTest(ParseResult.ok([2], bytesConsumed: 4));
    vm.toggleStats();

    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    await tester.pump();

    final expectedColor = vm.displayChannels.first.color;
    final channelSpan = tester
        .widgetList<RichText>(find.byType(RichText))
        .expand(
          (widget) =>
              widget.text is TextSpan
                  ? (widget.text as TextSpan).children ?? const <InlineSpan>[]
                  : const <InlineSpan>[],
        )
        .whereType<TextSpan>()
        .firstWhere((span) => span.text?.startsWith('Ch0:') ?? false);
    expect(channelSpan.style?.color, expectedColor);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump();
  });

  testWidgets('高级设置可切换绘图质量', (tester) async {
    final vm = PlotViewModel(connectionService);

    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    expect(find.textContaining('FPS:'), findsOneWidget);
    expect(find.text(AppStrings.plot.advancedSettings), findsNothing);

    await tester.tap(find.byTooltip(AppStrings.plot.advancedSettings).last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-navigation-view')),
      findsOneWidget,
    );
    await tester.tap(find.text('性能'));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.plot.lodQuality), findsOneWidget);
    expect(find.text(AppStrings.plot.lodQualityBalanced), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plotLodQualitySelector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('plotRenderEngineSelector')),
      findsOneWidget,
    );
    final receiveAggregationToggle = find.byKey(
      const ValueKey('plot-receive-aggregation-toggle'),
    );
    expect(receiveAggregationToggle, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: receiveAggregationToggle,
        matching: find.byType(Switch),
      ),
    );
    await tester.pump();
    expect(AppSettings().plotReceiveAggregationEnabled, isFalse);

    await tester.tap(find.text(AppStrings.plot.lodQualityBalanced));
    await tester.pumpAndSettle();

    expect(vm.lodQuality, PlotLodQuality.performance);

    await tester.tap(find.text(AppStrings.plot.lodQualityQuality));
    final renderEngineSelector = find.byKey(
      const ValueKey('plotRenderEngineSelector'),
    );
    await tester.ensureVisible(renderEngineSelector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: renderEngineSelector,
        matching: find.text(AppStrings.plot.renderEngineD3d11),
      ),
    );
    await tester.pumpAndSettle();

    expect(vm.lodQuality, PlotLodQuality.performance);
    expect(vm.renderEngine, PlotRenderEngine.canvas);
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(vm.lodQuality, PlotLodQuality.quality);
    expect(vm.renderEngine, PlotRenderEngine.d3d11);
    expect(AppSettings().plotReceiveAggregationEnabled, isTrue);

    await tester.tap(find.byTooltip(AppStrings.plot.advancedSettings).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据'));
    await tester.pumpAndSettle();
    final retentionField = find.byKey(
      const ValueKey('plot-retention-limit-field'),
    );
    expect(retentionField, findsOneWidget);
    await tester.enterText(retentionField, '8');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(vm.plotRetentionLimitGiB, isNot(8));
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(vm.plotRetentionLimitGiB, 8);
    expect(AppSettings().plotHistoryMemoryLimitGiB, 8);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('Delta X/Y 按钮右键可配置线条且 Y 提供吸附开关', (tester) async {
    final vm = PlotViewModel(connectionService);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    expect(AppStrings.plot.measureXxTooltip, contains('右键'));
    expect(AppStrings.plot.measureYyTooltip, contains('右键'));
    expect(find.byKey(const ValueKey('plot-measure-x-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('plot-measure-y-button')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('plot-measure-x-button')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.plot.measureXSettings), findsOneWidget);
    expect(find.byKey(const ValueKey('x-measure-line1-color')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('x-measure-line2-opacity')),
      findsOneWidget,
    );
    final x1Opacity = find.byKey(const ValueKey('x-measure-line1-opacity'));
    await tester.enterText(x1Opacity, '35');
    await tester.tap(find.byKey(const ValueKey('x-measure-settings-save')));
    await tester.pumpAndSettle();
    expect(vm.xMeasurementLine1Opacity, 0.35);

    await tester.tap(
      find.byKey(const ValueKey('plot-measure-y-button')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.plot.measureYSettings), findsOneWidget);
    final snapToggle = find.byKey(const ValueKey('y-measure-snap-toggle'));
    expect(snapToggle, findsOneWidget);
    expect(vm.yMeasurementSnapEnabled, isTrue);
    await tester.tap(
      find.descendant(of: snapToggle, matching: find.byType(Switch)),
    );
    await tester.tap(find.byKey(const ValueKey('y-measure-settings-save')));
    await tester.pumpAndSettle();
    expect(vm.yMeasurementSnapEnabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('图例按最长通道名称扩展以优先显示完整名称', (tester) async {
    final vm = PlotViewModel(connectionService);
    const longName = '主电机控制器输出电流反馈滤波后的完整通道名称';
    vm.setChannelAlias(0, longName);
    vm.ingestParsedResultForTest(ParseResult.ok(const [1.0], bytesConsumed: 4));

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byTooltip(AppStrings.plot.legend).hitTestable().first,
    );
    await tester.pump();

    final legend = find.byKey(const ValueKey('plot-legend-box'));
    expect(legend, findsOneWidget);
    expect(
      find.descendant(of: legend, matching: find.text(longName)),
      findsOneWidget,
    );
    final nameFinder = find.descendant(
      of: legend,
      matching: find.text(longName),
    );
    final nameText = tester.widget<Text>(nameFinder);
    final textPainter = TextPainter(
      text: TextSpan(text: longName, style: nameText.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    addTearDown(textPainter.dispose);
    expect(
      tester.getSize(nameFinder).width,
      greaterThanOrEqualTo(textPainter.width),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('800px 绘图工具栏将右侧工具折叠到更多菜单且不溢出', (tester) async {
    final vm = PlotViewModel(connectionService);
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('plot-start-stop-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('toolbar-more-button')), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('toolbar-more-button')).last);
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.plot.fitAll), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('折叠到更多菜单的测量工具仍响应右键设置', (tester) async {
    final vm = PlotViewModel(connectionService);
    await tester.binding.setSurfaceSize(const Size(500, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('toolbar-more-button')).last);
    await tester.pump();
    await tester.tap(
      find.text(AppStrings.plot.measureXx),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.plot.measureXSettings), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('导出窗口同时选择范围和普通数学通道', (tester) async {
    final vm = PlotViewModel(connectionService);
    vm.ingestParsedResultForTest(ParseResult.ok([1, 2], bytesConsumed: 1));
    expect(
      vm.configureMathChannel(0, 'CH0 + CH1', vm.mathChannels[0].display),
      isTrue,
    );

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    await tester.tap(find.byTooltip(AppStrings.plot.exportDataTooltip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.plot.csvText));
    await tester.pumpAndSettle();

    expect(find.text('导出范围与通道'), findsOneWidget);
    expect(find.text('起始点'), findsOneWidget);
    expect(find.text('结束点'), findsOneWidget);
    expect(find.text('Ch0'), findsWidgets);
    expect(find.text('CH0 + CH1'), findsOneWidget);
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((tile) => tile.value == true),
      isTrue,
    );

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('请至少选择 1 个通道'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('普通通道设置可输入显示参数并与列表共用偏置开关', (tester) async {
    final vm = PlotViewModel(connectionService);

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
    final lineWidthField = find.byKey(
      const ValueKey('channel-line-width-field'),
    );
    final pointRadiusField = find.byKey(
      const ValueKey('channel-point-radius-field'),
    );
    expect(lineWidthField, findsOneWidget);
    expect(pointRadiusField, findsOneWidget);
    await tester.enterText(lineWidthField, '2.5');
    await tester.enterText(pointRadiusField, '4.5');

    final offsetToggle = find.byKey(const ValueKey('channel-offset-toggle'));
    expect(tester.widget<Switch>(offsetToggle).value, isFalse);
    await tester.tap(offsetToggle);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('channel-offset-field')),
      '-12.5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('channel-scale-field')),
      '2',
    );
    await tester.tap(find.text(AppStrings.common.confirm));
    await tester.pumpAndSettle();

    expect(vm.channels[0].lineWidth, 2.5);
    expect(vm.channels[0].pointSize, 4.5);
    expect(vm.channels[0].offsetEnabled, isTrue);
    expect(vm.channels[0].yOffset, -12.5);
    expect(vm.channels[0].yScale, 2);
    expect(find.byTooltip(AppStrings.plot.closeOffset), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('发送协议配置只在显式选择r协议时可打开', (tester) async {
    final vm = PlotViewModel(connectionService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    Finder configIconButton() => find.descendant(
      of: find.byKey(const ValueKey('send-protocol-config-button')),
      matching: find.byType(IconButton),
    );

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
    final vm = PlotViewModel(connectionService);

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
    final vm = PlotViewModel(connectionService);
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

  testWidgets('通道列表名称编辑支持统一的64字符上限', (tester) async {
    final vm = PlotViewModel(connectionService);
    const longName = '主电机控制器输出电流反馈滤波后的完整通道名称与工程标识';

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    final channelName = find.text('Ch0').first;
    await tester.tap(channelName);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(channelName);
    await tester.pump();
    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.maxLength == PlotConfiguration.channelAliasMaxLength,
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, longName);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(vm.channels[0].alias, longName);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('JustFloat配合R协议选择预设后立即刷新名称和地址', (tester) async {
    final vm = PlotViewModel(connectionService);
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
    final vm = PlotViewModel(connectionService);

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
    final vm = PlotViewModel(connectionService);
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
    final vm = PlotViewModel(connectionService);

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
    final vm = PlotViewModel(connectionService);

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
    final vm = PlotViewModel(connectionService);

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
    final vm = PlotViewModel(connectionService);
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
      find.descendant(
        of: find.byKey(const ValueKey('plot-import-data-button')),
        matching: find.byType(IconButton),
      ),
    );
    IconButton exportButton() => tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('plot-export-data-button')),
        matching: find.byType(IconButton),
      ),
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
    final vm = PlotViewModel(connectionService);
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

    expect(
      keyed<ToolbarToggleTextButton>('plot-random-source-checkbox').onPressed,
      isNotNull,
    );
    expect(
      keyed<ToolbarDropdown<ParserType>>('plot-parser-selector').onChanged,
      isNotNull,
    );
    expect(
      keyed<ToolbarIconButton>('plot-parser-config-button').onPressed,
      isNotNull,
    );
    expect(
      keyed<ToolbarDropdown<SendProtocolType>>(
        'plot-send-protocol-selector',
      ).onChanged,
      isNotNull,
    );
    expect(
      keyed<ToolbarIconButton>('send-protocol-config-button').onPressed,
      isNotNull,
    );
    expect(
      keyed<ToolbarDropdown<String?>>('plot-r-profile-selector').onChanged,
      isNotNull,
    );

    vm.setPlottingForTest(true);
    vm.notifyListeners();
    await tester.pump();

    expect(
      keyed<ToolbarToggleTextButton>('plot-random-source-checkbox').onPressed,
      isNull,
    );
    expect(
      keyed<ToolbarDropdown<ParserType>>('plot-parser-selector').onChanged,
      isNull,
    );
    expect(
      keyed<ToolbarIconButton>('plot-parser-config-button').onPressed,
      isNull,
    );
    expect(
      keyed<ToolbarDropdown<SendProtocolType>>(
        'plot-send-protocol-selector',
      ).onChanged,
      isNull,
    );
    expect(
      keyed<ToolbarIconButton>('send-protocol-config-button').onPressed,
      isNull,
    );
    expect(
      keyed<ToolbarDropdown<String?>>('plot-r-profile-selector').onChanged,
      isNull,
    );
    expect(
      keyed<ToolbarIconButton>('plot-create-r-profile-button').onPressed,
      isNull,
    );
    expect(
      keyed<ToolbarIconButton>('plot-edit-r-profile-button').onPressed,
      isNull,
    );
    expect(
      keyed<ToolbarIconButton>('plot-random-frequency-button').onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('无数据时使用统一浅色空态，收到数据后应用暗色背景', (tester) async {
    final vm = PlotViewModel(connectionService);
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

    expect(emptyBackground().color, AppTheme.pageBackgroundColor);

    vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 1));
    vm.notifyListeners();
    await tester.pump();

    expect(find.byKey(const ValueKey('plot-empty-background')), findsNothing);
    final backgroundPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const ValueKey('plot-layer-background')),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(
      (backgroundPaint.painter! as PlotLayerPainter).backgroundStyle,
      PlotBackgroundStyle.dark,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}
