import 'dart:async';
import 'dart:io';
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
import '../widgets/common_widgets.dart';

class ModbusPage extends StatefulWidget {
  const ModbusPage({super.key});

  @override
  State<ModbusPage> createState() => _ModbusPageState();
}

class _ModbusPageState extends State<ModbusPage> {
  final _unitController = TextEditingController(text: '1');
  final _addressController = TextEditingController(text: '0');
  final _quantityController = TextEditingController(text: '1');
  final _valuesController = TextEditingController();
  ModbusFunction _function = ModbusFunction.readHoldingRegisters;

  @override
  void dispose() {
    _unitController.dispose();
    _addressController.dispose();
    _quantityController.dispose();
    _valuesController.dispose();
    super.dispose();
  }

  Future<void> _changeMode(ModbusMode mode) async {
    if (mode == ModbusMode.tcp && !AppSettings().networkConnectionsEnabled) {
      AppNotifications.show('请先在高级设置中启用网络连接');
      return;
    }
    final connection = context.read<DataConnectionService>();
    final service = context.read<ModbusClientService>();
    if (connection.isConnected || connection.isConnecting) {
      AppNotifications.show('请先断开数据连接再切换Modbus协议');
      return;
    }
    await service.setMode(mode);
    final settings = AppSettings();
    settings
      ..modbusMode = mode.value
      ..saveConnectionTypeForPage(
        'modbus',
        mode == ModbusMode.tcp
            ? DataConnectionType.tcpClient
            : DataConnectionType.serial,
      );
    await settings.save();
  }

  ModbusRequest _buildRequest(ModbusMode mode) {
    final unit = int.tryParse(_unitController.text.trim());
    final address = int.tryParse(_addressController.text.trim());
    final quantity = int.tryParse(_quantityController.text.trim());
    if (unit == null || address == null || quantity == null) {
      throw const FormatException('单元号、地址和数量必须是十进制整数');
    }
    final values =
        _valuesController.text
            .split(RegExp(r'[,\s]+'))
            .where((value) => value.isNotEmpty)
            .map((value) => int.parse(value))
            .toList();
    return ModbusRequest(
      mode: mode,
      unitId: unit,
      function: _function,
      address: address,
      quantity: quantity,
      registerValues:
          _function.isBitFunction ? const [] : List.unmodifiable(values),
      coilValues:
          _function.isBitFunction
              ? List.unmodifiable(values.map((value) => value != 0))
              : const [],
    );
  }

  Future<void> _sendManual() async {
    final service = context.read<ModbusClientService>();
    try {
      final response = await service.execute(_buildRequest(service.mode));
      if (response.isException) {
        AppNotifications.show(
          '从站返回异常码 0x${response.exceptionCode!.toRadixString(16).padLeft(2, '0')}',
        );
      }
    } catch (error) {
      AppNotifications.show('Modbus请求失败：$error');
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

  Future<void> _addPollingTask() async {
    final request = _buildRequest(context.read<ModbusClientService>().mode);
    if (!request.function.isRead) {
      AppNotifications.show('周期任务仅支持读取功能码');
      return;
    }
    final nameController = TextEditingController(
      text: '${request.function.label} ${request.address}',
    );
    final retriesController = TextEditingController(text: '0');
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: const Text('添加轮询任务'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: secondaryDialogFieldDecoration(
                      labelText: '任务名称',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: retriesController,
                    keyboardType: TextInputType.number,
                    decoration: secondaryDialogFieldDecoration(
                      labelText: '读取重试（0～3）',
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
                label: '添加',
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) {
      final service = context.read<ModbusClientService>();
      final retries = int.tryParse(retriesController.text) ?? 0;
      service.addTask(
        ModbusPollingTask(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name:
              nameController.text.trim().isEmpty
                  ? '轮询任务'
                  : nameController.text.trim(),
          unitId: request.unitId,
          function: request.function,
          address: request.address,
          quantity: request.quantity,
          intervalMs: service.pollingIntervalMs,
          readRetries: retries.clamp(0, 3),
        ),
      );
    }
    nameController.dispose();
    retriesController.dispose();
  }

  Future<void> _addSendTask() async {
    final request = _buildRequest(context.read<ModbusClientService>().mode);
    if (request.function.isRead) {
      AppNotifications.show('周期发送任务仅支持写功能码');
      return;
    }
    final count =
        request.function == ModbusFunction.writeSingleCoil ||
                request.function == ModbusFunction.writeSingleRegister
            ? 1
            : request.quantity;
    final initialValues =
        request.function.isBitFunction
            ? request.coilValues.map((value) => value ? 1 : 0).toList()
            : request.registerValues;
    final nameController = TextEditingController(
      text: '${request.function.label} ${request.address}',
    );
    final stepController = TextEditingController(text: '1');
    var valueMode = ModbusSendValueMode.random;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: const Text('添加周期发送任务'),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: nameController,
                          decoration: secondaryDialogFieldDecoration(
                            labelText: '任务名称',
                          ),
                        ),
                        const SizedBox(height: 12),
                        NoAnimDropdown<ModbusSendValueMode>(
                          value: valueMode,
                          hint: '选择数值生成方式',
                          decoration: secondaryDialogFieldDecoration(
                            labelText: '数值生成方式',
                          ),
                          items: [
                            for (final mode in ModbusSendValueMode.values)
                              DropdownMenuItem(
                                value: mode,
                                child: Text(mode.label),
                              ),
                          ],
                          onChanged:
                              (value) => setDialogState(
                                () => valueMode = value ?? valueMode,
                              ),
                        ),
                        if (valueMode != ModbusSendValueMode.random) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: stepController,
                            keyboardType: TextInputType.number,
                            decoration: secondaryDialogFieldDecoration(
                              labelText: '步长 N（1～65535）',
                            ),
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '从当前写入值开始，每次发送后按16位无符号数循环变化。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
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
      final service = context.read<ModbusClientService>();
      final step = int.tryParse(stepController.text.trim()) ?? 1;
      service.addSendTask(
        ModbusSendTask(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name:
              nameController.text.trim().isEmpty
                  ? '周期发送任务'
                  : nameController.text.trim(),
          unitId: request.unitId,
          function: request.function,
          address: request.address,
          quantity: count,
          valueMode: valueMode,
          initialValues: List<int>.generate(
            count,
            (index) => initialValues.elementAtOrNull(index) ?? 0,
          ),
          step: step.clamp(1, 0xFFFF),
          intervalMs: service.sendingIntervalMs,
        ),
      );
    }
    nameController.dispose();
    stepController.dispose();
  }

  Future<void> _configurePeriodicInterval({required bool polling}) async {
    final service = context.read<ModbusClientService>();
    final controller = TextEditingController(
      text:
          polling
              ? '${service.pollingIntervalMs}'
              : '${service.sendingIntervalMs}',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(polling ? '轮询周期设置' : '发送周期设置'),
            content: SizedBox(
              width: 360,
              child: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: secondaryDialogFieldDecoration(
                  labelText: '周期（ms，50～3600000）',
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
                label: '确定',
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) {
      final value = int.tryParse(controller.text.trim());
      if (value == null || value < 50 || value > 3600000) {
        AppNotifications.show('周期必须在50～3600000 ms之间');
      } else if (polling) {
        service.setPollingIntervalMs(value);
      } else {
        service.setSendingIntervalMs(value);
      }
    }
    controller.dispose();
  }

  Future<void> _togglePolling() async {
    final service = context.read<ModbusClientService>();
    try {
      if (service.polling) {
        await service.stopPolling();
      } else {
        await service.startPolling();
      }
    } catch (error) {
      AppNotifications.show('轮询启动失败：$error');
    }
  }

  Future<void> _toggleSending() async {
    final service = context.read<ModbusClientService>();
    try {
      if (service.sending) {
        await service.stopSending();
      } else {
        await service.startSending();
      }
    } catch (error) {
      AppNotifications.show('周期发送启动失败：$error');
    }
  }

  Future<void> _showProtocolSettings() async {
    final service = context.read<ModbusClientService>();
    final controller = TextEditingController(text: '${service.timeoutMs}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: const Text('Modbus协议设置'),
            content: SizedBox(
              width: 360,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: secondaryDialogFieldDecoration(
                  labelText: '响应超时（ms）',
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
                label: '确定',
              ),
            ],
          ),
    );
    if (confirmed == true) {
      final value = int.tryParse(controller.text.trim());
      if (value == null || value < 100 || value > 60000) {
        AppNotifications.show('响应超时必须在100～60000 ms之间');
      } else {
        service.setTimeoutMs(value);
        AppSettings().modbusTimeoutMs = value;
        await AppSettings().save();
      }
    }
    controller.dispose();
  }

  Future<void> _exportTasks() async {
    final path = await file_picker.FilePicker.saveFile(
      dialogTitle: '导出Modbus轮询任务',
      fileName: 'modbus_tasks.json',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null || !mounted) return;
    await File(
      path,
    ).writeAsString(context.read<ModbusClientService>().exportTasks());
  }

  Future<void> _importTasks() async {
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: '导入Modbus轮询任务',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    final imported = context.read<ModbusClientService>().importTasks(
      await File(path).readAsString(),
    );
    AppNotifications.show(
      '已导入${imported.tasks.length}项轮询任务、${imported.sendTasks.length}项发送任务'
      '${imported.errors.isEmpty ? '' : '，${imported.errors.join('；')}'}',
    );
  }

  String _hex(Uint8List data) =>
      data
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase();

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<DataConnectionService>();
    final service = context.watch<ModbusClientService>();
    final response = service.lastResponse;
    final reference = int.tryParse(_addressController.text.trim()) ?? 0;
    return Column(
      children: [
        UnifiedToolbar(
          leadingItems: [
            ToolbarLayoutItem(
              extent: 76,
              child: ToolbarStartStopButton(
                running: service.sessionActive,
                label: service.sessionActive ? '停止' : '开始',
                tooltip:
                    service.sessionActive ? '停止Modbus数据处理' : '开始Modbus数据处理',
                onPressed: connection.isConnected ? _toggleSession : null,
              ),
            ),
            ToolbarLayoutItem(
              extent: 120,
              child: ToolbarDropdown<ModbusMode>(
                width: 120,
                value: service.mode,
                hint: 'Modbus协议',
                items: [
                  for (final mode in ModbusMode.values)
                    DropdownMenuItem(
                      value: mode,
                      enabled:
                          mode != ModbusMode.tcp ||
                          AppSettings().networkConnectionsEnabled,
                      child: Text(mode.label),
                    ),
                ],
                onChanged:
                    connection.isConnected
                        ? null
                        : (value) {
                          if (value != null) _changeMode(value);
                        },
              ),
            ),
          ],
          trailingItems: [
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                icon: const Icon(Icons.file_open),
                tooltip: '导入轮询任务',
                onPressed: _importTasks,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.file_open),
                  label: '导入轮询任务',
                  onPressed: _importTasks,
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: '导出周期任务',
                onPressed:
                    service.tasks.isEmpty && service.sendTasks.isEmpty
                        ? null
                        : _exportTasks,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.save_alt),
                  label: '导出周期任务',
                  onPressed:
                      service.tasks.isEmpty && service.sendTasks.isEmpty
                          ? null
                          : _exportTasks,
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清空帧记录',
                onPressed:
                    service.records.isEmpty ? null : service.clearRecords,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: '清空帧记录',
                  onPressed:
                      service.records.isEmpty ? null : service.clearRecords,
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarAdvancedSettingsButton(
                onPressed:
                    service.requestPending ? null : _showProtocolSettings,
                tooltip: 'Modbus协议设置',
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.tune),
                  label: 'Modbus协议设置',
                  onPressed:
                      service.requestPending ? null : _showProtocolSettings,
                ),
              ],
            ),
          ],
        ),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 430,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Text(
                      '手动请求',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _numberField(_unitController, '单元号')),
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
                    NoAnimDropdown<ModbusFunction>(
                      value: _function,
                      hint: '选择功能码',
                      decoration: secondaryDialogFieldDecoration(
                        labelText: '功能码',
                      ),
                      items: [
                        for (final item in ModbusFunction.values)
                          DropdownMenuItem(
                            value: item,
                            child: Text(
                              '0x${item.code.toRadixString(16).toUpperCase().padLeft(2, '0')} ${item.label}',
                            ),
                          ),
                      ],
                      onChanged:
                          (value) =>
                              setState(() => _function = value ?? _function),
                    ),
                    const SizedBox(height: 8),
                    _numberField(_quantityController, '数量'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _valuesController,
                      decoration: secondaryDialogFieldDecoration(
                        labelText: '写入值（逗号或空格分隔）',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        ElevatedButton.icon(
                          onPressed:
                              service.sessionActive && !service.requestPending
                                  ? _sendManual
                                  : null,
                          icon: const Icon(Icons.send),
                          label: const Text('发送'),
                        ),
                        if (_function.isRead)
                          OutlinedButton.icon(
                            onPressed: _addPollingTask,
                            icon: const Icon(Icons.add),
                            label: const Text('加入轮询'),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: _addSendTask,
                            icon: const Icon(Icons.add),
                            label: const Text('加入周期发送'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '当前结果',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      response == null
                          ? '暂无响应'
                          : response.isException
                          ? '异常码：0x${response.exceptionCode!.toRadixString(16).padLeft(2, '0')}'
                          : response.registerValues.isNotEmpty
                          ? response.registerValues
                              .map(
                                (value) =>
                                    '$value / 0x${value.toRadixString(16).padLeft(4, '0')}',
                              )
                              .join('\n')
                          : response.coilValues
                              .asMap()
                              .entries
                              .map(
                                (entry) =>
                                    '${entry.key}: ${entry.value ? 1 : 0}',
                              )
                              .join('\n'),
                    ),
                    if (service.lastError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${service.lastError}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    _PollingTaskList(
                      service: service,
                      onToggle: _togglePolling,
                      onConfigure:
                          () => _configurePeriodicInterval(polling: true),
                    ),
                    const Divider(height: 1),
                    _SendTaskList(
                      service: service,
                      onToggle: _toggleSending,
                      onConfigure:
                          () => _configurePeriodicInterval(polling: false),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        reverse: true,
                        itemCount: service.records.length,
                        itemBuilder: (context, reverseIndex) {
                          final record =
                              service.records[service.records.length -
                                  1 -
                                  reverseIndex];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              record.outbound
                                  ? Icons.north_east
                                  : Icons.south_west,
                              size: 18,
                            ),
                            title: SelectableText(
                              _hex(record.frame),
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                              ),
                            ),
                            subtitle: Text(
                              '${record.timestamp.toIso8601String()}  ${record.status}${record.elapsed == null ? '' : '  ${record.elapsed!.inMilliseconds} ms'}',
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numberField(
    TextEditingController controller,
    String label, {
    ValueChanged<String>? onChanged,
  }) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: secondaryDialogFieldDecoration(labelText: label),
    onChanged: onChanged,
  );
}

class _PollingTaskList extends StatelessWidget {
  const _PollingTaskList({
    required this.service,
    required this.onToggle,
    required this.onConfigure,
  });
  final ModbusClientService service;
  final VoidCallback onToggle;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 190,
    child: Column(
      children: [
        ListTile(
          dense: true,
          title: const Text(
            '周期轮询任务',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolbarIconButton(
                tooltip: '轮询周期设置',
                onPressed: onConfigure,
                icon: const Icon(Icons.settings_outlined),
              ),
              ToolbarStartStopButton(
                running: service.polling,
                label: service.polling ? '停止' : '开始',
                tooltip: service.polling ? '停止周期轮询' : '开始周期轮询',
                onPressed:
                    service.sessionActive &&
                            (service.polling ||
                                service.tasks.any((task) => task.enabled))
                        ? onToggle
                        : null,
              ),
            ],
          ),
        ),
        Expanded(
          child:
              service.tasks.isEmpty
                  ? const Center(child: Text('暂无任务'))
                  : ListView.builder(
                    itemCount: service.tasks.length,
                    itemBuilder: (context, index) {
                      final task = service.tasks[index];
                      final result = service.taskResults[task.id];
                      return ListTile(
                        dense: true,
                        leading: Checkbox(
                          value: task.enabled,
                          onChanged:
                              (value) => service.setTaskEnabled(
                                task.id,
                                value ?? false,
                              ),
                        ),
                        title: Text(task.name),
                        subtitle: Text(
                          '${task.function.label} U${task.unitId} A${task.address} ×${task.quantity}'
                          '${result == null ? '' : '  已响应'}',
                        ),
                        trailing: IconButton(
                          tooltip: '删除任务',
                          onPressed:
                              service.polling
                                  ? null
                                  : () => service.removeTask(task.id),
                          icon: const Icon(Icons.close),
                        ),
                      );
                    },
                  ),
        ),
      ],
    ),
  );
}

class _SendTaskList extends StatelessWidget {
  const _SendTaskList({
    required this.service,
    required this.onToggle,
    required this.onConfigure,
  });
  final ModbusClientService service;
  final VoidCallback onToggle;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 190,
    child: Column(
      children: [
        ListTile(
          dense: true,
          title: const Text(
            '周期发送任务',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolbarIconButton(
                tooltip: '发送周期设置',
                onPressed: onConfigure,
                icon: const Icon(Icons.settings_outlined),
              ),
              ToolbarStartStopButton(
                running: service.sending,
                label: service.sending ? '停止' : '开始',
                tooltip: service.sending ? '停止周期发送' : '开始周期发送',
                onPressed:
                    service.sessionActive &&
                            (service.sending ||
                                service.sendTasks.any((task) => task.enabled))
                        ? onToggle
                        : null,
              ),
            ],
          ),
        ),
        Expanded(
          child:
              service.sendTasks.isEmpty
                  ? const Center(child: Text('暂无任务'))
                  : ListView.builder(
                    itemCount: service.sendTasks.length,
                    itemBuilder: (context, index) {
                      final task = service.sendTasks[index];
                      return ListTile(
                        dense: true,
                        leading: Checkbox(
                          value: task.enabled,
                          onChanged:
                              (value) => service.setSendTaskEnabled(
                                task.id,
                                value ?? false,
                              ),
                        ),
                        title: Text(task.name),
                        subtitle: Text(
                          '${task.function.label} U${task.unitId} A${task.address} ×${task.quantity} / '
                          '${task.valueMode.label}'
                          '${task.valueMode == ModbusSendValueMode.random ? '' : ' ${task.step}'}',
                        ),
                        trailing: IconButton(
                          tooltip: '删除任务',
                          onPressed:
                              service.sending
                                  ? null
                                  : () => service.removeSendTask(task.id),
                          icon: const Icon(Icons.close),
                        ),
                      );
                    },
                  ),
        ),
      ],
    ),
  );
}
