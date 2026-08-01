import 'dart:async';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/flash_programming_models.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/flash_programming_service.dart';
import '../dialogs/flash_connection_dialog.dart';

class FlashProgrammingPage extends StatefulWidget {
  const FlashProgrammingPage({super.key});

  @override
  State<FlashProgrammingPage> createState() => _FlashProgrammingPageState();
}

class _FlashProgrammingPageState extends State<FlashProgrammingPage> {
  final _file = TextEditingController();
  final _binAddress = TextEditingController(text: '0x08000000');
  final _eraseAddress = TextEditingController(text: '0x08000000');
  final _eraseLength = TextEditingController(text: '0x1000');
  final _readAddress = TextEditingController(text: '0x08000000');
  final _readLength = TextEditingController(text: '0x1000');
  bool _eraseBeforeProgram = true;
  bool _verifyAfterProgram = true;
  bool _keepHalted = false;

  @override
  void dispose() {
    for (final controller in [
      _file,
      _binAddress,
      _eraseAddress,
      _eraseLength,
      _readAddress,
      _readLength,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _parseAddress(String value) {
    final text = value.trim().toLowerCase();
    return int.tryParse(
      text.startsWith('0x') ? text.substring(2) : text,
      radix: text.startsWith('0x') ? 16 : 10,
    );
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('确认'),
                ),
              ],
            ),
      ) ??
      false;

  Future<void> _connect() async {
    final service = context.read<FlashProgrammingService>();
    if (service.isConnected) {
      try {
        await service.disconnect();
      } catch (error) {
        AppNotifications.show('断开Flash会话失败：$error');
      }
      return;
    }
    var config = AppSettings().flashConnectionConfig;
    if (config.target.trim().isEmpty) {
      final selected = await showFlashConnectionDialog(context);
      if (selected == null) return;
      config = selected;
    }
    if (!mounted ||
        !await _confirm(
          '连接高权限Flash会话',
          'Flash功能可能复位、停止、擦除并改写目标芯片。\n\n'
              '目标：${config.target}\n'
              '后端：${config.backend.label}\n\n'
              '请确认目标硬件已处于允许编程的安全状态。',
        )) {
      return;
    }
    try {
      await service.connect(config);
    } catch (error) {
      AppNotifications.show('Flash连接失败：$error');
    }
  }

  Future<void> _pickProgramFile() async {
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: '选择烧写文件',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['elf', 'hex', 'bin'],
    );
    final path = result?.files.single.path;
    if (path != null) setState(() => _file.text = path);
  }

  Future<void> _program() async {
    final address = _parseAddress(_binAddress.text);
    final request = FlashProgramRequest(
      filePath: _file.text.trim(),
      binAddress: address,
      erase: _eraseBeforeProgram,
      verify: _verifyAfterProgram,
      keepHalted: _keepHalted,
    );
    try {
      request.validate();
    } catch (error) {
      AppNotifications.show('$error');
      return;
    }
    final service = context.read<FlashProgrammingService>();
    if (!await _confirm(
      '确认烧写Flash',
      '芯片：${service.config?.target}\n后端：${service.activeBackendName}\n'
          '文件：${request.filePath}\n'
          '${request.erase ? '将先擦除相关Flash。' : '不执行预擦除。'}\n'
          '此操作可能导致现有固件和数据不可恢复。',
    )) {
      return;
    }
    try {
      await service.program(request);
      AppNotifications.show('Flash烧写完成');
    } catch (error) {
      AppNotifications.show('Flash烧写失败：$error');
    }
  }

  Future<void> _erase(bool wholeChip) async {
    final address = _parseAddress(_eraseAddress.text);
    final length = _parseAddress(_eraseLength.text);
    if (!wholeChip &&
        (address == null || address < 0 || length == null || length <= 0)) {
      AppNotifications.show('擦除地址或长度无效');
      return;
    }
    final service = context.read<FlashProgrammingService>();
    final range =
        wholeChip
            ? '全片'
            : '0x${address!.toRadixString(16)} ～ '
                '0x${(address + length!).toRadixString(16)}';
    if (!await _confirm(
      '确认不可恢复的擦除操作',
      '芯片：${service.config?.target}\n后端：${service.activeBackendName}\n'
          '范围：$range\n\n擦除内容无法恢复，成功后目标将保持停止。',
    )) {
      return;
    }
    try {
      await service.erase(
        wholeChip
            ? const FlashEraseRequest.chip()
            : FlashEraseRequest.range(address: address!, length: length!),
      );
      AppNotifications.show('Flash擦除完成，目标保持停止');
    } catch (error) {
      AppNotifications.show('Flash擦除失败：$error');
    }
  }

  Future<void> _read() async {
    final address = _parseAddress(_readAddress.text);
    final length = _parseAddress(_readLength.text);
    if (address == null || address < 0 || length == null || length <= 0) {
      AppNotifications.show('读取地址或长度无效');
      return;
    }
    final output = await file_picker.FilePicker.saveFile(
      dialogTitle: '保存读取数据',
      fileName: 'flash_0x${address.toRadixString(16)}.bin',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['bin'],
    );
    if (output == null || !mounted) return;
    try {
      await context.read<FlashProgrammingService>().read(
        FlashReadRequest(address: address, length: length, outputPath: output),
      );
      AppNotifications.show('Flash读取完成：$output');
    } catch (error) {
      AppNotifications.show('Flash读取失败：$error');
    }
  }

  Future<void> _forceTerminate() async {
    if (!await _confirm(
      '强制终止Flash后端',
      '强制终止后目标状态将标记为未知，程序不会自动发送reset或resume补救命令。是否继续？',
    )) {
      return;
    }
    if (!mounted) return;
    await context.read<FlashProgrammingService>().forceTerminate();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FlashProgrammingService>();
    final connected = service.isConnected;
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed:
                    service.isBusy || service.isConnecting ? null : _connect,
                icon: Icon(connected ? Icons.link_off : Icons.link),
                label: Text(
                  connected
                      ? '断开'
                      : service.isConnecting
                      ? '连接中'
                      : '连接',
                ),
              ),
              IconButton(
                tooltip: 'Flash连接配置',
                onPressed:
                    service.hasSession || service.isConnecting
                        ? null
                        : () => showFlashConnectionDialog(context),
                icon: const Icon(Icons.settings),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '高权限页面：操作可能停核、复位、擦除或改写目标；与RTT监控会话完全隔离。',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (service.hasSession)
                Text(
                  '${service.activeBackendName} · ${service.config?.target}',
                ),
              if (service.isBusy ||
                  service.state == FlashOperationState.unknown)
                TextButton.icon(
                  onPressed: _forceTerminate,
                  icon: const Icon(Icons.dangerous_outlined),
                  label: const Text('强制终止'),
                ),
            ],
          ),
        ),
        if (service.isBusy || service.progress > 0)
          LinearProgressIndicator(value: service.isBusy ? service.progress : 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 480,
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    _sectionTitle('烧写'),
                    TextField(
                      controller: _file,
                      decoration: InputDecoration(
                        labelText: 'ELF / HEX / BIN 文件',
                        suffixIcon: IconButton(
                          tooltip: '选择文件',
                          onPressed: service.isBusy ? null : _pickProgramFile,
                          icon: const Icon(Icons.folder_open),
                        ),
                      ),
                    ),
                    TextField(
                      controller: _binAddress,
                      decoration: const InputDecoration(labelText: 'BIN基地址'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('烧写前擦除'),
                          selected: _eraseBeforeProgram,
                          onSelected:
                              (value) =>
                                  setState(() => _eraseBeforeProgram = value),
                        ),
                        FilterChip(
                          label: const Text('烧写后校验'),
                          selected: _verifyAfterProgram,
                          onSelected:
                              (value) =>
                                  setState(() => _verifyAfterProgram = value),
                        ),
                        FilterChip(
                          label: const Text('完成后保持停止'),
                          selected: _keepHalted,
                          onSelected:
                              (value) => setState(() => _keepHalted = value),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed:
                            connected && !service.isBusy ? _program : null,
                        icon: const Icon(Icons.memory),
                        label: const Text('擦除、烧写并校验'),
                      ),
                    ),
                    const Divider(height: 28),
                    _sectionTitle('擦除'),
                    Row(
                      children: [
                        Expanded(child: _input(_eraseAddress, '起始地址')),
                        const SizedBox(width: 8),
                        Expanded(child: _input(_eraseLength, '长度')),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed:
                              connected && !service.isBusy
                                  ? () => _erase(false)
                                  : null,
                          child: const Text('范围擦除'),
                        ),
                        FilledButton.tonal(
                          onPressed:
                              connected && !service.isBusy
                                  ? () => _erase(true)
                                  : null,
                          child: const Text('全片擦除'),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    _sectionTitle('读取为BIN'),
                    Row(
                      children: [
                        Expanded(child: _input(_readAddress, '起始地址')),
                        const SizedBox(width: 8),
                        Expanded(child: _input(_readLength, '长度')),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: connected && !service.isBusy ? _read : null,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('读取并保存'),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    ListTile(
                      dense: true,
                      title: Text(
                        service.stage.isEmpty ? '工具输出' : service.stage,
                      ),
                      subtitle:
                          service.lastError == null
                              ? null
                              : Text('${service.lastError}'),
                      trailing: IconButton(
                        tooltip: '清空输出',
                        onPressed:
                            service.outputLines.isEmpty
                                ? null
                                : service.clearOutput,
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        color: const Color(0xFF171717),
                        child: ListView.builder(
                          padding: const EdgeInsets.all(10),
                          itemCount: service.outputLines.length,
                          itemBuilder:
                              (_, index) => SelectableText(
                                service.outputLines[index],
                                style: const TextStyle(
                                  color: Color(0xFFE0E0E0),
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                ),
                              ),
                        ),
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

  Widget _sectionTitle(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      value,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  );

  Widget _input(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
  );
}
