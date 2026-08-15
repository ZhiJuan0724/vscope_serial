import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/modbus_models.dart';
import '../../services/app_notifications.dart';
import '../../services/modbus_client_service.dart';
import '../widgets/common_widgets.dart';
import '../widgets/modbus_register_grid.dart';
import '../widgets/plot_color_picker.dart';

class ModbusDetachedPage extends StatefulWidget {
  const ModbusDetachedPage({
    super.key,
    required this.windowId,
    required this.pageKey,
  });

  final int windowId;
  final String pageKey;

  @override
  State<ModbusDetachedPage> createState() => _ModbusDetachedPageState();
}

class _ModbusDetachedPageState extends State<ModbusDetachedPage> {
  ModbusRegisterPage? _page;
  ModbusRegisterLayoutMode _layoutMode = ModbusRegisterLayoutMode.columnMajor;
  bool _sessionActive = false;
  final Map<String, ModbusRowState> _states = {};
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.setMethodHandler(_handleMethod);
    _requestSnapshot();
  }

  void _requestSnapshot() {
    final args = {'pageKey': widget.pageKey};
    unawaited(DesktopMultiWindow.invokeMethod(0, 'modbusReady', args));
    // 子引擎可能在首帧之后才完成方法通道注册，因此重试一次，避免独立窗口空白。
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (mounted && _page == null) {
        unawaited(DesktopMultiWindow.invokeMethod(0, 'modbusReady', args));
      }
    });
  }

  @override
  void dispose() {
    DesktopMultiWindow.setMethodHandler(null);
    super.dispose();
  }

  Future<dynamic> _handleMethod(MethodCall call, int fromWindowId) async {
    if (call.method != 'modbusSnapshot' || call.arguments is! Map) return null;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final page = ModbusRegisterPage.fromJson(args['page']);
    if (page == null) return null;
    final states = <String, ModbusRowState>{};
    final rawStates = args['states'];
    if (rawStates is Map) {
      for (final entry in rawStates.entries) {
        final value =
            entry.value is Map
                ? Map<String, dynamic>.from(entry.value as Map)
                : const <String, dynamic>{};
        final raw =
            value['rawRegisters'] is List
                ? [
                  for (final item in value['rawRegisters'] as List)
                    (item as num).toInt(),
                ]
                : const <int>[];
        final timestamp = DateTime.tryParse('${value['updatedAt'] ?? ''}');
        states['${entry.key}'] = ModbusRowState(
          value: value['value'],
          rawRegisters: raw,
          error: value['error'],
          updatedAt: timestamp,
          busy: value['busy'] == true,
          lastWriteValue: value['lastWriteValue'] as String?,
        );
      }
    }
    if (!mounted) return null;
    setState(() {
      _page = page;
      _layoutMode = ModbusRegisterLayoutMode.fromValue(args['layoutMode']);
      _sessionActive = args['sessionActive'] == true;
      _states
        ..clear()
        ..addAll(states);
    });
    return null;
  }

  Future<void> _command(
    String command, [
    Map<String, Object?> extra = const {},
  ]) => DesktopMultiWindow.invokeMethod(0, 'modbusCommand', {
    'pageKey': widget.pageKey,
    'command': command,
    ...extra,
  });

  Future<void> _closeWindow() async {
    if (_closing) return;
    _closing = true;
    await DesktopMultiWindow.invokeMethod(0, 'modbusDetachedClosed', {
      'pageKey': widget.pageKey,
    });
    await WindowController.fromWindowId(widget.windowId).close();
  }

  Future<bool> _confirm(
    String title,
    String message, {
    String confirmLabel = '删除',
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                label: confirmLabel,
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<void> _confirmDeleteRow(ModbusRegisterRow row) async {
    final confirmed = await _confirm(
      '删除寄存器',
      '确定删除地址 ${row.address} 的寄存器吗？其变量类型、备注、背景色和轮询配置将一并删除。',
    );
    if (!confirmed || !mounted) return;
    await _command('removeRow', {'rowId': row.id});
  }

  Future<void> _showRowMenu(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    Offset position,
  ) async {
    final action = await showModbusPaintedMenu<ModbusRowMenuAction>(
      context: context,
      position: position,
      title: '${row.address}[${row.variableType.label}]',
      items: [
        if (page.area.isWritable)
          const ModbusPaintedMenuItem(
            Icons.send_outlined,
            '快速发送',
            ModbusRowMenuAction.quickSend,
          ),
        const ModbusPaintedMenuItem(
          Icons.settings_outlined,
          '配置寄存器',
          ModbusRowMenuAction.configure,
        ),
        ModbusPaintedMenuItem(
          Icons.numbers,
          row.displayRadix == ModbusDisplayRadix.decimal
              ? '切换为十六进制显示'
              : '切换为十进制显示',
          ModbusRowMenuAction.toggleRadix,
        ),
        const ModbusPaintedMenuItem(
          Icons.delete_outline,
          '删除寄存器',
          ModbusRowMenuAction.delete,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case ModbusRowMenuAction.quickSend:
        await _showOneShotSend(page, row);
      case ModbusRowMenuAction.configure:
        await _showRowEditor(page, row);
      case ModbusRowMenuAction.toggleRadix:
        final next = row.copyWith(
          displayRadix:
              row.displayRadix == ModbusDisplayRadix.decimal
                  ? ModbusDisplayRadix.hexadecimal
                  : ModbusDisplayRadix.decimal,
        );
        await _command('updateRow', {
          'rowId': row.id,
          'row': next.toSparseJson(page.area),
        });
      case ModbusRowMenuAction.delete:
        await _confirmDeleteRow(row);
    }
  }

  Future<void> _showRowEditor(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
  ) async {
    final pollController = TextEditingController(text: '${row.pollIntervalMs}');
    final retriesController = TextEditingController(text: '${row.readRetries}');
    final sendIntervalController = TextEditingController(
      text: '${row.sendIntervalMs}',
    );
    final valueController = TextEditingController(text: row.sendValue);
    final stepController = TextEditingController(text: row.sendStep);
    final noteController = TextEditingController(text: row.note);
    var pollEnabled = row.pollEnabled;
    var sendEnabled = row.sendEnabled;
    var mode = row.sendMode;
    var variableType = row.variableType;
    var backgroundArgb = row.backgroundArgb;
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: Text(
                    '${row.address}[${row.variableType.label}] 配置寄存器',
                  ),
                  content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!page.area.isBitArea)
                            AppDialogDropdown<ModbusVariableType>(
                              value: variableType,
                              labelText: '变量类型',
                              items: [
                                for (final item in ModbusVariableType.values)
                                  DropdownMenuItem(
                                    value: item,
                                    child: Text(item.label),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setDialogState(() => variableType = value);
                                }
                              },
                            ),
                          const SizedBox(height: 10),
                          AppDialogTextField(
                            controller: noteController,
                            labelText: '寄存器备注',
                          ),
                          const SizedBox(height: 14),
                          AppSwitchRow(
                            title: const Text('轮询查询'),
                            value: pollEnabled,
                            onChanged:
                                (value) =>
                                    setDialogState(() => pollEnabled = value),
                          ),
                          if (pollEnabled) ...[
                            AppDialogTextField(
                              controller: pollController,
                              keyboardType: TextInputType.number,
                              labelText:
                                  '查询周期（$modbusMinIntervalMs～$modbusMaxIntervalMs ms）',
                            ),
                            const SizedBox(height: 10),
                            AppDialogTextField(
                              controller: retriesController,
                              keyboardType: TextInputType.number,
                              labelText: '读取重试（0～3）',
                            ),
                          ],
                          if (page.area.isWritable) ...[
                            AppSwitchRow(
                              title: const Text('周期发送'),
                              value: sendEnabled,
                              onChanged:
                                  (value) =>
                                      setDialogState(() => sendEnabled = value),
                            ),
                            if (sendEnabled) ...[
                              AppDialogDropdown<ModbusSendValueMode>(
                                value: mode,
                                labelText: '周期发送模式',
                                items: [
                                  for (final item in ModbusSendValueMode.values)
                                    DropdownMenuItem(
                                      value: item,
                                      child: Text(item.label),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(() => mode = value);
                                  }
                                },
                              ),
                              const SizedBox(height: 10),
                              AppDialogTextField(
                                controller: valueController,
                                labelText: '周期发送值',
                              ),
                              if (mode == ModbusSendValueMode.increment ||
                                  mode == ModbusSendValueMode.decrement) ...[
                                const SizedBox(height: 10),
                                AppDialogTextField(
                                  controller: stepController,
                                  labelText: '自增/自减步长',
                                ),
                              ],
                              const SizedBox(height: 10),
                              AppDialogTextField(
                                controller: sendIntervalController,
                                keyboardType: TextInputType.number,
                                labelText:
                                    '发送周期（$modbusMinIntervalMs～$modbusMaxIntervalMs ms）',
                              ),
                            ],
                          ],
                          const SizedBox(height: 14),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: AppColorSwatchPicker(
                              selectedColor:
                                  backgroundArgb == null
                                      ? null
                                      : Color(backgroundArgb!),
                              presetColors: const [
                                Color(0xFFFFF3CD),
                                Color(0xFFDFF5E1),
                                Color(0xFFDDEBFF),
                                Color(0xFFF2DDF5),
                              ],
                              onChanged:
                                  (color) => setDialogState(
                                    () => backgroundArgb = color?.toARGB32(),
                                  ),
                              onCustomColor:
                                  (initial) => showPlotCustomColorPicker(
                                    context,
                                    initial,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      label: '保存',
                    ),
                  ],
                ),
          ),
    );
    final poll = int.tryParse(pollController.text.trim());
    final retries = int.tryParse(retriesController.text.trim());
    final sendInterval = int.tryParse(sendIntervalController.text.trim());
    final valid =
        !pollEnabled ||
        (poll != null &&
            poll >= modbusMinIntervalMs &&
            poll <= modbusMaxIntervalMs &&
            retries != null &&
            retries >= 0 &&
            retries <= 3);
    final sendValid =
        !sendEnabled ||
        (sendInterval != null &&
            sendInterval >= modbusMinIntervalMs &&
            sendInterval <= modbusMaxIntervalMs);
    if (result == true && valid && sendValid) {
      final updated = row.copyWith(
        variableType: variableType,
        pollEnabled: pollEnabled,
        pollIntervalMs: poll ?? row.pollIntervalMs,
        readRetries: retries ?? row.readRetries,
        sendEnabled: page.area.isWritable && sendEnabled,
        sendIntervalMs: sendInterval ?? row.sendIntervalMs,
        sendMode: mode,
        sendValue:
            valueController.text.trim().isEmpty
                ? '0'
                : valueController.text.trim(),
        sendStep:
            stepController.text.trim().isEmpty
                ? '1'
                : stepController.text.trim(),
        note: noteController.text.trim(),
        backgroundArgb: backgroundArgb,
        clearBackground: backgroundArgb == null,
      );
      await _command('updateRow', {
        'rowId': row.id,
        'row': updated.toSparseJson(page.area),
      });
    } else if (result == true) {
      AppNotifications.show('周期或重试参数无效');
    }
    for (final controller in [
      pollController,
      retriesController,
      sendIntervalController,
      valueController,
      stepController,
      noteController,
    ]) {
      controller.dispose();
    }
  }

  // 保留此兼容入口，以读取旧版本创建的配置。
  // ignore: unused_element
  Future<void> _showLegacyRowMenu(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    Offset position,
  ) async {
    final action = await showModbusPaintedMenu<String>(
      context: context,
      position: position,
      title: '配置寄存器',
      items: [
        ModbusPaintedMenuItem(
          Icons.sync,
          row.pollEnabled ? '取消轮询查询' : '设置轮询查询',
          'poll',
        ),
        if (page.area.isWritable)
          ModbusPaintedMenuItem(
            Icons.send_outlined,
            row.sendEnabled ? '取消周期发送' : '设置周期发送',
            'send',
          ),
        if (page.area.isWritable)
          const ModbusPaintedMenuItem(Icons.edit, '编辑值并发送一次', 'once'),
        const ModbusPaintedMenuItem(Icons.numbers, '切换十进制/十六进制显示', 'radix'),
        const ModbusPaintedMenuItem(Icons.notes, '编辑备注', 'note'),
        const ModbusPaintedMenuItem(Icons.palette_outlined, '修改背景颜色', 'color'),
        if (!page.area.isBitArea)
          const ModbusPaintedMenuItem(
            Icons.category_outlined,
            '修改变量类型',
            'type',
          ),
        const ModbusPaintedMenuItem(Icons.delete_outline, '删除寄存器行', 'delete'),
      ],
    );
    switch (action) {
      case 'poll':
        await _command('setRowPolling', {
          'rowId': row.id,
          'enabled': !row.pollEnabled,
        });
      case 'send':
        await _command('setRowSending', {
          'rowId': row.id,
          'enabled': !row.sendEnabled,
        });
      case 'once':
        await _showOneShotSend(page, row);
      case 'radix':
        final next = row.copyWith(
          displayRadix:
              row.displayRadix == ModbusDisplayRadix.decimal
                  ? ModbusDisplayRadix.hexadecimal
                  : ModbusDisplayRadix.decimal,
        );
        await _command('updateRow', {
          'rowId': row.id,
          'row': next.toSparseJson(page.area),
        });
      case 'note':
        if (!mounted) return;
        final controller = TextEditingController(text: row.note);
        final note = await showDialog<String>(
          context: context,
          builder:
              (dialogContext) => AlertDialog(
                title: const Text('编辑备注'),
                content: TextField(controller: controller, autofocus: true),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消'),
                  ),
                  ElevatedButton(
                    onPressed:
                        () => Navigator.pop(dialogContext, controller.text),
                    child: const Text('确定'),
                  ),
                ],
              ),
        );
        controller.dispose();
        if (note != null) {
          await _command('updateRow', {
            'rowId': row.id,
            'row': row.copyWith(note: note).toSparseJson(page.area),
          });
        }
      case 'color':
        if (!mounted) return;
        final color = await showDialog<int?>(
          context: context,
          builder:
              (dialogContext) => AlertDialog(
                title: const Text('修改背景颜色'),
                content: Wrap(
                  spacing: 8,
                  children: [
                    for (final color in const [
                      Colors.transparent,
                      Color(0xFFFFF3CD),
                      Color(0xFFD1ECF1),
                      Color(0xFFD4EDDA),
                      Color(0xFFF8D7DA),
                    ])
                      IconButton(
                        tooltip: '选择颜色',
                        onPressed:
                            () => Navigator.pop(
                              dialogContext,
                              color == Colors.transparent
                                  ? null
                                  : color.toARGB32(),
                            ),
                        icon: Icon(
                          Icons.square,
                          color:
                              color == Colors.transparent ? Colors.grey : color,
                        ),
                      ),
                  ],
                ),
              ),
        );
        await _command('updateRow', {
          'rowId': row.id,
          'row': row
              .copyWith(backgroundArgb: color, clearBackground: color == null)
              .toSparseJson(page.area),
        });
      case 'type':
        if (!mounted) return;
        final type = await showDialog<ModbusVariableType>(
          context: context,
          builder:
              (dialogContext) => SimpleDialog(
                title: const Text('修改变量类型'),
                children: [
                  for (final item in ModbusVariableType.values)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialogContext, item),
                      child: Text(item.label),
                    ),
                ],
              ),
        );
        if (type != null) {
          await _command('updateRow', {
            'rowId': row.id,
            'row': row.copyWith(variableType: type).toSparseJson(page.area),
          });
        }
      case 'delete':
        await _confirmDeleteRow(row);
    }
  }

  Future<void> _showOneShotSend(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
  ) async {
    final controller = TextEditingController(text: row.sendValue);
    final value = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text('${row.address}[${row.variableType.label}] 一次性发送'),
            content: AppDialogTextField(controller: controller, labelText: '值'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('发送'),
              ),
            ],
          ),
    );
    controller.dispose();
    if (value != null) {
      await _command('sendOnce', {'rowId': row.id, 'value': value});
    }
  }

  Future<void> _showAddRows(ModbusRegisterPage page) async {
    final addressController = TextEditingController(text: '0');
    final countController = TextEditingController(text: '1');
    var type = ModbusVariableType.defaultFor(page.area);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: const Text('添加寄存器'),
                  content: SizedBox(
                    width: 380,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppDialogTextField(
                          controller: addressController,
                          keyboardType: TextInputType.number,
                          labelText: '起始地址（0基）',
                        ),
                        const SizedBox(height: 12),
                        AppDialogTextField(
                          controller: countController,
                          keyboardType: TextInputType.number,
                          labelText: '添加数量',
                        ),
                        if (!page.area.isBitArea) ...[
                          const SizedBox(height: 12),
                          AppDialogDropdown<ModbusVariableType>(
                            value: type,
                            labelText: '变量类型',
                            items: [
                              for (final item in ModbusVariableType.values)
                                DropdownMenuItem(
                                  value: item,
                                  child: Text(item.label),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => type = value);
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      label: '添加',
                    ),
                  ],
                ),
          ),
    );
    final start = int.tryParse(addressController.text.trim());
    final count = int.tryParse(countController.text.trim());
    addressController.dispose();
    countController.dispose();
    if (confirmed != true || start == null || count == null) return;
    if (start < 0 || count < 1 || count > 1000 || start + count > 0x10000) {
      return;
    }
    await _command('addRows', {
      'start': start,
      'count': count,
      'variableType': type.value,
    });
  }

  Future<void> _showBlankMenu(ModbusRegisterPage page, Offset position) async {
    final action = await showModbusPaintedMenu<String>(
      context: context,
      position: position,
      title: '寄存器页面',
      items: const [ModbusPaintedMenuItem(Icons.add, '添加单个寄存器', 'add')],
    );
    if (action == 'add') await _showAddRows(page);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      body:
          page == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  SizedBox(
                    height: 38,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        ToolbarStartStopButton(
                          running: page.enabled && _sessionActive,
                          label: page.enabled && _sessionActive ? '停止' : '开始',
                          tooltip:
                              page.enabled && _sessionActive
                                  ? '停止此页面轮询和周期发送'
                                  : _sessionActive &&
                                      page.rows.any((row) => row.pollEnabled)
                                  ? '开始此页面轮询和周期发送'
                                  : '请先开始Modbus并至少开启一个寄存器轮询',
                          onPressed:
                              _sessionActive &&
                                      (page.enabled ||
                                          page.rows.any(
                                            (row) => row.pollEnabled,
                                          ))
                                  ? () => _command('setPageEnabled', {
                                    'enabled': !page.enabled,
                                  })
                                  : null,
                        ),
                        ToolbarIconButton(
                          icon: const Icon(Icons.playlist_add),
                          tooltip: '批量添加寄存器',
                          onPressed: () => _showAddRows(page),
                        ),
                        ToolbarToggleIconButton(
                          icon: const Icon(Icons.category_outlined),
                          tooltip:
                              page.showVariableType
                                  ? '隐藏变量类型（u16）'
                                  : '显示变量类型（u16）',
                          selected: page.showVariableType,
                          onPressed:
                              () => _command('setPageVariableTypeVisible', {
                                'visible': !page.showVariableType,
                              }),
                        ),
                        const Spacer(),
                        Text(
                          _sessionActive ? '已连接' : '未连接',
                          style: TextStyle(
                            color:
                                _sessionActive
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                        ToolbarIconButton(
                          icon: const Icon(Icons.close),
                          tooltip: '关闭独立窗口',
                          onPressed: _closeWindow,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ModbusRegisterGrid(
                      page: page,
                      layoutMode: _layoutMode,
                      rowState:
                          (row) => _states[row.id] ?? const ModbusRowState(),
                      onRowContextMenu:
                          (row, position) => _showRowMenu(page, row, position),
                      onBlankContextMenu:
                          (position) => _showBlankMenu(page, position),
                    ),
                  ),
                ],
              ),
    );
  }
}
