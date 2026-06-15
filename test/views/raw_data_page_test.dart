import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/views/pages/raw_data_page.dart';

void main() {
  testWidgets('开启自动滚动时保持在最新行', (tester) async {
    final service = SerialService();
    service.clearReceivedData();
    service.autoScroll = true;
    service.setDisplayLineLimit(SerialService.defaultDisplayLineLimit);
    for (var i = 0; i < 100; i++) {
      service.debugAddRawReceiveData(
        Uint8List.fromList(utf8.encode('line$i\n')),
      );
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final receiveText = tester.widget<SelectableText>(
      find.descendant(
        of: find.byKey(const Key('rawDataReceiveTextField')),
        matching: find.byType(SelectableText),
      ),
    );
    expect(receiveText.data, contains('line0\nline1'));
    expect(receiveText.data, endsWith('line99'));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);

    service.debugAddRawReceiveData(Uint8List.fromList(utf8.encode('latest\n')));
    await tester.pump();
    await tester.pump();

    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);

    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();

    expect(service.autoScroll, isFalse);

    scrollable.position.jumpTo(0);
    service.debugAddRawReceiveData(
      Uint8List.fromList(utf8.encode('after-disabled\n')),
    );
    await tester.pump();
    await tester.pump();

    expect(scrollable.position.pixels, 0);

    service.clearReceivedData();
    service.autoScroll = true;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
