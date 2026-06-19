import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../core/utils/crc.dart';
import '../../services/app_notifications.dart';
import '../../services/serial_service.dart';
import '../../services/ymodem_service.dart';
import '../../viewmodels/raw_data_viewmodel.dart';
import '../widgets/common_widgets.dart';

enum _FileTransferDirection {
  send('发送'),
  receive('接收');

  final String label;
  const _FileTransferDirection(this.label);
}

enum _ShellFileTransferProtocol {
  ymodem('YMODEM');

  final String label;
  const _ShellFileTransferProtocol(this.label);
}

extension on YmodemPacketSizeMode {
  String get label {
    return switch (this) {
      YmodemPacketSizeMode.auto => '自动',
      YmodemPacketSizeMode.bytes128 => '128 字节',
      YmodemPacketSizeMode.bytes1024 => '1024 字节',
    };
  }
}

/// 数据收发页面
class RawDataPage extends StatefulWidget {
  const RawDataPage({super.key});

  @override
  State<RawDataPage> createState() => _RawDataPageState();
}

class _RawDataPageState extends State<RawDataPage> {
  static const List<String> _terminalFontFamilies = [
    'Consolas',
    'Cascadia Mono',
    'Cascadia Code',
    'Courier New',
    'JetBrains Mono',
    'Fira Code',
    'Sarasa Mono SC',
    'SarasaUiSC',
  ];

  final TextEditingController _sendController = TextEditingController();
  final TextEditingController _shellLineController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _terminalScrollController = ScrollController();
  final Terminal _terminal = Terminal(maxLines: 10000);
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final TerminalController _terminalController = TerminalController();
  final FocusNode _terminalFocusNode = FocusNode(
    debugLabel: 'rawDataShellTerminal',
  );
  final FocusNode _shellLineFocusNode = FocusNode(
    debugLabel: 'rawDataShellLineInput',
  );
  bool _autoScrollScheduled = false;
  String _receiveText = '';
  double _splitRatio = 0.65;
  StreamSubscription<Uint8List>? _shellSubscription;
  RawDataViewModel? _shellVm;
  Rect? _terminalCursorRect;
  Size? _terminalCellSize;
  bool _terminalCursorUpdateScheduled = false;

  @override
  void initState() {
    super.initState();
    _terminal.write('\x1b[?25l');
    _terminal.addListener(_scheduleTerminalCursorUpdate);
    _terminalScrollController.addListener(_scheduleTerminalCursorUpdate);
  }

  @override
  void dispose() {
    _terminal.removeListener(_scheduleTerminalCursorUpdate);
    _terminalScrollController.removeListener(_scheduleTerminalCursorUpdate);
    _sendController.dispose();
    _shellLineController.dispose();
    _scrollController.dispose();
    _terminalScrollController.dispose();
    _terminalFocusNode.dispose();
    _shellLineFocusNode.dispose();
    _shellSubscription?.cancel();
    super.dispose();
  }

  void _syncReceiveText(RawDataViewModel vm) {
    final text = vm.receivedLines.join('\n');
    if (_receiveText != text) {
      _receiveText = text;
    }
  }

  void _scrollToBottom(RawDataViewModel vm) {
    if (!vm.autoScroll || _autoScrollScheduled) return;

    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !vm.autoScroll || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _syncShellSubscription(RawDataViewModel vm) {
    if (_shellVm == vm && _shellSubscription != null) return;
    _shellSubscription?.cancel();
    _shellVm = vm;
    _shellSubscription = vm.shellDataStream.listen((data) {
      if (vm.isYmodemActive) return;
      _terminal.write(utf8.decode(data, allowMalformed: true));
      _terminal.write('\x1b[?25l');
      _scrollTerminalToBottom();
    });
    _terminal.onOutput = (output) {
      if (!vm.shellMode ||
          vm.shellInputMode != RawShellInputMode.key ||
          vm.isYmodemActive) {
        return;
      }
      vm.sendShellBytes(Uint8List.fromList(utf8.encode(output)));
    };
  }

  void _scrollTerminalToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_terminalScrollController.hasClients) return;
      _terminalScrollController.jumpTo(
        _terminalScrollController.position.maxScrollExtent,
      );
      _scheduleTerminalCursorUpdate();
    });
  }

  void _syncShellFocus(RawDataViewModel vm) {
    _scheduleTerminalCursorUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!vm.shellMode) {
        _terminalFocusNode.unfocus();
        _shellLineFocusNode.unfocus();
        return;
      }
      if (vm.shellInputMode == RawShellInputMode.line) {
        _terminalFocusNode.unfocus();
      } else {
        _shellLineFocusNode.unfocus();
        if (!_terminalFocusNode.hasFocus) {
          _terminalFocusNode.requestFocus();
        }
      }
    });
  }

  void _scheduleTerminalCursorUpdate() {
    if (_terminalCursorUpdateScheduled) return;
    _terminalCursorUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _terminalCursorUpdateScheduled = false;
      if (!mounted) return;
      final viewRect = _terminalViewKey.currentState?.cursorRect;
      final cellSize =
          viewRect == null
              ? _terminalCellSize
              : Size(viewRect.width, viewRect.height);
      if (cellSize == null || cellSize.width <= 0 || cellSize.height <= 0) {
        return;
      }
      final scrollOffset =
          _terminalScrollController.hasClients
              ? _terminalScrollController.offset
              : 0.0;
      final rect = Rect.fromLTWH(
        _terminal.buffer.cursorX * cellSize.width,
        _terminal.buffer.absoluteCursorY * cellSize.height - scrollOffset,
        cellSize.width,
        cellSize.height,
      );
      if (rect == _terminalCursorRect) return;
      setState(() {
        _terminalCellSize = cellSize;
        _terminalCursorRect = rect;
      });
    });
  }

  int _getHexByteCount(String text) {
    final hexString = text.replaceAll(' ', '');
    if (hexString.isEmpty) return 0;
    return (hexString.length / 2).ceil();
  }

  ButtonStyle _toolbarElevatedStyle(Color backgroundColor) {
    return ElevatedButton.styleFrom(
      backgroundColor: backgroundColor,
      foregroundColor: Colors.white,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 32),
    );
  }

  ButtonStyle _toolbarFlatButtonStyle() {
    final overlay = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.08);
    return TextButton.styleFrom(
      overlayColor: overlay,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      minimumSize: const Size(0, 32),
    );
  }

  Widget _buildToolbarIconAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final color =
        onPressed == null
            ? Theme.of(context).disabledColor
            : IconTheme.of(context).color;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          hoverColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.06),
          highlightColor: Theme.of(
            context,
          ).colorScheme.primary.withValues(alpha: 0.12),
          splashColor: Colors.transparent,
          mouseCursor:
              onPressed == null
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }

  Widget _buildShellArea(RawDataViewModel vm) {
    final terminalTheme = _shellTerminalTheme(vm);
    return Column(
      children: [
        _buildShellToolbar(vm),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: terminalTheme.background,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TerminalView(
                    _terminal,
                    key: _terminalViewKey,
                    controller: _terminalController,
                    scrollController: _terminalScrollController,
                    theme: terminalTheme,
                    focusNode: _terminalFocusNode,
                    autofocus: false,
                    readOnly: vm.shellInputMode == RawShellInputMode.line,
                    hardwareKeyboardOnly: true,
                    onKeyEvent:
                        (node, event) =>
                            _handleShellTerminalKey(node, event, vm),
                    cursorType: TerminalCursorType.verticalBar,
                    textStyle: TerminalStyle(
                      fontFamily: vm.terminalFontFamily,
                      fontSize: vm.terminalFontSize,
                    ),
                    onSecondaryTapDown: (details, offset) async {
                      final selection = _terminalController.selection;
                      if (selection != null) {
                        final text = _terminal.buffer.getText(selection);
                        _terminalController.clearSelection();
                        await Clipboard.setData(ClipboardData(text: text));
                      } else {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text;
                        if (text != null) {
                          await vm.sendShellBytes(
                            Uint8List.fromList(utf8.encode(text)),
                          );
                        }
                      }
                    },
                  ),
                  _buildShellCursorOverlay(vm, terminalTheme),
                ],
              ),
            ),
          ),
        ),
        if (vm.shellInputMode == RawShellInputMode.line)
          _buildShellCommandLine(vm),
      ],
    );
  }

  Widget _buildShellCursorOverlay(
    RawDataViewModel vm,
    TerminalTheme terminalTheme,
  ) {
    final rect = _terminalCursorRect;
    if (rect == null ||
        !vm.shellMode ||
        vm.shellInputMode != RawShellInputMode.key) {
      return const SizedBox.shrink();
    }
    final color = terminalTheme.cursor;
    final child = switch (vm.shellCursorMode) {
      RawShellCursorMode.block => Container(
        color: color.withValues(alpha: 0.35),
      ),
      RawShellCursorMode.underline => Align(
        alignment: Alignment.bottomLeft,
        child: Container(width: rect.width, height: 2, color: color),
      ),
      RawShellCursorMode.verticalBar => Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 1,
          height: rect.height,
          child: ColoredBox(color: color),
        ),
      ),
    };
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(child: child),
    );
  }

  TerminalTheme _shellTerminalTheme(RawDataViewModel vm) {
    if (vm.shellThemeMode == RawShellThemeMode.dark) {
      return TerminalThemes.defaultTheme;
    }
    return const TerminalTheme(
      cursor: Color(0xFF2563EB),
      selection: Color(0x663B82F6),
      foreground: Color(0xFF202124),
      background: Color(0xFFFFFFFF),
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

  Widget _buildShellToolbar(RawDataViewModel vm) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showInputMode = constraints.maxWidth >= 900;
          return SizedBox(
            height: 40,
            child: ClipRect(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'Shell',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('普通收发'),
                    selected: false,
                    onSelected: (_) => vm.setShellMode(false),
                    avatar: const Icon(Icons.swap_horiz, size: 16),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        vm.isRawReceiving
                            ? () => vm.stopReceiving()
                            : vm.isConnected
                            ? () => vm.startReceiving()
                            : null,
                    icon: Icon(
                      vm.isRawReceiving ? Icons.stop : Icons.play_arrow,
                      size: 16,
                    ),
                    label: Text(vm.isRawReceiving ? '停止接收' : '开始接收'),
                    style: _toolbarElevatedStyle(
                      vm.isRawReceiving ? Colors.red : Colors.green,
                    ),
                  ),
                  if (showInputMode) ...[
                    const SizedBox(width: 8),
                    _buildShellInputModeSelector(vm),
                  ],
                  const Spacer(),
                  Text(
                    vm.isConnected ? '已连接' : '未连接',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          vm.isConnected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildToolbarIconAction(
                    tooltip: '清屏',
                    icon: Icons.clear,
                    onPressed: () {
                      _terminal.write('\x1b[2J\x1b[H\x1b[?25l');
                      _scrollTerminalToBottom();
                    },
                  ),
                  _buildToolbarIconAction(
                    tooltip: '保存',
                    icon: Icons.save,
                    onPressed: () => _showExportDialog(context, vm),
                  ),
                  _buildToolbarIconAction(
                    tooltip: 'Shell 设置',
                    icon: Icons.settings,
                    onPressed:
                        () => _showShellAdvancedSettingsDialog(context, vm),
                  ),
                  _buildShellMoreMenu(vm, showInputMode: showInputMode),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildShellInputModeSelector(RawDataViewModel vm) {
    return SegmentedButton<RawShellInputMode>(
      segments: const [
        ButtonSegment(
          value: RawShellInputMode.line,
          label: Text('命令行'),
          icon: Icon(Icons.keyboard_return, size: 16),
        ),
        ButtonSegment(
          value: RawShellInputMode.key,
          label: Text('逐键'),
          icon: Icon(Icons.keyboard, size: 16),
        ),
      ],
      selected: {vm.shellInputMode},
      onSelectionChanged:
          vm.isYmodemActive
              ? null
              : (values) => vm.setShellInputMode(values.single),
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }

  Widget _buildShellMoreMenu(
    RawDataViewModel vm, {
    required bool showInputMode,
  }) {
    return PopupMenuButton<String>(
      tooltip: '更多选项',
      icon: const Icon(Icons.more_vert, size: 20),
      splashRadius: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];
        if (!showInputMode) {
          items.add(_buildMenuHeader('输入模式'));
          items.add(
            PopupMenuItem(
              value: 'shell_line_input',
              enabled: !vm.isYmodemActive,
              onTap: () => vm.setShellInputMode(RawShellInputMode.line),
              child: _buildMenuItem(
                icon:
                    vm.shellInputMode == RawShellInputMode.line
                        ? Icons.radio_button_checked
                        : Icons.keyboard_return,
                label: '命令行',
              ),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'shell_key_input',
              enabled: !vm.isYmodemActive,
              onTap: () => vm.setShellInputMode(RawShellInputMode.key),
              child: _buildMenuItem(
                icon:
                    vm.shellInputMode == RawShellInputMode.key
                        ? Icons.radio_button_checked
                        : Icons.keyboard,
                label: '逐键',
              ),
            ),
          );
        }

        if (items.isNotEmpty) items.add(const PopupMenuDivider());
        items.add(_buildMenuHeader('更多功能'));
        items.add(
          PopupMenuItem(
            value: 'file_transfer',
            enabled: vm.isConnected || vm.isYmodemActive,
            onTap:
                () => WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _showFileTransferDialog(context, vm);
                }),
            child: _buildMenuItem(icon: Icons.folder_open, label: '文件发送/接收'),
          ),
        );
        return items;
      },
    );
  }

  Widget _buildShellCommandLine(RawDataViewModel vm) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _shellLineController,
              focusNode: _shellLineFocusNode,
              enabled: vm.isConnected && !vm.isYmodemActive,
              decoration: const InputDecoration(
                hintText: '输入命令后按 Enter 发送',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
              onSubmitted: (_) => _sendShellLine(vm),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed:
                vm.isConnected && !vm.isYmodemActive
                    ? () => _sendShellLine(vm)
                    : null,
            icon: const Icon(Icons.send),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }

  void _showFileTransferDialog(BuildContext context, RawDataViewModel vm) {
    var direction = _FileTransferDirection.send;
    var protocol = _ShellFileTransferProtocol.ymodem;
    var packetSizeMode = YmodemPacketSizeMode.auto;
    File? selectedFile;
    String? resultText;
    String? errorText;
    var running = false;

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (
                  context,
                  setDialogState,
                ) => StreamBuilder<YmodemTransferStatus>(
                  stream: vm.ymodemStatusStream,
                  initialData: vm.ymodemStatus,
                  builder: (context, snapshot) {
                    final status = snapshot.data ?? vm.ymodemStatus;
                    final isActive = status.isActive || running;
                    final canStart =
                        vm.isConnected &&
                        !isActive &&
                        (direction == _FileTransferDirection.receive ||
                            selectedFile != null);
                    return AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      title: const Text('文件发送/接收'),
                      content: SizedBox(
                        width: 430,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SegmentedButton<_FileTransferDirection>(
                              segments:
                                  _FileTransferDirection.values
                                      .map(
                                        (value) => ButtonSegment(
                                          value: value,
                                          label: Text(value.label),
                                        ),
                                      )
                                      .toList(),
                              selected: {direction},
                              onSelectionChanged:
                                  isActive
                                      ? null
                                      : (values) => setDialogState(() {
                                        direction = values.single;
                                        resultText = null;
                                        errorText = null;
                                      }),
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<_ShellFileTransferProtocol>(
                              initialValue: protocol,
                              decoration: const InputDecoration(
                                labelText: '传输协议',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              items:
                                  _ShellFileTransferProtocol.values
                                      .map(
                                        (value) => DropdownMenuItem(
                                          value: value,
                                          child: Text(value.label),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  isActive
                                      ? null
                                      : (value) => setDialogState(
                                        () => protocol = value ?? protocol,
                                      ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<YmodemPacketSizeMode>(
                              initialValue: packetSizeMode,
                              decoration: const InputDecoration(
                                labelText: '发送长度',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              items:
                                  YmodemPacketSizeMode.values
                                      .map(
                                        (value) => DropdownMenuItem(
                                          value: value,
                                          child: Text(value.label),
                                        ),
                                      )
                                      .toList(),
                              onChanged:
                                  isActive ||
                                          direction ==
                                              _FileTransferDirection.receive
                                      ? null
                                      : (value) => setDialogState(
                                        () =>
                                            packetSizeMode =
                                                value ?? packetSizeMode,
                                      ),
                            ),
                            const SizedBox(height: 12),
                            if (direction == _FileTransferDirection.send)
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      selectedFile == null
                                          ? '未选择文件'
                                          : selectedFile!.path,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed:
                                        isActive
                                            ? null
                                            : () async {
                                              final result =
                                                  await file_picker
                                                      .FilePicker.pickFiles();
                                              final path =
                                                  result?.files.single.path;
                                              if (path == null) return;
                                              setDialogState(() {
                                                selectedFile = File(path);
                                                resultText = null;
                                                errorText = null;
                                              });
                                            },
                                    icon: const Icon(Icons.attach_file),
                                    label: const Text('选择'),
                                  ),
                                ],
                              )
                            else
                              Text(
                                '接收文件将保存到应用目录 exports/ymodem。',
                                style: TextStyle(
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            const SizedBox(height: 16),
                            _buildFileTransferProgress(context, status),
                            if (resultText != null) ...[
                              const SizedBox(height: 8),
                              Text(resultText!),
                            ],
                            if (errorText != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                errorText!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed:
                              isActive
                                  ? () async {
                                    await vm.cancelYmodem();
                                    setDialogState(() => running = false);
                                  }
                                  : null,
                          child: const Text('取消传输'),
                        ),
                        TextButton(
                          onPressed:
                              isActive
                                  ? null
                                  : () => Navigator.of(context).pop(),
                          child: const Text('关闭'),
                        ),
                        ElevatedButton.icon(
                          onPressed:
                              canStart
                                  ? () async {
                                    setDialogState(() {
                                      running = true;
                                      resultText = null;
                                      errorText = null;
                                    });
                                    try {
                                      if (protocol ==
                                          _ShellFileTransferProtocol.ymodem) {
                                        if (direction ==
                                            _FileTransferDirection.send) {
                                          await vm.sendYmodemFile(
                                            selectedFile!,
                                            packetSizeMode: packetSizeMode,
                                          );
                                          resultText = '发送完成';
                                        } else {
                                          final file =
                                              await vm.receiveYmodemFile();
                                          resultText =
                                              file == null
                                                  ? '未接收文件'
                                                  : '接收完成: ${file.path}';
                                        }
                                      }
                                    } catch (error) {
                                      errorText = error.toString();
                                    } finally {
                                      if (context.mounted) {
                                        setDialogState(() => running = false);
                                      }
                                    }
                                  }
                                  : null,
                          icon: Icon(
                            direction == _FileTransferDirection.send
                                ? Icons.upload_file
                                : Icons.download,
                          ),
                          label: Text(direction.label),
                        ),
                      ],
                    );
                  },
                ),
          ),
    );
  }

  Widget _buildFileTransferProgress(
    BuildContext context,
    YmodemTransferStatus status,
  ) {
    final percent = status.totalBytes <= 0 ? 0.0 : status.progress * 100;
    final direction = switch (status.direction) {
      YmodemDirection.send => '发送',
      YmodemDirection.receive => '接收',
      null => '等待',
    };
    final hasStatus = status.phase != YmodemPhase.idle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value:
              status.isActive && status.totalBytes <= 0
                  ? null
                  : status.progress,
        ),
        const SizedBox(height: 8),
        Text(
          hasStatus
              ? '$direction ${status.fileName ?? ''}  '
                  '${_formatBytes(status.transferredBytes)} / '
                  '${_formatBytes(status.totalBytes)}  '
                  '${percent.toStringAsFixed(1)}%'
              : '等待开始传输',
          overflow: TextOverflow.ellipsis,
        ),
        if (hasStatus && status.message.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            status.message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  String _formatBytes(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${bytes.toStringAsFixed(0)} B';
  }

  KeyEventResult _handleShellTerminalKey(
    FocusNode node,
    KeyEvent event,
    RawDataViewModel vm,
  ) {
    if (!vm.shellMode || vm.shellInputMode != RawShellInputMode.key) {
      return KeyEventResult.ignored;
    }
    if (vm.isYmodemActive || !vm.isConnected) return KeyEventResult.handled;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final ctrl = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    final alt = keyboard.isAltPressed;
    final meta = keyboard.isMetaPressed;

    if (ctrl && shift && key == LogicalKeyboardKey.keyC) {
      _copyTerminalSelection();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      _pasteShellClipboard(vm);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      vm.sendShellBytes(Uint8List.fromList(const [0x03]));
      return KeyEventResult.handled;
    }

    final bytes = _shellBytesForKey(event, ctrl: ctrl, alt: alt, meta: meta);
    if (bytes == null || bytes.isEmpty) return KeyEventResult.handled;
    vm.sendShellBytes(bytes);
    return KeyEventResult.handled;
  }

  Uint8List? _shellBytesForKey(
    KeyEvent event, {
    required bool ctrl,
    required bool alt,
    required bool meta,
  }) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter) {
      return Uint8List.fromList(const [0x0D]);
    }
    if (key == LogicalKeyboardKey.backspace) {
      return Uint8List.fromList(const [0x7F]);
    }
    if (key == LogicalKeyboardKey.tab) {
      return Uint8List.fromList(const [0x09]);
    }
    if (key == LogicalKeyboardKey.escape) {
      return Uint8List.fromList(const [0x1B]);
    }
    if (ctrl && !alt && !meta) {
      final controlByte = _controlByteForKey(key);
      if (controlByte != null) return Uint8List.fromList([controlByte]);
    }
    if (ctrl || alt || meta) return null;

    final character = event.character;
    if (character == null || character.isEmpty) return null;
    return Uint8List.fromList(utf8.encode(character));
  }

  int? _controlByteForKey(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) {
      final code = label.toUpperCase().codeUnitAt(0);
      if (code >= 0x41 && code <= 0x5A) return code - 0x40;
    }
    return switch (key) {
      LogicalKeyboardKey.bracketLeft => 0x1B,
      LogicalKeyboardKey.backslash => 0x1C,
      LogicalKeyboardKey.bracketRight => 0x1D,
      LogicalKeyboardKey.digit6 => 0x1E,
      LogicalKeyboardKey.minus => 0x1F,
      _ => null,
    };
  }

  Future<void> _copyTerminalSelection() async {
    final selection = _terminalController.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    _terminalController.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteShellClipboard(RawDataViewModel vm) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    await vm.sendShellBytes(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SerialService>(context, listen: false);
    return ChangeNotifierProvider(
      create: (_) => RawDataViewModel(service),
      child: Consumer<RawDataViewModel>(
        builder: (context, vm, child) {
          _syncShellSubscription(vm);
          _syncShellFocus(vm);
          _syncReceiveText(vm);
          _scrollToBottom(vm);
          if (vm.shellMode) {
            return _buildShellArea(vm);
          }
          return Column(
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * _splitRatio,
                child: _buildReceiveArea(vm),
              ),
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  setState(() {
                    final delta =
                        details.delta.dy / MediaQuery.of(context).size.height;
                    _splitRatio = (_splitRatio + delta).clamp(0.2, 0.8);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: Container(
                    height: 8,
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.5),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildSendArea(vm)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReceiveArea(RawDataViewModel vm) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 使用固定断点决定折叠策略，避免宽度跳动：
              // - ≥ 820px: 全部展开
              // - 560px ~ 820px: 操作组（清空/保存/设置）折叠进菜单
              // - < 560px: 选项组（时间戳/HEX/滚动）和操作组都折叠
              final width = constraints.maxWidth;
              final showOptions = width >= 560;
              final showActions = width >= 820;
              final hasCollapsed = !showOptions || !showActions;

              return SizedBox(
                height: 40,
                child: ClipRect(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        '数据收发',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      if (vm.shellEnabled) ...[
                        FilterChip(
                          label: const Text('Shell'),
                          selected: vm.shellMode,
                          onSelected: vm.setShellMode,
                          avatar: const Icon(Icons.terminal, size: 16),
                        ),
                        const SizedBox(width: 8),
                      ],
                      ElevatedButton.icon(
                        onPressed:
                            vm.isRawReceiving
                                ? () => vm.stopReceiving()
                                : vm.isConnected
                                ? () => vm.startReceiving()
                                : null,
                        icon: Icon(
                          vm.isRawReceiving ? Icons.stop : Icons.play_arrow,
                          size: 16,
                        ),
                        label: Text(vm.isRawReceiving ? '停止接收' : '开始接收'),
                        style: _toolbarElevatedStyle(
                          vm.isRawReceiving ? Colors.red : Colors.green,
                        ),
                      ),
                      const Spacer(),
                      // 选项组（时间戳/HEX/自动滚动）
                      if (showOptions) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.showTimestamp,
                                onChanged:
                                    (value) => vm.setShowTimestamp(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('时间戳'),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.receiveHex,
                                onChanged: (value) => vm.setReceiveHex(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('HEX显示'),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: Checkbox(
                                value: vm.autoScroll,
                                onChanged: (value) => vm.setAutoScroll(value!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const Text('自动滚动'),
                          ],
                        ),
                      ],
                      // 操作组（清空/保存/高级设置）
                      if (showActions) ...[
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () => vm.clearData(),
                          icon: const Icon(Icons.clear, size: 18),
                          label: const Text('清空'),
                          style: _toolbarFlatButtonStyle(),
                        ),
                        TextButton.icon(
                          onPressed: () => _showExportDialog(context, vm),
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('保存'),
                          style: _toolbarFlatButtonStyle(),
                        ),
                        TextButton.icon(
                          onPressed:
                              () => _showRawAdvancedSettingsDialog(context, vm),
                          icon: const Icon(Icons.settings, size: 18),
                          label: const Text('高级设置'),
                          style: _toolbarFlatButtonStyle(),
                        ),
                      ],
                      // 有折叠的组时显示下拉菜单
                      if (hasCollapsed)
                        _buildRawCollapsedMenu(
                          context,
                          vm,
                          showOptions: showOptions,
                          showActions: showActions,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(4.0),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 数据列表或提示文字
                vm.receivedLines.isNotEmpty
                    ? SingleChildScrollView(
                      key: const Key('rawDataReceiveTextField'),
                      controller: _scrollController,
                      child: SizedBox(
                        width: double.infinity,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 28),
                          child: SelectableText(
                            _receiveText,
                            style: const TextStyle(
                              fontFamily: 'SarasaUiSC',
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    )
                    : const Center(
                      child: Text(
                        '发送的数据将显示在这里\n点击"开始接收"可同时显示接收数据',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ),
                // 右下角统计信息
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      vm.receiveHex
                          ? '接收: ${vm.dataStats['原始字节']} | 行数: ${vm.dataStats['文本行数']} | 缓存: ${vm.dataStats['文本缓存']}'
                          : '解码: ${vm.receiveEncoding} | 行数: ${vm.dataStats['文本行数']} | 缓存: ${vm.dataStats['文本缓存']}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendArea(RawDataViewModel vm) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // 工具栏：发送HEX + CRC 放同一行
          Row(
            children: [
              const Text('发送数据', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.keepSendText,
                    onChanged: (value) => vm.setKeepSendText(value!),
                  ),
                  const Text('发送后保留'),
                ],
              ),
              const SizedBox(width: 8),
              if (!vm.sendHex) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: vm.appendLineEnding,
                      onChanged: (value) => vm.setAppendLineEnding(value!),
                    ),
                    const Text('末尾回车'),
                  ],
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: NoAnimDropdown<String>(
                    value: vm.lineEnding,
                    hint: '回车',
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: '\r', child: Text(r'\r')),
                      DropdownMenuItem(value: '\n', child: Text(r'\n')),
                      DropdownMenuItem(value: '\r\n', child: Text(r'\r\n')),
                    ],
                    onChanged:
                        vm.appendLineEnding
                            ? (value) {
                              if (value != null) vm.setLineEnding(value);
                            }
                            : null,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: vm.sendHex,
                    onChanged: (value) => vm.setSendHex(value!),
                  ),
                  const Text('HEX发送'),
                ],
              ),
              if (vm.sendHex) ...[
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: vm.enableCrc,
                      onChanged: (value) => vm.setEnableCrc(value!),
                    ),
                    const Text('CRC'),
                  ],
                ),
                if (vm.enableCrc) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 90,
                    child: NoAnimDropdown<CrcType>(
                      value: vm.crcType,
                      hint: '类型',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: CrcType.crc8,
                          child: Text('CRC-8'),
                        ),
                        DropdownMenuItem(
                          value: CrcType.crc16,
                          child: Text('CRC-16'),
                        ),
                        DropdownMenuItem(
                          value: CrcType.crc32,
                          child: Text('CRC-32'),
                        ),
                      ],
                      onChanged: (value) => vm.setCrcType(value!),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 140,
                    child: NoAnimDropdown<String>(
                      value: vm.crcPolyName,
                      hint: '多项式',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        isDense: true,
                      ),
                      items:
                          getPolysByType(vm.crcType).keys.map((name) {
                            return DropdownMenuItem(
                              value: name,
                              child: Tooltip(
                                message: name,
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }).toList(),
                      onChanged: (value) => vm.setCrcPolyName(value!),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 92,
                    child: NoAnimDropdown<CrcByteOrder>(
                      value: vm.crcByteOrder,
                      hint: '字节序',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        isDense: true,
                      ),
                      items:
                          CrcByteOrder.values.map((order) {
                            return DropdownMenuItem(
                              value: order,
                              child: Text(order.label),
                            );
                          }).toList(),
                      onChanged: (value) => vm.setCrcByteOrder(value!),
                    ),
                  ),
                ],
              ],
            ],
          ),
          const SizedBox(height: 4),
          // 输入区域
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      TextField(
                        controller: _sendController,
                        decoration: InputDecoration(
                          hintText:
                              vm.sendHex ? '输入十六进制 (如: 01 02 03)' : '输入要发送的数据',
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        maxLines: null,
                        expands: true,
                        enabled: true,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        inputFormatters:
                            vm.sendHex ? [_HexInputFormatter()] : null,
                        onChanged: (value) {
                          if (vm.sendHex) {
                            _formatHexInput(value);
                          }
                          setState(() {});
                        },
                      ),
                      // 右下角长度显示
                      Positioned(
                        right: 8,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            vm.sendHex
                                ? '${_getHexByteCount(_sendController.text)} bytes'
                                : '${_sendController.text.length} chars',
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed:
                      vm.isConnected
                          ? () {
                            final data = vm.prepareSendData(
                              _sendController.text,
                            );
                            if (data != null) {
                              try {
                                vm.send(data);
                                if (!vm.keepSendText) {
                                  _sendController.clear();
                                  setState(() {});
                                }
                              } catch (e) {
                                if (!context.mounted) return;
                                _showSnackBar(context, e.toString());
                              }
                            }
                          }
                          : null,
                  icon: const Icon(Icons.send),
                  label: const Text('发送'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, RawDataViewModel vm) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: const Text('保存数据'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择保存格式：'),
                const SizedBox(height: 8),
                ...vm.dataStats.entries.map(
                  (e) => Text(
                    '${e.key}: ${e.value}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final path = await vm.exportAsText();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  if (path != null) {
                    _showSnackBar(context, '已保存为文本: $path');
                  }
                },
                icon: const Icon(Icons.text_snippet),
                label: const Text('文本 (.txt)'),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  final path = await vm.exportAsRawBytes();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  if (path != null) {
                    _showSnackBar(context, '已保存为原始字节: $path');
                  }
                },
                icon: const Icon(Icons.memory),
                label: const Text('原始字节 (.bin)'),
              ),
            ],
          ),
    );
  }

  void _showSnackBar(BuildContext context, String message) {
    AppNotifications.show(message, messenger: ScaffoldMessenger.of(context));
  }

  Future<void> _sendShellLine(RawDataViewModel vm) async {
    final text = _shellLineController.text;
    if (text.isEmpty) return;
    try {
      await vm.sendShellText(text);
      _terminal.write('$text\r\n');
      _shellLineController.clear();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(context, e.toString());
    }
  }

  void _formatHexInput(String value) {
    // Remove all spaces first
    final hexOnly = value.replaceAll(' ', '');
    // Re-insert spaces every 2 chars
    final formatted = <String>[];
    for (var i = 0; i < hexOnly.length; i += 2) {
      if (i + 2 <= hexOnly.length) {
        formatted.add(hexOnly.substring(i, i + 2));
      } else {
        formatted.add(hexOnly.substring(i));
      }
    }
    final newText = formatted.join(' ');
    if (newText != value) {
      _sendController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _showRawAdvancedSettingsDialog(
    BuildContext context,
    RawDataViewModel vm,
  ) {
    final timeWindowController = TextEditingController(
      text: vm.timeWindowUs.toString(),
    );
    final displayLineLimitController = TextEditingController(
      text: vm.displayLineLimit.toString(),
    );
    var shellEnabled = vm.shellEnabled;
    var selectedEncoding = vm.receiveEncoding;
    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: const Text('普通收发设置'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('文本解码方式:'),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 220,
                        child: NoAnimDropdown<String>(
                          value: selectedEncoding,
                          hint: '解码',
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            isDense: true,
                          ),
                          items:
                              RawDataViewModel.availableEncodings.map((e) {
                                return DropdownMenuItem(
                                  value: e['id'],
                                  child: Text(e['name']!),
                                );
                              }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => selectedEncoding = value);
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '非 HEX 模式下，使用选定的编码将原始字节解码为文本。',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text('HEX分包时间 (μs):'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: timeWindowController,
                        decoration: const InputDecoration(
                          hintText: '10 ~ 10000',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '仅在 HEX显示 + 时间戳 开启时生效。当前: ${vm.timeWindowUs}μs (${vm.timeWindowUs < 1000 ? "显示微秒级时间戳" : "显示毫秒级时间戳"})',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text('接收区最大显示行数:'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: displayLineLimitController,
                        decoration: const InputDecoration(
                          hintText: '100 ~ 100000',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '默认 10000 行。降低上限后会立即移除最早的显示内容，不影响原始字节导出。',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 20),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('启用 Shell 模式入口'),
                        subtitle: const Text(
                          '开启后普通收发工具栏显示 Shell 切换按钮。',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: shellEnabled,
                        onChanged:
                            (value) =>
                                setDialogState(() => shellEnabled = value),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final us = int.tryParse(timeWindowController.text);
                        final displayLineLimit = int.tryParse(
                          displayLineLimitController.text,
                        );
                        if (us == null || us < 10 || us > 10000) {
                          _showSnackBar(context, '请输入 10 ~ 10000 之间的数值');
                          return;
                        }
                        if (displayLineLimit == null ||
                            displayLineLimit <
                                SerialService.minDisplayLineLimit ||
                            displayLineLimit >
                                SerialService.maxDisplayLineLimit) {
                          _showSnackBar(context, '显示行数请输入 100 ~ 100000 之间的数值');
                          return;
                        }

                        final changed =
                            us != vm.timeWindowUs ||
                            displayLineLimit != vm.displayLineLimit ||
                            shellEnabled != vm.shellEnabled ||
                            selectedEncoding != vm.receiveEncoding;
                        if (changed) {
                          vm.setReceiveEncoding(selectedEncoding);
                          vm.setTimeWindowUs(us);
                          vm.setDisplayLineLimit(displayLineLimit);
                          vm.setShellEnabled(shellEnabled);
                        }
                        Navigator.of(context).pop();
                        if (changed) {
                          _showSnackBar(
                            context,
                            '高级设置已保存，接收区最多显示 $displayLineLimit 行',
                          );
                        }
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
          ),
    );
  }

  void _showShellAdvancedSettingsDialog(
    BuildContext context,
    RawDataViewModel vm,
  ) {
    final terminalFontSizeController = TextEditingController(
      text: vm.terminalFontSize.toStringAsFixed(0),
    );
    var terminalFontFamily =
        _terminalFontFamilies.contains(vm.terminalFontFamily)
            ? vm.terminalFontFamily
            : 'Consolas';
    var shellThemeMode = vm.shellThemeMode;
    var shellCursorMode = vm.shellCursorMode;
    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: const Text('Shell 设置'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('终端字号:'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: terminalFontSizeController,
                        decoration: const InputDecoration(
                          hintText: '10 ~ 24',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text('终端字体:'),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: terminalFontFamily,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            _terminalFontFamilies
                                .map(
                                  (font) => DropdownMenuItem(
                                    value: font,
                                    child: Text(
                                      font,
                                      style: TextStyle(fontFamily: font),
                                    ),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            (value) => setDialogState(
                              () => terminalFontFamily = value ?? 'Consolas',
                            ),
                      ),
                      const SizedBox(height: 20),
                      const Text('终端主题:'),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<RawShellThemeMode>(
                        initialValue: shellThemeMode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            RawShellThemeMode.values
                                .map(
                                  (mode) => DropdownMenuItem(
                                    value: mode,
                                    child: Text(mode.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            (value) => setDialogState(
                              () => shellThemeMode = value ?? shellThemeMode,
                            ),
                      ),
                      const SizedBox(height: 20),
                      const Text('光标样式:'),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<RawShellCursorMode>(
                        initialValue: shellCursorMode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            RawShellCursorMode.values
                                .map(
                                  (mode) => DropdownMenuItem(
                                    value: mode,
                                    child: Text(mode.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            (value) => setDialogState(
                              () => shellCursorMode = value ?? shellCursorMode,
                            ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final terminalFontSize = double.tryParse(
                          terminalFontSizeController.text,
                        );
                        if (terminalFontSize == null ||
                            terminalFontSize < 10 ||
                            terminalFontSize > 24) {
                          _showSnackBar(context, '终端字号请输入 10 ~ 24 之间的数值');
                          return;
                        }

                        vm.setTerminalFontSize(terminalFontSize);
                        vm.setTerminalFontFamily(terminalFontFamily);
                        vm.setShellThemeMode(shellThemeMode);
                        vm.setShellCursorMode(shellCursorMode);
                        Navigator.of(context).pop();
                        _showSnackBar(context, 'Shell 设置已保存');
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
          ),
    );
  }

  /// 折叠菜单：显示未平铺的组
  Widget _buildRawCollapsedMenu(
    BuildContext context,
    RawDataViewModel vm, {
    required bool showOptions,
    required bool showActions,
  }) {
    return PopupMenuButton<String>(
      tooltip: '更多选项',
      icon: const Icon(Icons.more_vert, size: 20),
      splashRadius: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];

        // 选项组（如果未平铺）
        if (!showOptions) {
          items.add(_buildMenuHeader('显示选项'));
          items.add(
            PopupMenuItem(
              value: 'timestamp',
              child: _buildMenuItem(
                icon:
                    vm.showTimestamp
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: '时间戳',
              ),
              onTap: () => vm.setShowTimestamp(!vm.showTimestamp),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'hex',
              child: _buildMenuItem(
                icon:
                    vm.receiveHex
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: 'HEX显示',
              ),
              onTap: () => vm.setReceiveHex(!vm.receiveHex),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'autoscroll',
              child: _buildMenuItem(
                icon:
                    vm.autoScroll
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                label: '自动滚动',
              ),
              onTap: () => vm.setAutoScroll(!vm.autoScroll),
            ),
          );
        }

        // 操作组（如果未平铺）
        if (!showActions) {
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(_buildMenuHeader('操作'));
          items.add(
            PopupMenuItem(
              value: 'clear',
              child: _buildMenuItem(icon: Icons.clear, label: '清空'),
              onTap: () => vm.clearData(),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'export',
              child: _buildMenuItem(icon: Icons.save, label: '保存'),
              onTap: () => _showExportDialog(context, vm),
            ),
          );
          items.add(
            PopupMenuItem(
              value: 'advanced',
              child: _buildMenuItem(icon: Icons.settings, label: '高级设置'),
              onTap: () => _showRawAdvancedSettingsDialog(context, vm),
            ),
          );
        }

        return items;
      },
    );
  }

  /// 构建菜单分组标题
  PopupMenuItem<String> _buildMenuHeader(String label) {
    return PopupMenuItem(
      value: 'header_$label',
      enabled: false,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: Colors.grey.shade600,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 构建下拉菜单项
  Widget _buildMenuItem({required IconData icon, required String label}) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// HEX input formatter: only allows 0-9, A-F, a-f, and spaces
class _HexInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Allow only hex chars and spaces
    final filtered = newValue.text.replaceAll(RegExp(r'[^0-9A-Fa-f ]'), '');
    if (filtered != newValue.text) {
      return TextEditingValue(
        text: filtered,
        selection: TextSelection.collapsed(offset: filtered.length),
      );
    }
    return newValue;
  }
}
