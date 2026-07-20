import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../core/localization/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../services/app_notifications.dart';
import '../../services/serial_service.dart';
import '../../services/shell_receive_queue.dart';
import '../../services/shell_stream_decoder.dart';
import '../../services/ymodem_service.dart';
import '../../viewmodels/shell_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 独立串口 Shell 页面。
///
/// 高频串口回调只进入 [_receiveQueue]，终端更新限制为每帧一次且每帧最多
/// 消费 64 KiB，避免小包风暴反复触发布局、绘制和滚动。
class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    this.receiveQueueLimitBytes = ShellReceiveQueue.defaultMaxBytes,
  });

  /// Shell UI 尚未消费的接收数据上限；测试可注入较小值验证过载路径。
  final int receiveQueueLimitBytes;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  static const int _maxReceiveBytesPerFrame = 64 * 1024;
  static const _terminalFontFamilies = <String>[
    'Consolas',
    'Cascadia Mono',
    'Cascadia Code',
    'Courier New',
    'JetBrains Mono',
    'Fira Code',
    'Sarasa Mono SC',
    'SarasaUiSC',
  ];

  late Terminal _terminal;
  late ShellStreamDecoder _decoder;
  final TerminalController _terminalController = TerminalController();
  final ScrollController _terminalScrollController = ScrollController();
  final TextEditingController _lineController = TextEditingController();
  final FocusNode _lineFocusNode = FocusNode(debugLabel: 'shellLineInput');
  final FocusNode _terminalFocusNode = FocusNode(debugLabel: 'shellTerminal');
  late final ShellReceiveQueue _receiveQueue;
  final List<String> _commandHistory = <String>[];
  StreamSubscription<Uint8List>? _receiveSubscription;
  ShellViewModel? _viewModel;
  int _receivedBytes = 0;
  int _newOutputBytes = 0;
  int _historyIndex = 0;
  bool _receiveDrainScheduled = false;
  bool _terminalSizeUpdateScheduled = false;
  bool _terminalAtBottom = true;
  String _ansiDetectionTail = '';
  DateTime? _lastOverflowWarningAt;

  @override
  void initState() {
    super.initState();
    final settings = context.read<ShellViewModel>();
    _receiveQueue = ShellReceiveQueue(maxBytes: widget.receiveQueueLimitBytes);
    _terminal = _createTerminal(settings.scrollbackLines);
    _decoder = ShellStreamDecoder(settings.encoding);
    _terminalScrollController.addListener(_handleScrollPosition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vm = context.read<ShellViewModel>();
    if (identical(_viewModel, vm)) return;
    _receiveSubscription?.cancel();
    _viewModel = vm;
    _receiveSubscription = vm.dataStream.listen(
      _enqueueReceivedData,
      onError: (Object error, StackTrace stackTrace) {
        if (mounted) _showPageError('Shell 接收异常: $error');
      },
    );
    _bindTerminalOutput(vm);
  }

  @override
  void dispose() {
    _viewModel?.serialService.updateShellPendingReceiveBytes(0);
    unawaited(_receiveSubscription?.cancel());
    _terminalScrollController.removeListener(_handleScrollPosition);
    _terminalScrollController.dispose();
    _terminalController.dispose();
    _lineController.dispose();
    _terminalFocusNode.dispose();
    _lineFocusNode.dispose();
    super.dispose();
  }

  void _bindTerminalOutput(ShellViewModel vm) {
    _terminal.onOutput = (text) {
      if (!vm.isRunning || vm.inputMode != RawShellInputMode.key) return;
      unawaited(_sendBytesSafely(vm, vm.encodeText(text)));
    };
  }

  Terminal _createTerminal(int maxLines) {
    return Terminal(
      maxLines: maxLines,
      onResize: (_, _, _, _) {
        if (_terminalSizeUpdateScheduled || !mounted) return;
        _terminalSizeUpdateScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _terminalSizeUpdateScheduled = false;
          if (mounted) setState(() {});
        });
      },
    );
  }

  void _enqueueReceivedData(Uint8List data) {
    if (data.isEmpty) return;
    final dropped = _receiveQueue.add(data);
    _syncReceiveQueueUsage();
    if (dropped > 0) _handleReceiveOverflow();
    _scheduleReceiveDrain();
  }

  void _handleReceiveOverflow() {
    _decoder.reset(encoding: _viewModel?.encoding);
    _ansiDetectionTail = '';
    _terminalController.clearSelection();
    // RIS 终止可能被截断的 ANSI 序列，避免丢块后终端长期处于错误样式。
    _terminal.write('\x1bc');
    final now = DateTime.now();
    final previous = _lastOverflowWarningAt;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 5)) {
      return;
    }
    _lastOverflowWarningAt = now;
    _terminal.write(
      '\r\n[警告] Shell 接收过载，已丢弃最旧数据 '
      '${_formatBytes(_receiveQueue.droppedBytes)}。\r\n',
    );
  }

  void _scheduleReceiveDrain() {
    if (_receiveDrainScheduled || !mounted) return;
    _receiveDrainScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _receiveDrainScheduled = false;
      if (!mounted) return;
      _drainReceivedData();
      if (_receiveQueue.isNotEmpty) _scheduleReceiveDrain();
    });
  }

  void _drainReceivedData() {
    var remaining = _maxReceiveBytesPerFrame;
    var consumed = 0;
    final output = StringBuffer();
    final followBottom = _isAtBottom;
    for (final chunk in _receiveQueue.removeUpTo(remaining)) {
      output.write(_decoder.add(chunk));
      remaining -= chunk.length;
      consumed += chunk.length;
    }
    _syncReceiveQueueUsage();
    if (output.isNotEmpty) {
      final decoded = output.toString();
      final detectionText = '$_ansiDetectionTail$decoded';
      if (detectionText.contains('\x1b[2J') ||
          detectionText.contains('\x1b[3J')) {
        _terminalController.clearSelection();
      }
      _ansiDetectionTail =
          detectionText.length <= 8
              ? detectionText
              : detectionText.substring(detectionText.length - 8);
      _terminal.write(decoded);
    }
    if (consumed == 0) return;
    _receivedBytes += consumed;
    if (followBottom) {
      _newOutputBytes = 0;
      _scheduleScrollToBottom();
    } else {
      _newOutputBytes += consumed;
    }
    setState(() {});
  }

  void _syncReceiveQueueUsage() {
    _viewModel?.serialService.updateShellPendingReceiveBytes(
      _receiveQueue.queuedBytes,
    );
  }

  bool get _isAtBottom {
    if (!_terminalScrollController.hasClients) return true;
    final position = _terminalScrollController.position;
    return position.maxScrollExtent - position.pixels <= 2;
  }

  void _handleScrollPosition() {
    if (!mounted) return;
    final atBottom = _isAtBottom;
    final bottomChanged = atBottom != _terminalAtBottom;
    _terminalAtBottom = atBottom;
    if (_newOutputBytes != 0 && atBottom) {
      setState(() => _newOutputBytes = 0);
    } else if (bottomChanged) {
      setState(() {});
    }
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_terminalScrollController.hasClients) return;
      _terminalScrollController.jumpTo(
        _terminalScrollController.position.maxScrollExtent,
      );
    });
  }

  Future<void> _toggleRunning(ShellViewModel vm) async {
    if (vm.isRunning) {
      await vm.stop();
      return;
    }
    if (!vm.start()) return;
    _receiveQueue.reset();
    _syncReceiveQueueUsage();
    _receivedBytes = 0;
    _newOutputBytes = 0;
    _terminalAtBottom = true;
    _ansiDetectionTail = '';
    _lastOverflowWarningAt = null;
    _decoder.reset(encoding: vm.encoding);
    _focusInputModeAfterLayout(vm.inputMode);
  }

  Future<void> _sendLine(ShellViewModel vm) async {
    final text = _lineController.text;
    if (text.isEmpty || !vm.isRunning || vm.isYmodemActive) {
      _refocusLineInput(vm);
      return;
    }
    try {
      if (vm.localEcho) _terminal.write('$text\r\n');
      _commandHistory.remove(text);
      _commandHistory.add(text);
      _historyIndex = _commandHistory.length;
      _lineController.clear();
      // 串口写入在后台有序队列中完成，输入框无需等待写入结果即可继续接收命令。
      _refocusLineInput(vm);
      await vm.sendText(text);
    } catch (error) {
      _showPageError('发送失败: $error');
    } finally {
      _refocusLineInput(vm);
    }
  }

  void _refocusLineInput(ShellViewModel vm) {
    if (mounted &&
        vm.isRunning &&
        !vm.isYmodemActive &&
        vm.inputMode == RawShellInputMode.line) {
      // 先覆盖 TextField 提交动作的默认焦点变化，让用户可以立即继续输入；
      // 下一帧再校正一次，避免发送状态刷新重建界面后焦点被其他控件接走。
      _lineFocusNode.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !vm.isRunning ||
          vm.isYmodemActive ||
          vm.inputMode != RawShellInputMode.line) {
        return;
      }
      _lineFocusNode.requestFocus();
    });
  }

  Future<void> _sendBytesSafely(ShellViewModel vm, Uint8List data) async {
    try {
      await vm.sendBytes(data);
    } catch (error) {
      _showPageError('发送失败: $error');
    }
  }

  KeyEventResult _handleTerminalKey(
    FocusNode node,
    KeyEvent event,
    ShellViewModel vm,
  ) {
    if (event is! KeyDownEvent || !vm.isRunning || vm.isYmodemActive) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    if (control && shift && event.logicalKey == LogicalKeyboardKey.keyC) {
      unawaited(_copySelection());
      return KeyEventResult.handled;
    }
    if (control && shift && event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_pasteClipboard(vm));
      return KeyEventResult.handled;
    }
    if (control && !shift && event.logicalKey == LogicalKeyboardKey.keyC) {
      unawaited(_sendBytesSafely(vm, Uint8List.fromList(const <int>[0x03])));
      return KeyEventResult.handled;
    }
    // 方向键、Tab 和其余 Ctrl 组合继续交给 xterm 编码。
    return KeyEventResult.ignored;
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection == null) return;
    await Clipboard.setData(
      ClipboardData(text: _terminal.buffer.getText(selection)),
    );
  }

  Future<void> _pasteClipboard(ShellViewModel vm) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || !vm.isRunning) return;
    final multiline = text.contains('\n') || text.contains('\r');
    if (multiline) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('发送多行内容'),
              content: const Text('剪贴板包含多行内容，确定直接发送到设备吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(AppStrings.common.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(AppStrings.raw.send),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _sendBytesSafely(vm, vm.encodeText(text));
  }

  KeyEventResult _handleLineHistory(KeyEvent event) {
    if (event is! KeyDownEvent || _commandHistory.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _historyIndex = (_historyIndex - 1).clamp(0, _commandHistory.length - 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _historyIndex = (_historyIndex + 1).clamp(0, _commandHistory.length);
    } else {
      return KeyEventResult.ignored;
    }
    _lineController.text =
        _historyIndex == _commandHistory.length
            ? ''
            : _commandHistory[_historyIndex];
    _lineController.selection = TextSelection.collapsed(
      offset: _lineController.text.length,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ShellViewModel>(
      builder: (context, vm, _) {
        if (_decoder.encoding != vm.encoding) {
          _decoder.reset(encoding: vm.encoding);
        }
        return Column(
          children: [
            _buildToolbar(vm),
            Expanded(child: _buildTerminal(vm)),
            if (vm.inputMode == RawShellInputMode.line) _buildLineInput(vm),
            _buildStatus(vm),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(ShellViewModel vm) {
    final canTransfer = vm.isRunning || vm.isYmodemActive;
    final canConfigure = !vm.isRunning;
    return UnifiedToolbar(
      leadingItems: [
        ToolbarLayoutItem(
          extent: 76,
          child: ToolbarStartStopButton(
            key: const ValueKey('shell-start-stop-button'),
            tooltip: vm.isRunning ? '停止 Shell' : '开始 Shell',
            running: vm.isRunning,
            label: vm.isRunning ? '停止' : '开始',
            onPressed:
                vm.isConnected || vm.isRunning
                    ? () => _toggleRunning(vm)
                    : null,
          ),
        ),
        _shellModeToolbarItem(vm, RawShellInputMode.line),
        _shellModeToolbarItem(vm, RawShellInputMode.key),
      ],
      trailingItems: [
        ToolbarLayoutItem(
          extent: kToolbarControlExtent,
          child: SizedBox(
            width: kToolbarControlExtent,
            height: kToolbarControlExtent,
            child: PopupMenuButton<String>(
              tooltip: '清屏',
              padding: EdgeInsets.zero,
              iconSize: kToolbarIconSize,
              icon: const Icon(Icons.clear),
              onSelected: _clearTerminal,
              itemBuilder:
                  (context) => const [
                    PopupMenuItem(value: 'screen', child: Text('清除当前屏幕')),
                    PopupMenuItem(value: 'history', child: Text('清除历史')),
                    PopupMenuItem(value: 'all', child: Text('清除屏幕和历史')),
                  ],
            ),
          ),
          overflowActions: [
            ToolbarOverflowAction(
              icon: const Icon(Icons.clear),
              label: '清除当前屏幕',
              onPressed: () => _clearTerminal('screen'),
            ),
            ToolbarOverflowAction(
              icon: const Icon(Icons.history),
              label: '清除历史',
              onPressed: () => _clearTerminal('history'),
            ),
            ToolbarOverflowAction(
              icon: const Icon(Icons.delete_sweep_outlined),
              label: '清除屏幕和历史',
              onPressed: () => _clearTerminal('all'),
            ),
          ],
        ),
        _shellActionToolbarItem(
          icon: Icons.drive_folder_upload_outlined,
          label: '文件传输',
          onPressed: canTransfer ? () => _showFileTransferDialog(vm) : null,
        ),
        _shellActionToolbarItem(
          icon: Icons.save,
          label: '导出终端文本',
          onPressed: _exportTerminalText,
        ),
        ToolbarLayoutItem(
          extent: kToolbarControlExtent,
          child: ToolbarAdvancedSettingsButton(
            tooltip: AppStrings.common.shellSettings,
            onPressed: canConfigure ? () => _showSettingsDialog(vm) : null,
          ),
          overflowActions: [
            ToolbarOverflowAction(
              icon: const Icon(Icons.tune),
              label: AppStrings.common.shellSettings,
              onPressed: canConfigure ? () => _showSettingsDialog(vm) : null,
            ),
          ],
        ),
      ],
    );
  }

  ToolbarLayoutItem _shellActionToolbarItem({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return ToolbarLayoutItem(
      extent: kToolbarControlExtent,
      child: ToolbarIconButton(
        icon: Icon(icon),
        tooltip: label,
        onPressed: onPressed,
      ),
      overflowActions: [
        ToolbarOverflowAction(
          icon: Icon(icon),
          label: label,
          onPressed: onPressed,
        ),
      ],
    );
  }

  ToolbarLayoutItem _shellModeToolbarItem(
    ShellViewModel vm,
    RawShellInputMode mode,
  ) {
    final lineMode = mode == RawShellInputMode.line;
    final label = lineMode ? '命令行模式' : '逐键模式';
    final icon = lineMode ? Icons.keyboard_return : Icons.keyboard;
    return ToolbarLayoutItem(
      extent: kToolbarControlExtent,
      child: _modeButton(vm: vm, mode: mode, tooltip: label, icon: icon),
      overflowActions: [
        ToolbarOverflowAction(
          icon: Icon(icon),
          label: label,
          selected: vm.inputMode == mode,
          onPressed:
              vm.isYmodemActive ? null : () => _selectInputMode(vm, mode),
        ),
      ],
    );
  }

  Widget _modeButton({
    required ShellViewModel vm,
    required RawShellInputMode mode,
    required String tooltip,
    required IconData icon,
  }) {
    return ToolbarToggleIconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      selected: vm.inputMode == mode,
      onPressed: vm.isYmodemActive ? null : () => _selectInputMode(vm, mode),
    );
  }

  void _selectInputMode(ShellViewModel vm, RawShellInputMode mode) {
    vm.setInputMode(mode);
    if (vm.isRunning) _focusInputModeAfterLayout(mode);
  }

  void _clearTerminal(String value) {
    switch (value) {
      case 'screen':
        _terminal.write('\x1b[2J\x1b[H');
      case 'history':
        _terminal.eraseScrollbackOnly();
      case 'all':
        _terminal.write('\x1b[3J\x1b[2J\x1b[H');
    }
  }

  void _focusInputModeAfterLayout(RawShellInputMode mode) {
    _terminalController.clearSelection();
    if (mode == RawShellInputMode.key) {
      _lineFocusNode.unfocus();
    } else {
      _terminalFocusNode.unfocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (mode == RawShellInputMode.key) {
        _terminalFocusNode.requestFocus();
      } else {
        _lineFocusNode.requestFocus();
      }
      // 模式切换会改变终端区域高度，必须在新布局完成后重新定位到底部，
      // 否则 xterm 光标可能沿用旧视口偏移而绘制在第一行。
      _scheduleScrollToBottom();
    });
  }

  Widget _buildTerminal(ShellViewModel vm) {
    final baseTheme = _terminalTheme(vm.themeMode);
    // xterm 自带光标在视口高度变化后可能沿用错误的滚动偏移。统一隐藏后，
    // 逐键模式按 Buffer.cursorY 在当前视口内绘制光标；命令行模式只显示输入框光标。
    final theme = _terminalThemeWithCursor(baseTheme, Colors.transparent);
    final terminalStyle = TerminalStyle(
      fontFamily: vm.fontFamily,
      fontSize: vm.fontSize,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        const terminalPadding = 8.0;
        final cellSize = _measureTerminalCellSize(terminalStyle);
        final contentHeight = math.max(
          0.0,
          constraints.maxHeight - terminalPadding * 2,
        );
        final visibleRows = math.max(1, contentHeight ~/ cellSize.height);
        // xterm 的滚动范围按像素计算；视口若包含不足一行的余数，滚动到底部时
        // 会在顶部露出半行历史。将实际终端区域限制为整数行，余量留在底部。
        final terminalHeight = math.min(
          contentHeight,
          visibleRows * cellSize.height,
        );

        return ColoredBox(
          color: theme.background,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: terminalPadding,
                right: terminalPadding,
                top: terminalPadding,
                height: terminalHeight,
                child: TerminalView(
                  _terminal,
                  controller: _terminalController,
                  scrollController: _terminalScrollController,
                  theme: theme,
                  focusNode: _terminalFocusNode,
                  autofocus: false,
                  readOnly:
                      !vm.isRunning || vm.inputMode == RawShellInputMode.line,
                  hardwareKeyboardOnly: true,
                  onKeyEvent:
                      (node, event) => _handleTerminalKey(node, event, vm),
                  shortcuts: const <ShortcutActivator, Intent>{},
                  cursorType: _cursorType(vm.cursorMode),
                  alwaysShowCursor: false,
                  textStyle: terminalStyle,
                  onSecondaryTapDown: (details, offset) async {
                    if (_terminalController.selection != null) {
                      await _copySelection();
                      _terminalController.clearSelection();
                    } else {
                      await _pasteClipboard(vm);
                    }
                  },
                ),
              ),
              if (vm.isRunning &&
                  vm.inputMode == RawShellInputMode.key &&
                  _terminalAtBottom &&
                  _terminal.cursorVisibleMode)
                _buildKeyModeCursor(
                  vm,
                  baseTheme.cursor,
                  cellSize,
                  terminalPadding,
                ),
              if (_newOutputBytes > 0)
                Positioned(
                  right: 16,
                  bottom: 14,
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() => _newOutputBytes = 0);
                      _scheduleScrollToBottom();
                    },
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    label: Text('新输出 ${_formatBytes(_newOutputBytes)}'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKeyModeCursor(
    ShellViewModel vm,
    Color color,
    Size cellSize,
    double padding,
  ) {
    final left = padding + _terminal.buffer.cursorX * cellSize.width;
    final rowTop = padding + _terminal.buffer.cursorY * cellSize.height;
    final (top, width, height) = switch (vm.cursorMode) {
      RawShellCursorMode.block => (rowTop, cellSize.width, cellSize.height),
      RawShellCursorMode.underline => (
        rowTop + cellSize.height - 1,
        cellSize.width,
        1.0,
      ),
      RawShellCursorMode.verticalBar => (rowTop, 1.0, cellSize.height),
    };
    return Positioned(
      key: const ValueKey('shell-terminal-cursor'),
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(child: ColoredBox(color: color)),
    );
  }

  Size _measureTerminalCellSize(TerminalStyle style) {
    const sample = 'mmmmmmmmmm';
    final textStyle = style.toTextStyle();
    final builder =
        ui.ParagraphBuilder(textStyle.getParagraphStyle())
          ..pushStyle(
            textStyle.getTextStyle(
              textScaler: MediaQuery.textScalerOf(context),
            ),
          )
          ..addText(sample);
    final paragraph =
        builder.build()
          ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final result = Size(
      paragraph.maxIntrinsicWidth / sample.length,
      paragraph.height,
    );
    paragraph.dispose();
    return result;
  }

  Widget _buildLineInput(ShellViewModel vm) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: (_, event) => _handleLineHistory(event),
              child: TextField(
                key: const ValueKey('shell-line-input'),
                controller: _lineController,
                focusNode: _lineFocusNode,
                enabled: vm.isRunning && !vm.isYmodemActive,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '输入命令后按 Enter 发送',
                ),
                // 覆盖 TextField 的默认完成行为，避免 Enter 后自动释放焦点。
                onEditingComplete: () {},
                onSubmitted: (_) => _sendLine(vm),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed:
                vm.isRunning && !vm.isYmodemActive ? () => _sendLine(vm) : null,
            icon: const Icon(Icons.send, size: 18),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatus(ShellViewModel vm) {
    final lineEnding = switch (vm.lineEnding) {
      '\r' => 'CR',
      '\n' => 'LF',
      _ => 'CRLF',
    };
    return Container(
      height: kPageStatusBarHeight,
      padding: kPageStatusBarPadding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: DefaultTextStyle(
        key: const ValueKey('shell-status-text-style'),
        style: kPageStatusBarTextStyle,
        child: Row(
          children: [
            Text(vm.isRunning ? '运行中' : '已停止'),
            const SizedBox(width: 16),
            Text('${vm.encoding}  $lineEnding'),
            const SizedBox(width: 16),
            Text('${_terminal.viewWidth} x ${_terminal.viewHeight}'),
            const SizedBox(width: 16),
            Text(
              '接收 ${_formatBytes(_receivedBytes)}',
              key: const ValueKey('shell-received-bytes'),
            ),
            if (_receiveQueue.droppedBytes > 0) ...[
              const SizedBox(width: 16),
              Text(
                '丢弃 ${_formatBytes(_receiveQueue.droppedBytes)}',
                key: const ValueKey('shell-dropped-bytes'),
              ),
            ],
            const Spacer(),
            if (!_isAtBottom) const Text('滚动锁定'),
          ],
        ),
      ),
    );
  }

  Future<void> _exportTerminalText() async {
    final directory = await file_picker.FilePicker.getDirectoryPath(
      dialogTitle: '选择终端文本导出目录',
    );
    if (directory == null) return;
    final path =
        '$directory${Platform.pathSeparator}shell_${DateTime.now().millisecondsSinceEpoch}.txt';
    await File(path).writeAsString(_terminal.buffer.getText());
    AppNotifications.show('终端文本已导出: $path');
  }

  Future<void> _showSettingsDialog(ShellViewModel vm) async {
    var encoding = vm.encoding;
    var lineEnding = vm.lineEnding;
    var fontSize = vm.fontSize;
    var fontFamily = vm.fontFamily;
    var theme = vm.themeMode;
    var cursor = vm.cursorMode;
    var localEcho = vm.localEcho;
    var scrollback = vm.scrollbackLines;
    var fontSizeText = fontSize.round().toString();
    String? fontSizeError;
    final scrollController = ScrollController();
    final inputSectionKey = GlobalKey();
    final fontSectionKey = GlobalKey();
    final appearanceSectionKey = GlobalKey();
    final historySectionKey = GlobalKey();
    try {
      await showDialog<void>(
        context: context,
        builder:
            (dialogContext) => StatefulBuilder(
              builder:
                  (context, setDialogState) => AlertDialog(
                    shape: kAdvancedSettingsDialogShape,
                    title: Text(AppStrings.common.shellSettings),
                    content: SettingsNavigationView(
                      scrollController: scrollController,
                      items: [
                        SettingsNavigationItem(
                          label: '输入与编码',
                          anchorKey: inputSectionKey,
                        ),
                        SettingsNavigationItem(
                          label: '终端字体',
                          anchorKey: fontSectionKey,
                        ),
                        SettingsNavigationItem(
                          label: '外观与光标',
                          anchorKey: appearanceSectionKey,
                        ),
                        SettingsNavigationItem(
                          label: '历史记录',
                          anchorKey: historySectionKey,
                        ),
                      ],
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            key: inputSectionKey,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '文本编码',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(height: 4),
                                    NoAnimDropdown<String>(
                                      value: encoding,
                                      hint: '选择文本编码',
                                      decoration:
                                          secondaryDialogFieldDecoration(),
                                      items:
                                          ShellViewModel.availableEncodings
                                              .map(
                                                (value) => DropdownMenuItem(
                                                  value: value,
                                                  child: Text(value),
                                                ),
                                              )
                                              .toList(),
                                      onChanged:
                                          (value) => setDialogState(
                                            () => encoding = value ?? encoding,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '命令行行尾',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(height: 4),
                                    NoAnimDropdown<String>(
                                      key: const ValueKey(
                                        'shell-line-ending-dropdown',
                                      ),
                                      value: lineEnding,
                                      hint: '选择命令行行尾',
                                      decoration:
                                          secondaryDialogFieldDecoration(),
                                      items: const [
                                        DropdownMenuItem(
                                          value: '\r',
                                          child: Text('CR'),
                                        ),
                                        DropdownMenuItem(
                                          value: '\n',
                                          child: Text('LF'),
                                        ),
                                        DropdownMenuItem(
                                          value: '\r\n',
                                          child: Text('CRLF'),
                                        ),
                                      ],
                                      onChanged:
                                          (value) => setDialogState(
                                            () =>
                                                lineEnding =
                                                    value ?? lineEnding,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '命令行模式发送时会在内容末尾追加所选行尾。',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Divider(height: 24),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('命令行本地回显'),
                            value: localEcho,
                            onChanged:
                                (value) =>
                                    setDialogState(() => localEcho = value),
                          ),
                          const Divider(height: 24),
                          Text(
                            key: fontSectionKey,
                            '终端字体',
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: kSecondaryDialogWideFieldWidth,
                            child: NoAnimDropdown<String>(
                              value: fontFamily,
                              hint: '选择终端字体',
                              decoration: secondaryDialogFieldDecoration(),
                              items:
                                  _terminalFontFamilies
                                      .map(
                                        (font) => DropdownMenuItem(
                                          value: font,
                                          child: Text(font),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  (value) => setDialogState(
                                    () => fontFamily = value ?? fontFamily,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('字号', style: TextStyle(fontSize: 14)),
                              const Spacer(),
                              SizedBox(
                                width: kSecondaryDialogFieldWidth,
                                child: TextFormField(
                                  key: const ValueKey('shell-font-size-field'),
                                  initialValue: fontSizeText,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: secondaryDialogFieldDecoration(
                                    suffixText: 'px',
                                  ).copyWith(errorText: fontSizeError),
                                  onChanged: (value) {
                                    fontSizeText = value;
                                    final parsed = double.tryParse(value);
                                    setDialogState(() {
                                      if (parsed == null ||
                                          parsed < 10 ||
                                          parsed > 24) {
                                        fontSizeError =
                                            AppStrings
                                                .raw
                                                .terminalFontSizeInvalid;
                                      } else {
                                        fontSize = parsed;
                                        fontSizeError = null;
                                      }
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('字体示例', style: TextStyle(fontSize: 14)),
                          const SizedBox(height: 4),
                          Container(
                            key: const ValueKey('shell-font-preview'),
                            width: double.infinity,
                            constraints: const BoxConstraints(minHeight: 64),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLow,
                              border: Border.all(
                                color: Theme.of(context).dividerColor,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'SerialTools Shell  中文终端\nAa Bb 0123456789  > _',
                              style: TextStyle(
                                fontFamily: fontFamily,
                                fontSize: fontSize,
                                height: 1.25,
                              ),
                            ),
                          ),
                          const Divider(height: 24),
                          Text(
                            key: appearanceSectionKey,
                            '终端主题',
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 6),
                          SegmentedButton<RawShellThemeMode>(
                            segments: const [
                              ButtonSegment(
                                value: RawShellThemeMode.light,
                                label: Text('浅色'),
                              ),
                              ButtonSegment(
                                value: RawShellThemeMode.dark,
                                label: Text('深色'),
                              ),
                            ],
                            selected: <RawShellThemeMode>{theme},
                            onSelectionChanged:
                                (values) =>
                                    setDialogState(() => theme = values.single),
                          ),
                          const SizedBox(height: 12),
                          const Text('光标样式', style: TextStyle(fontSize: 14)),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: kSecondaryDialogWideFieldWidth,
                            child: NoAnimDropdown<RawShellCursorMode>(
                              value: cursor,
                              hint: '选择光标样式',
                              decoration: secondaryDialogFieldDecoration(),
                              items:
                                  RawShellCursorMode.values
                                      .map(
                                        (value) => DropdownMenuItem(
                                          value: value,
                                          child: Text(value.label),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  (value) => setDialogState(
                                    () => cursor = value ?? cursor,
                                  ),
                            ),
                          ),
                          const Divider(height: 24),
                          Text(
                            key: historySectionKey,
                            '历史行数',
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: kSecondaryDialogWideFieldWidth,
                            child: NoAnimDropdown<int>(
                              value: scrollback,
                              hint: '选择历史行数',
                              decoration: secondaryDialogFieldDecoration(),
                              items:
                                  const <int>[1000, 5000, 10000, 50000, 100000]
                                      .map(
                                        (value) => DropdownMenuItem(
                                          value: value,
                                          child: Text('$value 行'),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  (value) => setDialogState(
                                    () => scrollback = value ?? scrollback,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(AppStrings.common.cancel),
                      ),
                      DialogPrimaryActionButton(
                        onPressed: () {
                          final parsedFontSize = double.tryParse(fontSizeText);
                          if (parsedFontSize == null ||
                              parsedFontSize < 10 ||
                              parsedFontSize > 24) {
                            setDialogState(
                              () =>
                                  fontSizeError =
                                      AppStrings.raw.terminalFontSizeInvalid,
                            );
                            return;
                          }
                          vm
                            ..setEncoding(encoding)
                            ..setLineEnding(lineEnding)
                            ..setLocalEcho(localEcho)
                            ..setFontFamily(fontFamily)
                            ..setFontSize(parsedFontSize)
                            ..setThemeMode(theme)
                            ..setCursorMode(cursor);
                          if (scrollback != vm.scrollbackLines) {
                            vm.setScrollbackLines(scrollback);
                            _replaceTerminal(scrollback, vm);
                          }
                          Navigator.pop(dialogContext);
                        },
                        label: AppStrings.common.save,
                      ),
                    ],
                  ),
            ),
      );
    } finally {
      scrollController.dispose();
    }
  }

  void _replaceTerminal(int maxLines, ShellViewModel vm) {
    final history = _terminal.buffer.getText();
    setState(() {
      _terminal = _createTerminal(maxLines);
      _bindTerminalOutput(vm);
      if (history.isNotEmpty) _terminal.write(history);
    });
  }

  Future<void> _showFileTransferDialog(ShellViewModel vm) async {
    File? selectedFile;
    var packetSize = YmodemPacketSizeMode.auto;
    var transferActive = vm.isYmodemActive;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('YMODEM 文件传输'),
                  content: SizedBox(
                    width: 460,
                    child: StreamBuilder<YmodemTransferStatus>(
                      stream: vm.ymodemStatusStream,
                      initialData: vm.ymodemStatus,
                      builder: (context, snapshot) {
                        final status = snapshot.data!;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    selectedFile?.path ?? '未选择发送文件',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed:
                                      status.isActive
                                          ? null
                                          : () async {
                                            final result =
                                                await file_picker
                                                    .FilePicker.pickFiles();
                                            final path =
                                                result?.files.single.path;
                                            if (path != null) {
                                              setDialogState(
                                                () => selectedFile = File(path),
                                              );
                                            }
                                          },
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('选择'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<YmodemPacketSizeMode>(
                              initialValue: packetSize,
                              decoration: const InputDecoration(
                                labelText: '发送分包',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: YmodemPacketSizeMode.auto,
                                  child: Text('自动'),
                                ),
                                DropdownMenuItem(
                                  value: YmodemPacketSizeMode.bytes128,
                                  child: Text('128 字节'),
                                ),
                                DropdownMenuItem(
                                  value: YmodemPacketSizeMode.bytes1024,
                                  child: Text('1024 字节'),
                                ),
                              ],
                              onChanged:
                                  status.isActive
                                      ? null
                                      : (value) => setDialogState(
                                        () => packetSize = value ?? packetSize,
                                      ),
                            ),
                            const SizedBox(height: 14),
                            LinearProgressIndicator(
                              value:
                                  status.totalBytes > 0
                                      ? status.progress
                                      : status.isActive
                                      ? null
                                      : 0,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              status.message.isEmpty
                                  ? '等待开始传输'
                                  : status.message,
                            ),
                            if (error != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  actions: [
                    if (transferActive)
                      TextButton(
                        onPressed: vm.cancelYmodem,
                        child: const Text('取消传输'),
                      ),
                    TextButton(
                      onPressed:
                          transferActive
                              ? null
                              : () => Navigator.pop(dialogContext),
                      child: Text(AppStrings.common.close),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          transferActive
                              ? null
                              : () async {
                                setDialogState(() {
                                  transferActive = true;
                                  error = null;
                                });
                                try {
                                  final file = await vm.receiveYmodemFile();
                                  if (file != null) {
                                    setDialogState(
                                      () => error = '接收完成: ${file.path}',
                                    );
                                  }
                                } catch (value) {
                                  setDialogState(() => error = '$value');
                                } finally {
                                  if (dialogContext.mounted) {
                                    setDialogState(
                                      () => transferActive = false,
                                    );
                                  }
                                }
                              },
                      icon: const Icon(Icons.download),
                      label: const Text('接收'),
                    ),
                    FilledButton.icon(
                      onPressed:
                          selectedFile == null || transferActive
                              ? null
                              : () async {
                                setDialogState(() {
                                  transferActive = true;
                                  error = null;
                                });
                                try {
                                  await vm.sendYmodemFile(
                                    selectedFile!,
                                    packetSizeMode: packetSize,
                                  );
                                } catch (value) {
                                  setDialogState(() => error = '$value');
                                } finally {
                                  if (dialogContext.mounted) {
                                    setDialogState(
                                      () => transferActive = false,
                                    );
                                  }
                                }
                              },
                      icon: const Icon(Icons.upload),
                      label: const Text('发送'),
                    ),
                  ],
                ),
          ),
    );
  }

  TerminalTheme _terminalTheme(RawShellThemeMode mode) {
    if (mode == RawShellThemeMode.dark) return TerminalThemes.defaultTheme;
    return const TerminalTheme(
      cursor: Color(0xFF2563EB),
      selection: Color(0x663B82F6),
      foreground: Color(0xFF202124),
      background: AppTheme.pageBackgroundColor,
      black: Color(0xFF202124),
      red: Color(0xFFB3261E),
      green: Color(0xFF0B6B3A),
      yellow: Color(0xFF8A5A00),
      blue: Color(0xFF1A5FB4),
      magenta: Color(0xFF8E24AA),
      cyan: Color(0xFF007C91),
      white: Color(0xFFF1F3F4),
      brightBlack: Color(0xFF5F6368),
      brightRed: Color(0xFFD93025),
      brightGreen: Color(0xFF188038),
      brightYellow: Color(0xFFB06000),
      brightBlue: Color(0xFF1967D2),
      brightMagenta: Color(0xFF9C27B0),
      brightCyan: Color(0xFF0097A7),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFFFFF59D),
      searchHitBackgroundCurrent: Color(0xFFFFD54F),
      searchHitForeground: Color(0xFF202124),
    );
  }

  TerminalTheme _terminalThemeWithCursor(TerminalTheme theme, Color cursor) {
    return TerminalTheme(
      cursor: cursor,
      selection: theme.selection,
      foreground: theme.foreground,
      background: theme.background,
      black: theme.black,
      red: theme.red,
      green: theme.green,
      yellow: theme.yellow,
      blue: theme.blue,
      magenta: theme.magenta,
      cyan: theme.cyan,
      white: theme.white,
      brightBlack: theme.brightBlack,
      brightRed: theme.brightRed,
      brightGreen: theme.brightGreen,
      brightYellow: theme.brightYellow,
      brightBlue: theme.brightBlue,
      brightMagenta: theme.brightMagenta,
      brightCyan: theme.brightCyan,
      brightWhite: theme.brightWhite,
      searchHitBackground: theme.searchHitBackground,
      searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
      searchHitForeground: theme.searchHitForeground,
    );
  }

  TerminalCursorType _cursorType(RawShellCursorMode mode) {
    return switch (mode) {
      RawShellCursorMode.block => TerminalCursorType.block,
      RawShellCursorMode.underline => TerminalCursorType.underline,
      RawShellCursorMode.verticalBar => TerminalCursorType.verticalBar,
    };
  }

  void _showPageError(String message) {
    if (!mounted) return;
    AppNotifications.show(message);
  }

  String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
