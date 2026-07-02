import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/views/dialogs/status_dialog.dart';

void main() {
  final service = SerialService();

  tearDown(() {
    service.debugPortEnumerator = null;
    service.debugPortDetailsEnumerator = null;
    service.config = SerialConfig();
  });

  testWidgets('串口详细信息默认关闭且只在勾选后刷新', (tester) async {
    var detailCalls = 0;
    service
      ..config = SerialConfig(port: 'COM7')
      ..debugPortEnumerator = () async {
        return ['COM7'];
      }
      ..debugPortDetailsEnumerator = () async {
        detailCalls++;
        return const [
          NativeSerialPortDetail(port: 'COM7', name: 'USB Serial Port (COM7)'),
        ];
      };

    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: StatusDialog())),
      ),
    );
    await tester.pumpAndSettle();

    final checkboxFinder = find.byKey(
      const ValueKey('show-port-details-checkbox'),
    );
    expect(tester.widget<Checkbox>(checkboxFinder).value, isFalse);
    expect(find.text('COM7'), findsOneWidget);
    expect(detailCalls, 0);

    await tester.tap(checkboxFinder);
    await tester.pump();
    expect(tester.widget<Checkbox>(checkboxFinder).value, isTrue);
    expect(detailCalls, 0);

    await tester.tap(
      find.widgetWithText(ElevatedButton, AppStrings.common.refresh),
    );
    await tester.pumpAndSettle();

    expect(detailCalls, 1);
    expect(find.text('COM7: USB Serial Port'), findsOneWidget);
  });
}
