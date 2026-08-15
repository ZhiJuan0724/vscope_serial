import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/data_connection_config.dart';
import '../../data/models/modbus_models.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/data_connection_service.dart';
import '../../services/modbus_client_service.dart';
import '../../services/modbus_window_manager.dart';
import '../widgets/common_widgets.dart';
import '../widgets/modbus_register_grid.dart';
import 'plot_page.dart' show showPlotCustomColorPicker;

class ModbusPage extends StatefulWidget {
  const ModbusPage({super.key});

  @override
  State<ModbusPage> createState() => _ModbusPageState();
}

class _ModbusMenuAction {
  const _ModbusMenuAction(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _ModbusContextMenu extends StatelessWidget {
  const _ModbusContextMenu({
    required this.title,
    required this.actions,
    required this.onClose,
  });

  final String title;
  final List<_ModbusMenuAction> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: 6,
    borderRadius: BorderRadius.circular(6),
    clipBehavior: Clip.antiAlias,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final action in actions)
            InkWell(
              onTap: () {
                onClose();
                action.onTap();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(action.icon, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(action.label)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ModbusPageState extends State<ModbusPage> {
  /// 与绘图工具栏保持相同的下拉框视觉基线。
  static const double _toolbarDropdownOffsetY = 2;

  final _unitController = TextEditingController(text: '1');
  final _addressController = TextEditingController(text: '0');
  final _quantityController = TextEditingController(text: '1');
  final _valuesController = TextEditingController();
  ModbusFunction _function = ModbusFunction.readHoldingRegisters;
  String? _selectedPageKey;
  bool _showManual = true;
  bool _showPolling = true;
  bool _showLogs = true;
  bool _manualSending = false;
  double _logHeight = 180;
  OverlayEntry? _contextMenuEntry;

  @override
  void dispose() {
    _hideContextMenu();
    _unitController.dispose();
    _addressController.dispose();
    _quantityController.dispose();
    _valuesController.dispose();
    super.dispose();
  }

  ModbusRegisterPage? _selectedPage(ModbusClientService service) {
    final key = _selectedPageKey;
    if (key != null) {
      for (final page in service.pages) {
        if (page.key == key &&
            !context.read<ModbusWindowManager>().isDetached(page.key)) {
          return page;
        }
      }
    }
    final manager = context.read<ModbusWindowManager>();
    return service.pages
        .where((page) => !manager.isDetached(page.key))
        .firstOrNull;
  }

  String _multiRegisterOrderPreview(
    ModbusByteOrder byteOrder,
    ModbusWordOrder wordOrder,
  ) {
    if (wordOrder == ModbusWordOrder.highWordFirst) {
      return byteOrder == ModbusByteOrder.highByteFirst ? 'ABCD' : 'BADC';
    }
    return byteOrder == ModbusByteOrder.highByteFirst ? 'CDAB' : 'DCBA';
  }

  Future<void> _detachPage(String pageKey) async {
    await context.read<ModbusWindowManager>().detachPage(pageKey);
    if (mounted) setState(() {});
  }

  Future<void> _changeMode(ModbusMode mode) async {
    if (mode == ModbusMode.tcp && !AppSettings().networkConnectionsEnabled) {
      AppNotifications.show('请先在高级设置中启用网络连接');
      return;
    }
    final connection = context.read<DataConnectionService>();
    if (connection.isConnected || connection.isConnecting) {
      AppNotifications.show('请先断开数据连接再切换Modbus协议');
      return;
    }
    try {
      await context.read<ModbusClientService>().setMode(mode);
      final settings =
          AppSettings()
            ..modbusMode = mode.value
            ..saveConnectionTypeForPage(
              'modbus',
              mode == ModbusMode.tcp
                  ? DataConnectionType.tcpClient
                  : DataConnectionType.serial,
            );
      await settings.save();
    } catch (error) {
      AppNotifications.show('切换Modbus协议失败：$error');
    }
  }

  ModbusRequest _buildRequest(ModbusMode mode) {
    final unit = _parseInt(_unitController.text);
    final address = _parseInt(_addressController.text);
    final quantity = _parseInt(_quantityController.text);
    if (unit == null || address == null || quantity == null) {
      throw const FormatException('单元号、地址和数量必须是整数');
    }
    final valuesInput =
        _valuesController.text
            .split(RegExp(r'[,\s]+'))
            .where((value) => value.isNotEmpty)
            .toList();
    final invalidValues = <String>[];
    final values = <int>[];
    for (final value in valuesInput) {
      final parsed = _parseInt(value);
      if (parsed == null) {
        invalidValues.add(value);
      } else {
        values.add(parsed);
      }
    }
    if (invalidValues.isNotEmpty) {
      throw FormatException('写入值无法解析：${invalidValues.join('、')}');
    }
    return ModbusRequest(
      mode: mode,
      unitId: unit,
      function: _function,
      address: address,
      quantity: quantity,
      registerValues: _function.isBitFunction ? const [] : values,
      coilValues:
          _function.isBitFunction
              ? [for (final value in values) value != 0]
              : const [],
    );
  }

  int? _parseInt(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final negative = text.startsWith('-');
    final unsigned = negative ? text.substring(1) : text;
    final parsed =
        unsigned.toLowerCase().startsWith('0x')
            ? int.tryParse(unsigned.substring(2), radix: 16)
            : int.tryParse(unsigned);
    return parsed == null ? null : (negative ? -parsed : parsed);
  }

  Future<void> _sendManual() async {
    if (_manualSending) return;
    setState(() => _manualSending = true);
    try {
      final service = context.read<ModbusClientService>();
      final response = await service.execute(_buildRequest(service.mode));
      if (response.isException) {
        AppNotifications.show(
          '从站返回异常码 0x${response.exceptionCode!.toRadixString(16).padLeft(2, '0')}',
        );
      }
    } catch (error) {
      AppNotifications.show('Modbus请求失败：$error');
    } finally {
      if (mounted) setState(() => _manualSending = false);
    }
  }

  Future<void> _toggleSession() async {
    final service = context.read<ModbusClientService>();
    try {
      if (service.sessionActive) {
        await service.stop();
      } else {
        await service.startSession();
      }
    } catch (error) {
      AppNotifications.show('Modbus操作失败：$error');
    }
  }

  Future<void> _showProtocolSettings() async {
    final service = context.read<ModbusClientService>();
    final timeoutController = TextEditingController(
      text: '${service.timeoutMs}',
    );
    final logMaxLinesController = TextEditingController(
      text: '${service.logMaxLines}',
    );
    final scrollController = ScrollController();
    final protocolSectionKey = GlobalKey();
    final registerSectionKey = GlobalKey();
    final loggingSectionKey = GlobalKey();
    var layoutMode = service.layoutMode;
    var byteOrder = service.byteOrder;
    var wordOrder = service.wordOrder;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AppSettingsDialog(
                  title: const Text('Modbus高级设置'),
                  size: AppDialogSize.navigation,
                  hasUnsavedChanges:
                      () =>
                          timeoutController.text.trim() !=
                              '${service.timeoutMs}' ||
                          logMaxLinesController.text.trim() !=
                              '${service.logMaxLines}' ||
                          layoutMode != service.layoutMode ||
                          byteOrder != service.byteOrder ||
                          wordOrder != service.wordOrder,
                  onSave: () async {
                    final timeout = int.tryParse(timeoutController.text.trim());
                    if (timeout == null || timeout < 100 || timeout > 60000) {
                      throw const FormatException('响应超时必须在100～60000 ms之间');
                    }
                    final logMaxLines = int.tryParse(
                      logMaxLinesController.text.trim(),
                    );
                    if (logMaxLines == null ||
                        logMaxLines < modbusMinLogMaxLines ||
                        logMaxLines > modbusMaxLogMaxLines) {
                      throw const FormatException('日志上限必须在100～100000行之间');
                    }
                    service
                      ..setTimeoutMs(timeout)
                      ..setLayoutMode(layoutMode)
                      ..setByteOrder(byteOrder)
                      ..setWordOrder(wordOrder)
                      ..setLogMaxLines(logMaxLines);
                  },
                  child: SettingsNavigationView(
                    scrollController: scrollController,
                    items: [
                      SettingsNavigationItem(
                        label: '协议',
                        anchorKey: protocolSectionKey,
                      ),
                      SettingsNavigationItem(
                        label: '寄存器',
                        anchorKey: registerSectionKey,
                      ),
                      SettingsNavigationItem(
                        label: '日志',
                        anchorKey: loggingSectionKey,
                      ),
                    ],
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(key: protocolSectionKey),
                        AppDialogTextField(
                          controller: timeoutController,
                          keyboardType: TextInputType.number,
                          labelText: '响应超时（100～60000 ms）',
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        Divider(key: registerSectionKey, height: 32),
                        AppDialogDropdown<ModbusRegisterLayoutMode>(
                          value: layoutMode,
                          labelText: '寄存器排列',
                          items: [
                            for (final mode in ModbusRegisterLayoutMode.values)
                              DropdownMenuItem(
                                value: mode,
                                child: Text(mode.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => layoutMode = value);
                            }
                          },
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '多寄存器数据排列（全局）',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        AppDialogDropdown<ModbusByteOrder>(
                          value: byteOrder,
                          labelText: '字节序',
                          items: [
                            for (final order in ModbusByteOrder.values)
                              DropdownMenuItem(
                                value: order,
                                child: Text(order.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => byteOrder = value);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        AppDialogDropdown<ModbusWordOrder>(
                          value: wordOrder,
                          labelText: '字序',
                          items: [
                            for (final order in ModbusWordOrder.values)
                              DropdownMenuItem(
                                value: order,
                                child: Text(order.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => wordOrder = value);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '当前排列：${_multiRegisterOrderPreview(byteOrder, wordOrder)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Divider(key: loggingSectionKey, height: 32),
                        AppDialogTextField(
                          controller: logMaxLinesController,
                          keyboardType: TextInputType.number,
                          labelText:
                              '日志上限（$modbusMinLogMaxLines～$modbusMaxLogMaxLines 行）',
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );
    disposeAfterDialogTransition(() {
      timeoutController.dispose();
      logMaxLinesController.dispose();
      scrollController.dispose();
    });
  }

  Future<void> _showAddPage() async {
    final unitController = TextEditingController(text: '1');
    var area = ModbusRegisterArea.holdingRegisters;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: const Text('添加寄存器页面'),
                  content: SizedBox(
                    width: 360,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppDialogTextField(
                          controller: unitController,
                          keyboardType: TextInputType.number,
                          labelText: '从机 ID（0～255）',
                        ),
                        const SizedBox(height: 12),
                        AppDialogDropdown<ModbusRegisterArea>(
                          value: area,
                          labelText: '寄存器区',
                          items: [
                            for (final item in ModbusRegisterArea.values)
                              DropdownMenuItem(
                                value: item,
                                child: Text(item.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => area = value);
                            }
                          },
                        ),
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
    if (confirmed == true && mounted) {
      final unit = _parseInt(unitController.text);
      if (unit == null || unit < 0 || unit > 255) {
        AppNotifications.show('从机 ID 无效');
      } else {
        final page = ModbusRegisterPage(unitId: unit, area: area);
        if (!context.read<ModbusClientService>().addPage(page)) {
          AppNotifications.show('相同从机 ID 和寄存器区的页面已存在');
        } else {
          setState(() => _selectedPageKey = page.key);
        }
      }
    }
    unitController.dispose();
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
    if (confirmed == true && mounted) {
      final start = _parseInt(addressController.text);
      final count = _parseInt(countController.text);
      if (start == null ||
          count == null ||
          start < 0 ||
          count < 1 ||
          count > 1000 ||
          start + count - 1 > 0xFFFF) {
        AppNotifications.show('地址或添加数量无效');
      } else {
        final service = context.read<ModbusClientService>();
        final existing = page.rows.map((row) => row.address).toSet();
        final overlap = <int>[];
        for (var index = 0; index < count; index++) {
          final address = start + index;
          if (existing.contains(address)) overlap.add(address);
          service.addRow(
            page.key,
            ModbusRegisterRow(
              id: '${DateTime.now().microsecondsSinceEpoch}-$index',
              address: address,
              variableType:
                  page.area.isBitArea ? ModbusVariableType.boolean : type,
            ),
          );
        }
        if (overlap.isNotEmpty) {
          AppNotifications.show('已添加，但地址 ${overlap.join(', ')} 存在重叠');
        }
      }
    }
    addressController.dispose();
    countController.dispose();
  }

  void _showRowMenu(
    BuildContext context,
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    Offset position,
  ) {
    final service = context.read<ModbusClientService>();
    _showContextMenu(position, '${row.address}[${row.variableType.label}]', [
      if (page.area.isWritable)
        _ModbusMenuAction(
          Icons.send_outlined,
          '快速发送',
          () => _showOneShotSend(page, row),
        ),
      _ModbusMenuAction(
        Icons.settings_outlined,
        '配置寄存器',
        () => _showRowEditor(page, row),
      ),
      _ModbusMenuAction(
        Icons.numbers,
        row.displayRadix == ModbusDisplayRadix.decimal
            ? '切换为十六进制显示'
            : '切换为十进制显示',
        () => service.updateRow(
          page.key,
          row.copyWith(
            displayRadix:
                row.displayRadix == ModbusDisplayRadix.decimal
                    ? ModbusDisplayRadix.hexadecimal
                    : ModbusDisplayRadix.decimal,
          ),
        ),
      ),
      _ModbusMenuAction(
        Icons.delete_outline,
        '删除寄存器',
        () => unawaited(_confirmDeleteRow(page, row)),
      ),
    ]);
  }

  void _showContextMenu(
    Offset position,
    String title,
    List<_ModbusMenuAction> actions,
  ) {
    _hideContextMenu();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final size = MediaQuery.sizeOf(context);
    const width = 210.0;
    final height = 34.0 + actions.length * 38.0;
    final left =
        position.dx
            .clamp(8.0, (size.width - width - 8).clamp(8, double.infinity))
            .toDouble();
    final top =
        position.dy
            .clamp(8.0, (size.height - height - 8).clamp(8, double.infinity))
            .toDouble();
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    _contextMenuEntry = OverlayEntry(
      builder:
          (overlayContext) => themes.wrap(
            Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _hideContextMenu,
                  ),
                ),
                Positioned(
                  left: left,
                  top: top,
                  width: width,
                  child: _ModbusContextMenu(
                    title: title,
                    actions: actions,
                    onClose: _hideContextMenu,
                  ),
                ),
              ],
            ),
          ),
    );
    overlay.insert(_contextMenuEntry!);
  }

  void _hideContextMenu() {
    final entry = _contextMenuEntry;
    _contextMenuEntry = null;
    entry?.remove();
    entry?.dispose();
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
            shape: kAdvancedSettingsDialogShape,
            title: Text('${row.address}[${row.variableType.label}] 一次性发送'),
            content: AppDialogTextField(
              controller: controller,
              labelText: '值（十进制或0x十六进制）',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                label: '发送',
              ),
            ],
          ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    try {
      await context.read<ModbusClientService>().sendRowOnce(
        page.key,
        row.id,
        value,
      );
    } catch (error) {
      AppNotifications.show('一次性发送失败：$error');
    }
  }

  Future<void> _showRowEditor(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
  ) async {
    final intervalController = TextEditingController(
      text: '${row.sendIntervalMs}',
    );
    final valueController = TextEditingController(text: row.sendValue);
    final stepController = TextEditingController(text: row.sendStep);
    final pollController = TextEditingController(text: '${row.pollIntervalMs}');
    final retriesController = TextEditingController(text: '${row.readRetries}');
    final noteController = TextEditingController(text: row.note);
    var mode = row.sendMode;
    var variableType = row.variableType;
    var pollEnabled = row.pollEnabled;
    var sendEnabled = row.sendEnabled;
    var backgroundArgb = row.backgroundArgb;
    final scrollController = ScrollController();
    final generalKey = GlobalKey();
    final pollingKey = GlobalKey();
    final appearanceKey = GlobalKey();
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: Text('${row.address}[${row.variableType.label}] 行配置'),
                  content: SettingsNavigationView(
                    scrollController: scrollController,
                    items: [
                      SettingsNavigationItem(
                        label: '基本信息',
                        anchorKey: generalKey,
                      ),
                      SettingsNavigationItem(
                        label: '轮询与发送',
                        anchorKey: pollingKey,
                      ),
                      SettingsNavigationItem(
                        label: '外观',
                        anchorKey: appearanceKey,
                      ),
                    ],
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _settingsSectionTitle(generalKey, '基本信息'),
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
                        const SizedBox(height: 18),
                        _settingsSectionTitle(pollingKey, '轮询与发送'),
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
                            const SizedBox(height: 10),
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
                              controller: intervalController,
                              keyboardType: TextInputType.number,
                              labelText:
                                  '发送周期（$modbusMinIntervalMs～$modbusMaxIntervalMs ms）',
                            ),
                          ],
                        ],
                        const SizedBox(height: 18),
                        _settingsSectionTitle(appearanceKey, '外观'),
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
                              Color(0xFFFFE0E0),
                            ],
                            onChanged:
                                (color) => setDialogState(
                                  () => backgroundArgb = color?.toARGB32(),
                                ),
                            onCustomColor:
                                (initial) =>
                                    showPlotCustomColorPicker(context, initial),
                          ),
                        ),
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
                      label: '保存',
                    ),
                  ],
                ),
          ),
    );
    if (result == true && mounted) {
      final poll = _parseInt(pollController.text);
      final retries = _parseInt(retriesController.text);
      final sendInterval = _parseInt(intervalController.text);
      if (poll == null ||
          poll < modbusMinIntervalMs ||
          poll > modbusMaxIntervalMs ||
          retries == null ||
          retries < 0 ||
          retries > 3 ||
          (page.area.isWritable &&
              (sendInterval == null ||
                  sendInterval < modbusMinIntervalMs ||
                  sendInterval > modbusMaxIntervalMs))) {
        AppNotifications.show('周期或重试参数无效');
      } else {
        context.read<ModbusClientService>().updateRow(
          page.key,
          row.copyWith(
            variableType: variableType,
            pollEnabled: pollEnabled,
            pollIntervalMs: poll,
            readRetries: retries,
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
          ),
        );
      }
    }
    for (final controller in [
      intervalController,
      valueController,
      stepController,
      pollController,
      retriesController,
      noteController,
    ]) {
      controller.dispose();
    }
    scrollController.dispose();
  }

  Widget _settingsSectionTitle(Key key, String title) => Align(
    key: key,
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
  );

  Future<void> _exportConfiguration({
    String? profileId,
    String? profileName,
  }) async {
    final service = context.read<ModbusClientService>();
    final id = profileId ?? service.selectedProfile?.id;
    final name = profileName ?? service.selectedProfile?.name;
    if (id == null || name == null) return;
    final fileName = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final path = await file_picker.FilePicker.saveFile(
      dialogTitle: '导出 Modbus 配置',
      fileName: '$fileName.json',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null || !mounted) return;
    await service.exportProfile(
      id,
      path.toLowerCase().endsWith('.json') ? path : '$path.json',
    );
    AppNotifications.show('已导出配置“$name”');
  }

  Future<void> _importConfiguration() async {
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: '导入 Modbus 配置',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final service = context.read<ModbusClientService>();
      await service.importProfile(path);
      AppNotifications.show('已导入并切换Modbus配置');
    } catch (error) {
      AppNotifications.show('导入Modbus配置失败：$error');
    }
  }

  Future<String?> _promptProfileName({
    String? initial,
    required String title,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final name = await showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(title),
            content: AppDialogTextField(
              controller: controller,
              autofocus: true,
              labelText: '配置名称',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                label: '确定',
              ),
            ],
          ),
    );
    disposeAfterDialogTransition(controller.dispose);
    return name;
  }

  Future<void> _createProfile() async {
    final name = await _promptProfileName(title: '新建Modbus配置');
    if (name == null || !mounted) return;
    await context.read<ModbusClientService>().createProfile(name);
  }

  Future<void> _renameProfile(String id, String currentName) async {
    final service = context.read<ModbusClientService>();
    final name = await _promptProfileName(
      title: '重命名Modbus配置',
      initial: currentName,
    );
    if (name == null || !mounted) return;
    await service.renameProfile(id, name);
  }

  Future<void> _deleteProfile(String id, String name) async {
    final service = context.read<ModbusClientService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: const Text('删除Modbus配置'),
            content: Text('确定删除“$name”吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                label: '删除',
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) await service.deleteProfile(id);
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

  Future<void> _confirmDeleteRow(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
  ) async {
    final confirmed = await _confirm(
      '删除寄存器',
      '确定删除地址 ${row.address} 的寄存器吗？其变量类型、备注、背景色和轮询配置将一并删除。',
    );
    if (!confirmed || !mounted) return;
    context.read<ModbusClientService>().removeRow(page.key, row.id);
  }

  Future<void> _confirmClosePage(ModbusRegisterPage page) async {
    final confirmed = await _confirm(
      '关闭页面',
      '确定关闭该寄存器页面吗？',
      confirmLabel: '关闭',
    );
    if (!confirmed || !mounted) return;
    context.read<ModbusClientService>().removePage(page.key);
    setState(() => _selectedPageKey = null);
  }

  Future<void> _showProfileManager() async {
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => Consumer<ModbusClientService>(
            builder:
                (context, service, _) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: const Text('Modbus配置管理'),
                  content: SizedBox(
                    width: 560,
                    height: 380,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 40,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '本地目录：config/modbus',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              ToolbarIconButton(
                                icon: const Icon(Icons.add),
                                tooltip: '新建配置',
                                onPressed: _createProfile,
                              ),
                              ToolbarIconButton(
                                icon: const Icon(Icons.file_upload_outlined),
                                tooltip: '导入配置',
                                onPressed: _importConfiguration,
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: service.profiles.length,
                            separatorBuilder:
                                (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final profile = service.profiles[index];
                              final selected =
                                  profile.id == service.selectedProfile?.id;
                              return InkWell(
                                onTap:
                                    selected
                                        ? null
                                        : () =>
                                            service.selectProfile(profile.id),
                                child: SizedBox(
                                  height: 44,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 32,
                                        child:
                                            selected
                                                ? Icon(
                                                  Icons.check,
                                                  size: 18,
                                                  color:
                                                      Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                                )
                                                : null,
                                      ),
                                      Expanded(
                                        child: Text(
                                          profile.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ToolbarIconButton(
                                        icon: const Icon(Icons.edit_outlined),
                                        tooltip: '重命名配置',
                                        onPressed:
                                            () => _renameProfile(
                                              profile.id,
                                              profile.name,
                                            ),
                                      ),
                                      ToolbarIconButton(
                                        icon: const Icon(
                                          Icons.file_download_outlined,
                                        ),
                                        tooltip: '导出配置',
                                        onPressed:
                                            () => _exportConfiguration(
                                              profileId: profile.id,
                                              profileName: profile.name,
                                            ),
                                      ),
                                      ToolbarIconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        tooltip: '删除配置',
                                        onPressed:
                                            () => _deleteProfile(
                                              profile.id,
                                              profile.name,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      label: '关闭',
                    ),
                  ],
                ),
          ),
    );
  }

  Widget _buildToolbar(
    ModbusClientService service,
    DataConnectionService connection,
  ) => UnifiedToolbar(
    leadingItems: [
      ToolbarLayoutItem(
        extent: 76,
        child: ToolbarStartStopButton(
          running: service.sessionActive,
          label: service.sessionActive ? '停止' : '开始',
          tooltip: service.sessionActive ? '停止Modbus数据处理' : '开始Modbus数据处理',
          onPressed: connection.isConnected ? _toggleSession : null,
        ),
      ),
      ToolbarLayoutItem(
        extent: 110,
        child: ToolbarDropdown<ModbusMode>(
          width: 110,
          visibleFieldOffsetY: _toolbarDropdownOffsetY,
          value: service.mode,
          hint: '协议',
          items: [
            for (final mode in ModbusMode.values)
              DropdownMenuItem(value: mode, child: Text(mode.label)),
          ],
          onChanged:
              service.sessionActive
                  ? null
                  : (value) {
                    if (value != null) _changeMode(value);
                  },
        ),
      ),
      ToolbarLayoutItem(
        extent: 160,
        child: ToolbarDropdown<String>(
          key: const ValueKey('modbus-profile-selector'),
          width: 160,
          visibleFieldOffsetY: _toolbarDropdownOffsetY,
          value: service.selectedProfile?.id,
          hint: service.profilesInitialized ? '默认配置' : '加载配置…',
          items: [
            for (final profile in service.profiles)
              DropdownMenuItem(
                value: profile.id,
                child: Text(
                  profile.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          onChanged:
              !service.sessionActive && service.profilesInitialized
                  ? (value) {
                    if (value != null) service.selectProfile(value);
                  }
                  : null,
        ),
      ),
      ToolbarLayoutItem(
        extent: kToolbarControlExtent,
        child: ToolbarIconButton(
          key: const ValueKey('modbus-profile-manager-button'),
          icon: const Icon(Icons.edit_note),
          tooltip: '编辑Modbus配置',
          onPressed:
              service.sessionActive || !service.profilesInitialized
                  ? null
                  : _showProfileManager,
        ),
        overflowActions: [
          ToolbarOverflowAction(
            icon: const Icon(Icons.edit_note),
            label: '编辑Modbus配置',
            onPressed:
                service.sessionActive || !service.profilesInitialized
                    ? null
                    : _showProfileManager,
          ),
        ],
      ),
      ToolbarLayoutItem(
        extent: kToolbarControlExtent,
        child: ToolbarToggleIconButton(
          icon: const Icon(Icons.send_outlined),
          tooltip: '显示/隐藏手动发送',
          selected: _showManual,
          onPressed: () => setState(() => _showManual = !_showManual),
        ),
        overflowActions: [
          ToolbarOverflowAction(
            icon: const Icon(Icons.send_outlined),
            label: '显示手动发送',
            selected: _showManual,
            onPressed: () => setState(() => _showManual = !_showManual),
          ),
        ],
      ),
      ToolbarLayoutItem(
        extent: kToolbarControlExtent,
        child: ToolbarToggleIconButton(
          icon: const Icon(Icons.grid_view),
          tooltip: '显示/隐藏轮询页面',
          selected: _showPolling,
          onPressed: () => setState(() => _showPolling = !_showPolling),
        ),
        overflowActions: [
          ToolbarOverflowAction(
            icon: const Icon(Icons.grid_view),
            label: '显示轮询页面',
            selected: _showPolling,
            onPressed: () => setState(() => _showPolling = !_showPolling),
          ),
        ],
      ),
      ToolbarLayoutItem(
        extent: kToolbarControlExtent,
        child: ToolbarToggleIconButton(
          icon: const Icon(Icons.notes_outlined),
          tooltip: '显示/隐藏日志',
          selected: _showLogs,
          onPressed: () => setState(() => _showLogs = !_showLogs),
        ),
        overflowActions: [
          ToolbarOverflowAction(
            icon: const Icon(Icons.notes_outlined),
            label: '显示日志',
            selected: _showLogs,
            onPressed: () => setState(() => _showLogs = !_showLogs),
          ),
        ],
      ),
    ],
    trailingItems: [
      ToolbarLayoutItem(
        extent: kToolbarControlExtent,
        child: ToolbarAdvancedSettingsButton(
          tooltip: 'Modbus高级设置',
          onPressed: service.sessionActive ? null : _showProtocolSettings,
        ),
        overflowActions: [
          ToolbarOverflowAction(
            icon: const Icon(Icons.tune),
            label: 'Modbus高级设置',
            onPressed: service.sessionActive ? null : _showProtocolSettings,
          ),
        ],
      ),
    ],
  );

  Widget _buildManualPanel(ModbusClientService service) {
    final reference = _parseInt(_addressController.text) ?? 0;
    final response = service.lastResponse;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          '手动发送',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _numberField(_unitController, '从机 ID')),
            const SizedBox(width: 8),
            Expanded(
              child: _numberField(
                _addressController,
                'PDU地址（0基）',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        Text(
          '参考号：${modbusReferenceNumber(_function, reference.clamp(0, 65535))}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        AppDialogDropdown<ModbusFunction>(
          value: _function,
          hint: '选择功能码',
          labelText: '功能码',
          items: [
            for (final item in ModbusFunction.values)
              DropdownMenuItem(
                value: item,
                child: Text(
                  '0x${item.code.toRadixString(16).toUpperCase().padLeft(2, '0')} ${item.label}',
                ),
              ),
          ],
          onChanged: (value) => setState(() => _function = value ?? _function),
        ),
        const SizedBox(height: 8),
        _numberField(_quantityController, '数量'),
        const SizedBox(height: 8),
        AppDialogTextField(
          controller: _valuesController,
          labelText: '写入值（逗号或空格分隔）',
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed:
              service.sessionActive && !_manualSending ? _sendManual : null,
          icon: const Icon(Icons.send),
          label: const Text('发送一次'),
        ),
        const SizedBox(height: 18),
        const Text('最近响应', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SelectableText(_responseText(response)),
        if (service.lastError != null) ...[
          const SizedBox(height: 8),
          Text(
            '${service.lastError}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  String _responseText(ModbusResponse? response) {
    if (response == null) return '暂无响应';
    if (response.isException) {
      return '异常码：0x${response.exceptionCode!.toRadixString(16).padLeft(2, '0')}';
    }
    if (response.registerValues.isNotEmpty) {
      return response.registerValues
          .map(
            (value) => '$value / 0x${value.toRadixString(16).padLeft(4, '0')}',
          )
          .join('\n');
    }
    return response.coilValues
        .asMap()
        .entries
        .map((entry) => '${entry.key}: ${entry.value ? 1 : 0}')
        .join('\n');
  }

  Widget _buildPollingPanel(ModbusClientService service) {
    final page = _selectedPage(service);
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 14),
                child: Text('寄存器页面'),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  scrollDirection: Axis.horizontal,
                  itemCount:
                      service.pages
                          .where(
                            (item) =>
                                !context.read<ModbusWindowManager>().isDetached(
                                  item.key,
                                ),
                          )
                          .length,
                  separatorBuilder: (_, _) => const SizedBox(width: 3),
                  itemBuilder: (context, index) {
                    final item = service.pages
                        .where(
                          (item) =>
                              !context.read<ModbusWindowManager>().isDetached(
                                item.key,
                              ),
                        )
                        .elementAt(index);
                    return _pageTab(item, item.key == page?.key);
                  },
                ),
              ),
              ToolbarIconButton(
                icon: const Icon(Icons.add),
                tooltip: '添加页面',
                onPressed: _showAddPage,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        const Divider(height: 1),
        if (page == null)
          const Expanded(child: Center(child: Text('请添加一个寄存器页面')))
        else ...[
          _buildPageToolbar(service, page),
          const Divider(height: 1),
          Expanded(child: _buildRegisterGrid(service, page)),
        ],
      ],
    );
  }

  Widget _buildPageToolbar(
    ModbusClientService service,
    ModbusRegisterPage page,
  ) {
    final canStartPolling =
        service.sessionActive && page.rows.any((row) => row.pollEnabled);
    final pollingRunning = page.enabled && service.sessionActive;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 8),
          ToolbarStartStopButton(
            running: pollingRunning,
            label: pollingRunning ? '停止' : '开始',
            tooltip:
                pollingRunning
                    ? '停止此页面轮询和周期发送'
                    : canStartPolling
                    ? '开始此页面轮询和周期发送'
                    : '请先开始Modbus并至少开启一个寄存器轮询',
            onPressed:
                canStartPolling || pollingRunning
                    ? () => service.setPageEnabled(page.key, !page.enabled)
                    : null,
          ),
          ToolbarIconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: '批量添加寄存器',
            onPressed: () => _showAddRows(page),
          ),
          ToolbarToggleIconButton(
            icon: const Icon(Icons.category_outlined),
            tooltip: page.showVariableType ? '隐藏变量类型（u16）' : '显示变量类型（u16）',
            selected: page.showVariableType,
            onPressed:
                () => service.setPageVariableTypeVisible(
                  page.key,
                  !page.showVariableType,
                ),
          ),
          const Spacer(),
          ToolbarIconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: '在独立窗口打开页面',
            onPressed: () => _detachPage(page.key),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _pageTab(ModbusRegisterPage page, bool selected) {
    return GestureDetector(
      onLongPress:
          () => context.read<ModbusWindowManager>().detachPage(page.key),
      onSecondaryTapUp:
          (details) => _showPageTabMenu(page, details.globalPosition),
      child: InkWell(
        onTap: () => setState(() => _selectedPageKey = page.key),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 190),
          decoration: BoxDecoration(
            color:
                selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'U${page.unitId} · ${page.area.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '关闭页面',
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: () => unawaited(_confirmClosePage(page)),
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPageTabMenu(ModbusRegisterPage page, Offset position) {
    _showContextMenu(position, 'U${page.unitId} · ${page.area.label}', [
      _ModbusMenuAction(
        Icons.open_in_new,
        '在独立窗口打开',
        () => _detachPage(page.key),
      ),
      _ModbusMenuAction(
        Icons.close,
        '关闭页面',
        () => unawaited(_confirmClosePage(page)),
      ),
    ]);
  }

  Widget _buildRegisterGrid(
    ModbusClientService service,
    ModbusRegisterPage page,
  ) => ModbusRegisterGrid(
    page: page,
    layoutMode: service.layoutMode,
    rowState: (row) => service.rowState(page.key, row.id),
    onRowContextMenu:
        (row, position) => _showRowMenu(context, page, row, position),
    onBlankContextMenu: (position) => _showBlankGridMenu(page, position),
  );

  void _showBlankGridMenu(ModbusRegisterPage page, Offset position) {
    _showContextMenu(position, '寄存器页面', [
      _ModbusMenuAction(Icons.add, '添加单个寄存器', () => _showAddRows(page)),
      _ModbusMenuAction(
        Icons.playlist_play,
        '一键配置整页轮询',
        () => _showPagePollingEditor(page),
      ),
    ]);
  }

  Future<void> _showPagePollingEditor(ModbusRegisterPage page) async {
    final firstRow = page.rows.firstOrNull;
    final intervalController = TextEditingController(
      text: '${firstRow?.pollIntervalMs ?? modbusDefaultIntervalMs}',
    );
    final retriesController = TextEditingController(
      text: '${firstRow?.readRetries ?? 0}',
    );
    var enabled =
        page.rows.isNotEmpty && page.rows.every((row) => row.pollEnabled);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: const Text('批量配置寄存器轮询'),
                  content: SizedBox(
                    width: 360,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppSwitchRow(
                          title: const Text('启用这些寄存器的轮询功能'),
                          value: enabled,
                          onChanged:
                              (value) => setDialogState(() => enabled = value),
                        ),
                        AppDialogTextField(
                          controller: intervalController,
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
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      label: '应用到所有寄存器',
                    ),
                  ],
                ),
          ),
    );
    if (confirmed != true || !mounted) {
      intervalController.dispose();
      retriesController.dispose();
      return;
    }
    final interval = int.tryParse(intervalController.text.trim());
    final retries = int.tryParse(retriesController.text.trim());
    intervalController.dispose();
    retriesController.dispose();
    if (interval == null ||
        interval < modbusMinIntervalMs ||
        interval > modbusMaxIntervalMs ||
        retries == null ||
        retries < 0 ||
        retries > 3) {
      AppNotifications.show(
        '查询周期必须在$modbusMinIntervalMs～$modbusMaxIntervalMs ms之间，读取重试必须在0～3之间',
      );
      return;
    }
    final service = context.read<ModbusClientService>();
    for (final row in page.rows) {
      service.updateRow(
        page.key,
        row.copyWith(
          pollEnabled: enabled,
          pollIntervalMs: interval,
          readRetries: retries,
        ),
      );
    }
  }

  Widget _buildLogs(ModbusClientService service) {
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 14),
                child: Text('Modbus日志'),
              ),
              const Spacer(),
              ToolbarIconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清空Modbus日志',
                onPressed:
                    service.records.isEmpty ? null : service.clearRecords,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child:
                service.records.isEmpty
                    ? const Center(child: Text('暂无输出'))
                    : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      itemCount: service.records.length,
                      itemBuilder: (context, reverseIndex) {
                        final record =
                            service.records[service.records.length -
                                reverseIndex -
                                1];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                record.outbound
                                    ? Icons.north_east
                                    : Icons.south_west,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: SelectableText(
                                  '${_hex(record.frame)}  ${record.status}${record.elapsed == null ? '' : '  ${record.elapsed!.inMilliseconds} ms'}',
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontFamily: 'Consolas',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
          ),
        ),
      ],
    );
  }

  String _hex(Uint8List data) =>
      data
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase();

  Widget _numberField(
    TextEditingController controller,
    String label, {
    ValueChanged<String>? onChanged,
  }) => AppLabeledField(
    label: label,
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: secondaryDialogFieldDecoration(),
      onChanged: onChanged,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<DataConnectionService>();
    final service = context.watch<ModbusClientService>();
    context.watch<ModbusWindowManager>();
    final page = _selectedPage(service);
    return Column(
      children: [
        _buildToolbar(service, connection),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (_showManual)
                      SizedBox(width: 360, child: _buildManualPanel(service)),
                    if (_showManual && _showPolling)
                      const VerticalDivider(width: 1),
                    if (_showPolling)
                      Expanded(child: _buildPollingPanel(service)),
                    if (!_showManual && !_showPolling)
                      const Expanded(child: Center(child: Text('请从工具栏打开一个区域'))),
                  ],
                ),
              ),
              if (_showLogs) ...[
                MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragUpdate:
                        (details) => setState(
                          () =>
                              _logHeight = (_logHeight - details.delta.dy)
                                  .clamp(88, 360),
                        ),
                    child: SizedBox(
                      height: 8,
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
                SizedBox(height: _logHeight, child: _buildLogs(service)),
              ],
            ],
          ),
        ),
        if (page != null && !service.pages.any((item) => item.key == page.key))
          const SizedBox.shrink(),
      ],
    );
  }
}
