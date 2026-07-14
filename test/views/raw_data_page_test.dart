import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/views/pages/raw_data_page.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('发送工具栏在扩展过渡宽度下自动换行且不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = SerialService();
    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );
    await tester.pump();

    expect(find.text('扩展'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('扩展面板在窗口扩宽前离屏布局且主区域宽度保持不变', (tester) async {
    const windowChannel = MethodChannel('window_manager');
    const screenChannel = MethodChannel(
      'dev.leanflutter.plugins/screen_retriever',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final allowExpansion = Completer<void>();
    final expansionRequested = Completer<void>();
    var bounds = <String, double>{
      'x': 100,
      'y': 100,
      'width': 1000,
      'height': 700,
    };

    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() async {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(screenChannel, null);
      await tester.binding.setSurfaceSize(null);
    });
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      if (call.method != 'getAllDisplays') return null;
      return {
        'displays': [
          {
            'id': '0',
            'name': 'test-display',
            'size': {'width': 1920.0, 'height': 1080.0},
            'visiblePosition': {'dx': 0.0, 'dy': 0.0},
            'visibleSize': {'width': 1920.0, 'height': 1040.0},
            'scaleFactor': 1.0,
          },
        ],
      };
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isMaximized':
          return false;
        case 'getBounds':
          return bounds;
        case 'setMinimumSize':
          return true;
        case 'setBounds':
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final width = (arguments['width'] as num).toDouble();
          final height = (arguments['height'] as num).toDouble();
          if (width > bounds['width']! && !expansionRequested.isCompleted) {
            expansionRequested.complete();
            await allowExpansion.future;
          }
          bounds = {
            'x': (arguments['x'] as num).toDouble(),
            'y': (arguments['y'] as num).toDouble(),
            'width': width,
            'height': height,
          };
          await tester.binding.setSurfaceSize(Size(width, height));
          return true;
      }
      return true;
    });

    final service = SerialService();
    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);
    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );
    await tester.pump();

    final mainContent = find.byKey(const ValueKey('raw-data-main-content'));
    final panel = find.byKey(const ValueKey('multi-send-panel'));
    expect(tester.getSize(mainContent).width, 1000);

    await tester.tap(find.byKey(const ValueKey('multi-send-toggle')));
    for (var i = 0; i < 50 && !expansionRequested.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(expansionRequested.isCompleted, isTrue);
    expect(tester.getSize(mainContent).width, 1000);
    expect(tester.getTopLeft(panel).dx, 1000);

    allowExpansion.complete();
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(bounds['width'], 1380);
    expect(tester.getSize(mainContent).width, 1000);
    expect(tester.getTopLeft(panel).dx, 1000);

    await tester.tap(find.byKey(const ValueKey('multi-send-toggle')));
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(bounds['width'], 1000);
    expect(find.byKey(const ValueKey('multi-send-panel')), findsNothing);
    expect(tester.getSize(mainContent).width, 1000);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无原始数据时禁用保存按钮，收到数据后恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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

    final exportButtonFinder = find.byKey(
      const ValueKey('raw-data-export-button'),
    );
    expect(tester.widget<TextButton>(exportButtonFinder).onPressed, isNull);
    expect(find.byKey(const ValueKey('raw-data-stats-overlay')), findsNothing);

    service.debugAddRawReceiveData(Uint8List.fromList([1, 2, 3]));
    await tester.pump(const Duration(milliseconds: 20));

    expect(tester.widget<TextButton>(exportButtonFinder).onPressed, isNotNull);
    expect(
      find.byKey(const ValueKey('raw-data-stats-overlay')),
      findsOneWidget,
    );
    expect(find.textContaining('null'), findsNothing);

    service.clearReceivedData();
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  testWidgets('Shell清屏同时移除可视内容和滚动历史', (tester) async {
    final service = SerialService();
    service.setRawDataShellEnabled(true);
    service.setRawDataShellMode(true);
    service.setRawShellInputMode(RawShellInputMode.line);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );
    await tester.pump();

    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    for (var i = 0; i < 40; i++) {
      terminal.write('old output $i\r\n');
    }
    await tester.pump();
    expect(terminal.buffer.getText(), contains('old output'));

    await tester.tap(find.byTooltip(AppStrings.raw.clearScreen));
    await tester.pump();

    expect(terminal.buffer.getText(), isNot(contains('old output')));
    expect(terminal.buffer.cursorX, 0);
    expect(terminal.buffer.cursorY, 0);

    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Shell逐键模式将方向键和Tab交给终端编码', (tester) async {
    final service = SerialService()..isConnected = true;
    service.setRawDataShellEnabled(true);
    service.setRawDataShellMode(true);
    service.setRawShellInputMode(RawShellInputMode.key);

    await tester.pumpWidget(
      ChangeNotifierProvider<SerialService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: RawDataPage())),
      ),
    );
    await tester.pump();

    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final output = <String>[];
    terminal.onOutput = output.add;
    await tester.tap(find.byType(TerminalView));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);

    expect(output, ['\x1b[A', '\x1b[B', '\x1b[D', '\x1b[C', '\t']);

    service.setRawDataShellMode(false);
    service.setRawDataShellEnabled(false);
    service.isConnected = false;
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
