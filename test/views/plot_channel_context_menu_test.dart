import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';

void main() {
  testWidgets('普通通道右键菜单可打开通道高级设置', (tester) async {
    final serialService = SerialService();
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
    serialService.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });
}
