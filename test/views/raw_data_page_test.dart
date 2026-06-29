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
    // 虚拟列表跳到底部后，需要下一帧构建新的可见行。
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(service.receivedLines.first, 'line0');
    expect(service.receivedLines.last, 'line99');
    expect(find.text('line99'), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('关闭自动滚动后淘汰最旧行会保持当前视口', (tester) async {
    final service = SerialService();
    service.clearReceivedData();
    service.autoScroll = false;
    service.setDisplayLineLimit(100);
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
    await tester.pump(const Duration(milliseconds: 20));

    final receiveScrollable = find.descendant(
      of: find.byKey(const Key('rawDataReceiveTextField')),
      matching: find.byType(Scrollable),
    );
    final scrollable = tester.state<ScrollableState>(receiveScrollable);
    scrollable.position.jumpTo(300);
    await tester.pump();
    final previousOffset = scrollable.position.pixels;

    service.debugAddRawReceiveData(Uint8List.fromList(utf8.encode('latest\n')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(service.receivedLines.first, 'line1');
    expect(service.receivedLines.last, 'latest');
    expect(scrollable.position.pixels, lessThan(previousOffset - 5));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Shell模式隐藏普通发送区并显示终端操作', (tester) async {
    final service = SerialService();
    service.clearReceivedData();
    service.setRawDataShellEnabled(true);
    service.setRawDataShellMode(true);
    service.setRawShellInputMode(RawShellInputMode.line);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );

    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('发送文件'), findsNothing);
    expect(find.text('接收文件'), findsNothing);
    expect(find.text('发送数据'), findsNothing);
    expect(find.text('输入命令后按 Enter 发送'), findsOneWidget);

    await tester.tap(find.byTooltip('更多选项'));
    await tester.pumpAndSettle();

    expect(find.text('更多功能'), findsOneWidget);
    expect(find.text('文件发送/接收'), findsOneWidget);
    expect(find.text('发送文件'), findsNothing);
    expect(find.text('接收文件'), findsNothing);
    expect(find.text('取消传输'), findsNothing);

    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普通收发默认隐藏Shell入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final service = SerialService();
    service.clearReceivedData();
    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );

    expect(find.widgetWithText(FilterChip, 'Shell'), findsNothing);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用 Shell 模式入口'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilterChip, 'Shell'), findsOneWidget);

    service.setRawDataShellEnabled(false);
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普通收发高级设置未变化时不显示保存提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    final service = SerialService();
    service.clearReceivedData();
    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);
    service.setDisplayLineLimit(SerialService.defaultDisplayLineLimit);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.textContaining('高级设置已保存'), findsNothing);

    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
