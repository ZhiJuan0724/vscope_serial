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

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}
