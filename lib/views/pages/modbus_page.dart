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
import '../dialogs/data_connection_dialog.dart';

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

  Future<void> _openConnection() async {
    final service = context.read<ModbusClientService>();
    final settings = AppSettings();
    if (service.mode == ModbusMode.tcp && !settings.networkConnectionsEnabled) {
      AppNotifications.show('请先在高级设置中启用网络连接');
      return;
    }
    settings.saveConnectionTypeForPage(
      'modbus',
      service.mode == ModbusMode.tcp
          ? DataConnectionType.tcpClient
          : DataConnectionType.serial,
    );
    await showDataConnectionDialog(context, pageId: 'modbus');
  }

  Future<void> _toggleConnection() async {
    final connection = context.read<DataConnectionService>();
    final modbus = context.read<ModbusClientService>();
    if (connection.isConnected) {
      await modbus.stop();
      await connection.disconnect();
    } else {
      await _openConnection();
    }
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

  Future<void> _addPollingTask() async {
    final request = _buildRequest(context.read<ModbusClientService>().mode);
    if (!request.function.isRead) {
      AppNotifications.show('周期任务仅支持读取功能码');
      return;
    }
    final nameController = TextEditingController(
      text: '${request.function.label} ${request.address}',
    );
    final intervalController = TextEditingController(text: '1000');
    final retriesController = TextEditingController(text: '0');
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('添加轮询任务'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: '任务名称'),
                  ),
                  TextField(
                    controller: intervalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '间隔（ms，最小50）'),
                  ),
                  TextField(
                    controller: retriesController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '读取重试（0～3）'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('添加'),
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) {
      final interval = int.tryParse(intervalController.text) ?? 1000;
      final retries = int.tryParse(retriesController.text) ?? 0;
      context.read<ModbusClientService>().addTask(
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
          intervalMs: interval.clamp(50, 3600000),
          readRetries: retries.clamp(0, 3),
        ),
      );
    }
    nameController.dispose();
    intervalController.dispose();
    retriesController.dispose();
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

  Future<void> _showProtocolSettings() async {
    final service = context.read<ModbusClientService>();
    final controller = TextEditingController(text: '${service.timeoutMs}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Modbus协议设置'),
            content: SizedBox(
              width: 360,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '响应超时（ms）',
                  helperText: '范围100～60000，默认1000',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确定'),
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
      '已导入${imported.tasks.length}项${imported.errors.isEmpty ? '' : '，${imported.errors.join('；')}'}',
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
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: connection.isConnecting ? null : _toggleConnection,
                icon: Icon(
                  connection.isConnected ? Icons.link_off : Icons.link,
                ),
                label: Text(connection.isConnected ? '断开' : '连接'),
              ),
              IconButton(
                tooltip: '连接配置',
                onPressed: connection.isConnected ? null : _openConnection,
                icon: const Icon(Icons.settings),
              ),
              const SizedBox(width: 8),
              SegmentedButton<ModbusMode>(
                segments: [
                  for (final mode in ModbusMode.values)
                    ButtonSegment(value: mode, label: Text(mode.label)),
                ],
                selected: {service.mode},
                showSelectedIcon: false,
                onSelectionChanged:
                    connection.isConnected
                        ? null
                        : (value) => _changeMode(value.first),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: connection.isConnected ? _togglePolling : null,
                icon: Icon(service.polling ? Icons.stop : Icons.play_arrow),
                label: Text(service.polling ? '停止轮询' : '开始轮询'),
              ),
              IconButton(
                tooltip: 'Modbus协议设置',
                onPressed:
                    service.requestPending ? null : _showProtocolSettings,
                icon: const Icon(Icons.tune),
              ),
              const Spacer(),
              IconButton(
                tooltip: '导入任务',
                onPressed: _importTasks,
                icon: const Icon(Icons.file_open),
              ),
              IconButton(
                tooltip: '导出任务',
                onPressed: service.tasks.isEmpty ? null : _exportTasks,
                icon: const Icon(Icons.save_alt),
              ),
              IconButton(
                tooltip: '清空帧记录',
                onPressed:
                    service.records.isEmpty ? null : service.clearRecords,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
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
                    DropdownButtonFormField<ModbusFunction>(
                      initialValue: _function,
                      decoration: const InputDecoration(labelText: '功能码'),
                      items: [
                        for (final item in ModbusFunction.values)
                          DropdownMenuItem(
                            value: item,
                            child: Text(
                              '0x${item.code.toRadixString(16).padLeft(2, '0')} ${item.label}',
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
                      decoration: const InputDecoration(
                        labelText: '写入值（逗号或空格分隔）',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed:
                              connection.isConnected && !service.requestPending
                                  ? _sendManual
                                  : null,
                          icon: const Icon(Icons.send),
                          label: const Text('发送'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _function.isRead ? _addPollingTask : null,
                          icon: const Icon(Icons.add),
                          label: const Text('加入轮询'),
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
                    _TaskList(service: service),
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
    decoration: InputDecoration(labelText: label),
    onChanged: onChanged,
  );
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.service});
  final ModbusClientService service;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 220,
    child: Column(
      children: [
        const ListTile(
          dense: true,
          title: Text('周期轮询任务', style: TextStyle(fontWeight: FontWeight.w600)),
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
                          '${task.function.label} U${task.unitId} A${task.address} ×${task.quantity} / ${task.intervalMs}ms'
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
