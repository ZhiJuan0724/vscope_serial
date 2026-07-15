import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/shell_viewmodel.dart';
import 'package:vscope_serial/views/pages/shell_page.dart';
import 'package:xterm/xterm.dart';

class _TestShellViewModel extends ShellViewModel {
  _TestShellViewModel(super.serialService);

  @override
  Future<void> sendText(String text) async {}
}

void main() {
  late SerialService service;
  late ShellViewModel viewModel;

  setUp(() {
    service = SerialService();
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

  Widget buildPage() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SerialService>.value(value: service),
        ChangeNotifierProvider<ShellViewModel>.value(value: viewModel),
      ],
      child: const MaterialApp(home: Scaffold(body: ShellPage())),
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
    final startButton = tester.widget<ElevatedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('shell-start-stop-button')),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(startButton.style?.minimumSize?.resolve({}), const Size(0, 28));
    expect(find.text('开始'), findsOneWidget);
    expect(find.byTooltip('搜索终端内容'), findsNothing);
    expect(find.byTooltip('重置终端状态'), findsNothing);
    expect(
      find.descendant(
        of: find.byTooltip('导出终端文本'),
        matching: find.byIcon(Icons.save),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byTooltip('清屏'),
        matching: find.byIcon(Icons.clear),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip(AppStrings.common.shellSettings), findsOneWidget);
    expect(find.text(AppStrings.common.shellSettings), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.text('UTF-8  CRLF'), findsOneWidget);
    final statusStyle = tester.widget<DefaultTextStyle>(
      find.byKey(const ValueKey('shell-status-text-style')),
    );
    expect(statusStyle.style.fontSize, 11);
    expect(statusStyle.style.color, Colors.grey);
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
    expect(find.text('CRLF'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shell-settings-save-button')),
        matching: find.byType(ElevatedButton),
      ),
      findsOneWidget,
    );

    final lineEndingDropdown = find.byKey(
      const ValueKey('shell-line-ending-dropdown'),
    );
    await tester.tap(lineEndingDropdown);
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('CR')).dy,
      greaterThan(tester.getBottomLeft(lineEndingDropdown).dy),
    );
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
}
