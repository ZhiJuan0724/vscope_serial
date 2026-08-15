import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/app_strings.dart';
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
    String? confirmLabel,
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
                child: Text(AppStrings.common.cancel),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                label: confirmLabel ?? AppStrings.common.delete,
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<void> _confirmDeleteRow(ModbusRegisterRow row) async {
    final confirmed = await _confirm(
      AppStrings.modbus.deleteRegister,
      AppStrings.modbus.deleteRegisterConfirmMessage(row.address),
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
          ModbusPaintedMenuItem(
            Icons.send_outlined,
            AppStrings.modbus.quickSend,
            ModbusRowMenuAction.quickSend,
          ),
        ModbusPaintedMenuItem(
          Icons.settings_outlined,
          AppStrings.modbus.configureRegister,
          ModbusRowMenuAction.configure,
        ),
        ModbusPaintedMenuItem(
          Icons.numbers,
          row.displayRadix == ModbusDisplayRadix.decimal
              ? AppStrings.modbus.switchToHexDisplay
              : AppStrings.modbus.switchToDecimalDisplay,
          ModbusRowMenuAction.toggleRadix,
        ),
        ModbusPaintedMenuItem(
          Icons.delete_outline,
          AppStrings.modbus.deleteRegister,
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
                    AppStrings.modbus.configureRegisterTitle(
                      row.address,
                      row.variableType.label,
                    ),
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
                              labelText: AppStrings.modbus.variableType,
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
                            labelText: AppStrings.modbus.registerNote,
                          ),
                          const SizedBox(height: 14),
                          AppSwitchRow(
                            title: Text(AppStrings.modbus.pollQuery),
                            value: pollEnabled,
                            onChanged:
                                (value) =>
                                    setDialogState(() => pollEnabled = value),
                          ),
                          if (pollEnabled) ...[
                            AppDialogTextField(
                              controller: pollController,
                              keyboardType: TextInputType.number,
                              labelText: AppStrings.modbus.pollInterval(
                                modbusMinIntervalMs,
                                modbusMaxIntervalMs,
                              ),
                            ),
                            const SizedBox(height: 10),
                            AppDialogTextField(
                              controller: retriesController,
                              keyboardType: TextInputType.number,
                              labelText: AppStrings.modbus.readRetries,
                            ),
                          ],
                          if (page.area.isWritable) ...[
                            AppSwitchRow(
                              title: Text(AppStrings.modbus.periodicSend),
                              value: sendEnabled,
                              onChanged:
                                  (value) =>
                                      setDialogState(() => sendEnabled = value),
                            ),
                            if (sendEnabled) ...[
                              AppDialogDropdown<ModbusSendValueMode>(
                                value: mode,
                                labelText: AppStrings.modbus.periodicSendMode,
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
                                labelText: AppStrings.modbus.periodicSendValue,
                              ),
                              if (mode == ModbusSendValueMode.increment ||
                                  mode == ModbusSendValueMode.decrement) ...[
                                const SizedBox(height: 10),
                                AppDialogTextField(
                                  controller: stepController,
                                  labelText:
                                      AppStrings.modbus.incrementDecrementStep,
                                ),
                              ],
                              const SizedBox(height: 10),
                              AppDialogTextField(
                                controller: sendIntervalController,
                                keyboardType: TextInputType.number,
                                labelText: AppStrings.modbus.sendInterval(
                                  modbusMinIntervalMs,
                                  modbusMaxIntervalMs,
                                ),
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
                      child: Text(AppStrings.common.cancel),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      label: AppStrings.common.save,
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
      title: AppStrings.modbus.configureRegister,
      items: [
        ModbusPaintedMenuItem(
          Icons.sync,
          row.pollEnabled
              ? AppStrings.modbus.cancelPollQuery
              : AppStrings.modbus.setPollQuery,
          'poll',
        ),
        if (page.area.isWritable)
          ModbusPaintedMenuItem(
            Icons.send_outlined,
            row.sendEnabled
                ? AppStrings.modbus.cancelPeriodicSend
                : AppStrings.modbus.setPeriodicSend,
            'send',
          ),
        if (page.area.isWritable)
          ModbusPaintedMenuItem(
            Icons.edit,
            AppStrings.modbus.editValueAndSendOnce,
            'once',
          ),
        ModbusPaintedMenuItem(
          Icons.numbers,
          AppStrings.modbus.toggleRadixDisplay,
          'radix',
        ),
        ModbusPaintedMenuItem(Icons.notes, AppStrings.modbus.editNote, 'note'),
        ModbusPaintedMenuItem(
          Icons.palette_outlined,
          AppStrings.modbus.changeBackgroundColor,
          'color',
        ),
        if (!page.area.isBitArea)
          ModbusPaintedMenuItem(
            Icons.category_outlined,
            AppStrings.modbus.changeVariableType,
            'type',
          ),
        ModbusPaintedMenuItem(
          Icons.delete_outline,
          AppStrings.modbus.deleteRegisterRow,
          'delete',
        ),
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
                title: Text(AppStrings.modbus.editNote),
                content: TextField(controller: controller, autofocus: true),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(AppStrings.common.cancel),
                  ),
                  ElevatedButton(
                    onPressed:
                        () => Navigator.pop(dialogContext, controller.text),
                    child: Text(AppStrings.common.confirm),
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
                title: Text(AppStrings.modbus.changeBackgroundColor),
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
                        tooltip: AppStrings.modbus.selectColor,
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
                title: Text(AppStrings.modbus.changeVariableType),
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
            title: Text(
              AppStrings.modbus.oneShotSendTitle(
                row.address,
                row.variableType.label,
              ),
            ),
            content: AppDialogTextField(
              controller: controller,
              labelText: AppStrings.modbus.valueLabel,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: Text(AppStrings.modbus.send),
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
                  title: Text(AppStrings.modbus.addRegisterTitle),
                  content: SizedBox(
                    width: 380,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppDialogTextField(
                          controller: addressController,
                          keyboardType: TextInputType.number,
                          labelText: AppStrings.modbus.startAddress,
                        ),
                        const SizedBox(height: 12),
                        AppDialogTextField(
                          controller: countController,
                          keyboardType: TextInputType.number,
                          labelText: AppStrings.modbus.addCount,
                        ),
                        if (!page.area.isBitArea) ...[
                          const SizedBox(height: 12),
                          AppDialogDropdown<ModbusVariableType>(
                            value: type,
                            labelText: AppStrings.modbus.variableType,
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
                      child: Text(AppStrings.common.cancel),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      label: AppStrings.modbus.add,
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
      title: AppStrings.modbus.registerPage,
      items: [
        ModbusPaintedMenuItem(
          Icons.add,
          AppStrings.modbus.addSingleRegister,
          'add',
        ),
      ],
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
                          label:
                              page.enabled && _sessionActive
                                  ? AppStrings.modbus.stop
                                  : AppStrings.modbus.start,
                          tooltip:
                              page.enabled && _sessionActive
                                  ? AppStrings.modbus.stopPagePollingAndSending
                                  : _sessionActive &&
                                      page.rows.any((row) => row.pollEnabled)
                                  ? AppStrings.modbus.startPagePollingAndSending
                                  : AppStrings.modbus.startModbusFirst,
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
                          tooltip: AppStrings.modbus.batchAddRegisters,
                          onPressed: () => _showAddRows(page),
                        ),
                        ToolbarToggleIconButton(
                          icon: const Icon(Icons.category_outlined),
                          tooltip:
                              page.showVariableType
                                  ? AppStrings.modbus.hideVariableType
                                  : AppStrings.modbus.showVariableType,
                          selected: page.showVariableType,
                          onPressed:
                              () => _command('setPageVariableTypeVisible', {
                                'visible': !page.showVariableType,
                              }),
                        ),
                        const Spacer(),
                        Text(
                          _sessionActive
                              ? AppStrings.status.connected
                              : AppStrings.status.disconnected,
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
                          tooltip: AppStrings.modbus.closeDetachedWindow,
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
