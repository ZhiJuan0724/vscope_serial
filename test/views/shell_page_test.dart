import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/services/shell_session.dart';
import 'package:vscope_serial/viewmodels/shell_viewmodel.dart';
import 'package:vscope_serial/views/pages/shell_page.dart';
import 'package:xterm/xterm.dart';

class _TestShellViewModel extends ShellViewModel {
  _TestShellViewModel(super.connectionService);

  @override
  Future<void> sendText(String text) async {}
}

void main() {
  late DataConnectionService service;
  late ShellViewModel viewModel;

  setUp(() {
    service = DataConnectionService();
    service.isConnected = false;
    service.releaseActivity(service.activityOwner);
    service.setRawShellInputMode(RawShellInputMode.line);
    viewModel = _TestShellViewModel(service);
  });

  tearDown(() async {
    await service.stopShellReceiving();
    service.isConnected = false;
    viewModel.dispose();
  });

  Widget buildPage({
    int receiveQueueLimitBytes = 256 * 1024 * 1024,
    ValueChanged<LogicalKeyboardKey>? onConnectionShortcut,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DataConnectionService>.value(value: service),
        ChangeNotifierProvider<ShellViewModel>.value(value: viewModel),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ShellPage(
            receiveQueueLimitBytes: receiveQueueLimitBytes,
            onConnectionShortcut: onConnectionShortcut,
          ),
        ),
      ),
    );
  }

  testWidgets('all send controls stay disabled before Shell starts', (
    tester,
  ) async {
    await tester.pumpWidget(buildPage());
    final input = tester.widget<TextField>(find.byType(TextField).first);
    expect(input.enabled, isFalse);
    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('800px toolbar keeps all tools without RenderFlex overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildPage());
    await tester.pump();
    expect(
      find.byKey(const ValueKey('shell-start-stop-button')),
      findsOneWidget,
    );
    expect(find.text('开始'), findsOneWidget);
    expect(find.byTooltip('搜索终端内容'), findsNothing);
    expect(find.byTooltip('重置终端状态'), findsNothing);
    expect(find.byTooltip('导出终端文本'), findsOneWidget);
    expect(find.byTooltip('清屏'), findsOneWidget);
    expect(find.byTooltip(AppStrings.common.shellSettings), findsOneWidget);
    expect(find.text(AppStrings.common.shellSettings), findsNothing);
    expect(find.text('UTF-8  CR'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('encoding and line ending are kept in Shell settings', (
    tester,
  ) async {
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip(AppStrings.common.shellSettings));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-navigation-view')),
      findsOneWidget,
    );
    expect(find.text('输入与编码'), findsOneWidget);
    expect(find.text('外观与光标'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('文本编码'), findsOneWidget);
    expect(find.text('命令行行尾'), findsOneWidget);
    expect(find.text('Shell 配置方案'), findsNothing);
    expect(find.text('CR'), findsWidgets);
    final lineEndingDropdown = find.byKey(
      const ValueKey('shell-line-ending-dropdown'),
    );
    await tester.tap(lineEndingDropdown);
    await tester.pump();
    expect(find.text('CRLF'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('LF').last).dy,
      greaterThan(tester.getBottomLeft(lineEndingDropdown).dy),
    );
  });

  testWidgets('Shell 字号支持数值输入并即时预览', (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip(AppStrings.common.shellSettings));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-navigation-item-1')));
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsNothing);
    final fontSizeField = find.byKey(const ValueKey('shell-font-size-field'));
    await tester.enterText(fontSizeField, '18');
    await tester.pump();

    final preview = tester.widget<Text>(
      find.textContaining('SerialTools Shell'),
    );
    expect(preview.style?.fontFamily, viewModel.fontFamily);
    expect(preview.style?.fontSize, 18);

    await tester.tap(find.text(AppStrings.common.save));
    await tester.pumpAndSettle();
    expect(viewModel.fontSize, 18);
  });

  testWidgets('starting Shell does not inject text or move terminal cursor', (
    tester,
  ) async {
    service.isConnected = true;
    await tester.pumpWidget(buildPage());
    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    terminal.write('prompt');
    final cursorX = terminal.buffer.cursorX;
    final cursorY = terminal.buffer.cursorY;

    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pump();

    expect(terminal.buffer.getText(), contains('prompt'));
    expect(terminal.buffer.getText(), isNot(contains('新会话')));
    expect(terminal.buffer.cursorX, cursorX);
    expect(terminal.buffer.cursorY, cursorY);
  });

  testWidgets(
    'line mode hides terminal cursor and key mode keeps it at bottom',
    (tester) async {
      service.isConnected = true;
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(buildPage());

      final terminalView = find.byType(TerminalView);
      final terminal = tester.widget<TerminalView>(terminalView).terminal;
      for (var index = 0; index < 80; index++) {
        terminal.write('line $index\r\n');
      }
      terminal.write('prompt> ');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('开始 Shell'));
      await tester.pumpAndSettle();
      var view = tester.widget<TerminalView>(terminalView);
      expect(view.cursorType, TerminalCursorType.verticalBar);
      expect(view.focusNode?.hasFocus, isFalse);
      expect(view.theme.cursor, Colors.transparent);
      expect(find.byKey(const ValueKey('shell-terminal-cursor')), findsNothing);

      await tester.tap(find.byTooltip('逐键模式'));
      await tester.pumpAndSettle();
      view = tester.widget<TerminalView>(terminalView);
      expect(view.focusNode?.hasFocus, isTrue);
      expect(view.theme.cursor, Colors.transparent);
      expect(
        view.scrollController?.offset,
        closeTo(view.scrollController!.position.maxScrollExtent, 0.01),
      );
      final cursor = find.byKey(const ValueKey('shell-terminal-cursor'));
      expect(cursor, findsOneWidget);
      final terminalState = tester.state<TerminalViewState>(terminalView);
      final renderedRows =
          tester.getSize(terminalView).height /
          terminalState.renderTerminal.cellSize.height;
      expect(renderedRows, closeTo(renderedRows.roundToDouble(), 0.01));
      expect(
        tester.getSize(cursor).height,
        closeTo(terminalState.renderTerminal.cellSize.height, 0.01),
      );
      expect(
        tester.getCenter(cursor).dy,
        greaterThan(tester.getCenter(terminalView).dy),
      );

      final cursorOpacity = find.descendant(
        of: cursor,
        matching: find.byType(Opacity),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(tester.widget<Opacity>(cursorOpacity).opacity, 1);
      await tester.pump(const Duration(milliseconds: 550));
      expect(tester.widget<Opacity>(cursorOpacity).opacity, 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<Opacity>(cursorOpacity).opacity, 1);

      // 离开逐键模式后停止闪烁计时，避免后台保留无意义的周期任务。
      await tester.tap(find.byTooltip('命令行模式'));
      await tester.pump();
      expect(find.byKey(const ValueKey('shell-terminal-cursor')), findsNothing);
    },
  );

  testWidgets('line input keeps focus after Enter sends a command', (
    tester,
  ) async {
    service.isConnected = true;
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pumpAndSettle();

    final inputFinder = find.byKey(const ValueKey('shell-line-input'));
    await tester.enterText(inputFinder, 'status');
    expect(tester.widget<TextField>(inputFinder).focusNode?.hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(inputFinder);
    expect(input.focusNode?.hasFocus, isTrue);
  });

  testWidgets('remote clear sequence clears the previous selection anchors', (
    tester,
  ) async {
    service.isConnected = true;
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pumpAndSettle();

    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    view.terminal.write('old text');
    view.controller!.setSelection(
      view.terminal.buffer.createAnchor(0, 0),
      view.terminal.buffer.createAnchor(3, 0),
    );
    expect(view.controller!.selection, isNotNull);

    service.debugAddShellData(
      Uint8List.fromList('\x1b[2J\x1b[Hprompt> '.codeUnits),
    );
    await tester.pump();
    await tester.pump();

    expect(view.controller!.selection, isNull);
  });

  testWidgets('key mode leaves arrows and Tab to xterm encoding', (
    tester,
  ) async {
    service.isConnected = true;
    service.setRawShellInputMode(RawShellInputMode.key);
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pump();

    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final output = <String>[];
    terminal.onOutput = output.add;
    await tester.tap(find.byType(TerminalView));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);

    expect(output, ['\x1b[A', '\x1b[B', '\x1b[D', '\x1b[C', '\t']);
  });

  testWidgets('key mode routes connection shortcuts and blocks all F keys', (
    tester,
  ) async {
    final shortcuts = <LogicalKeyboardKey>[];
    service.isConnected = true;
    service.setRawShellInputMode(RawShellInputMode.key);
    await tester.pumpWidget(buildPage(onConnectionShortcut: shortcuts.add));
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pump();

    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final output = <String>[];
    terminal.onOutput = output.add;
    await tester.tap(find.byType(TerminalView));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);

    expect(shortcuts, [LogicalKeyboardKey.f1, LogicalKeyboardKey.f5]);
    expect(output, isEmpty);
  });

  testWidgets('remote ED2 clears current screen but preserves scrollback', (
    tester,
  ) async {
    await tester.pumpWidget(buildPage());
    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    terminal.resize(80, 8, 800, 160);
    for (var i = 0; i < 20; i++) {
      terminal.write('history $i\r\n');
    }
    terminal.write('\x1b[2J\x1b[Hprompt');
    expect(terminal.buffer.getText(), contains('history'));
    expect(terminal.buffer.getText(), contains('prompt'));
  });

  testWidgets('remote ED3 plus ED2 removes history', (tester) async {
    await tester.pumpWidget(buildPage());
    final terminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    terminal.resize(80, 8, 800, 160);
    for (var i = 0; i < 20; i++) {
      terminal.write('old output $i\r\n');
    }
    terminal.write('\x1b[3J\x1b[2J\x1b[Hletter:/\$ ');
    expect(terminal.buffer.getText(), isNot(contains('old output')));
    expect(terminal.buffer.getText(), startsWith('letter:/\$ '));
  });

  testWidgets('received data is drained at no more than 64 KiB per frame', (
    tester,
  ) async {
    service.isConnected = true;
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pump();

    service.debugAddShellData(
      Uint8List(70 * 1024)..fillRange(0, 70 * 1024, 65),
    );
    await tester.pump();

    Text receivedStatus() =>
        tester.widget<Text>(find.byKey(const ValueKey('shell-received-bytes')));

    expect(receivedStatus().data, '接收 64.0 KiB');
    await tester.pump();
    expect(receivedStatus().data, '接收 70.0 KiB');
  });

  testWidgets('receive overload drops old blocks and reports Chinese warning', (
    tester,
  ) async {
    service.isConnected = true;
    await tester.pumpWidget(buildPage(receiveQueueLimitBytes: 8));
    await tester.tap(find.byTooltip('开始 Shell'));
    await tester.pump();

    service.debugAddShellData(Uint8List.fromList([0xE4]));
    service.debugAddShellData(Uint8List.fromList(List.filled(12, 65)));
    await tester.pump();
    await tester.pump();

    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminal.terminal.buffer.getText(), contains('Shell 接收过载'));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('shell-dropped-bytes')))
          .data,
      '丢弃 5 B',
    );
  });
}
