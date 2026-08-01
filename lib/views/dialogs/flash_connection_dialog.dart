import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';

import '../../data/models/flash_programming_models.dart';
import '../../services/app_settings.dart';
import '../../services/bundled_openocd_runtime.dart';

Future<FlashConnectionConfig?> showFlashConnectionDialog(
  BuildContext context,
) => showDialog<FlashConnectionConfig>(
  context: context,
  builder: (_) => const FlashConnectionDialog(),
);

class FlashConnectionDialog extends StatefulWidget {
  const FlashConnectionDialog({super.key});

  @override
  State<FlashConnectionDialog> createState() => _FlashConnectionDialogState();
}

class _FlashConnectionDialogState extends State<FlashConnectionDialog> {
  late FlashConnectionConfig _config;
  late final TextEditingController _target;
  late final TextEditingController _probeId;
  late final TextEditingController _clock;
  late final TextEditingController _jlink;
  late final TextEditingController _openocd;
  late final TextEditingController _interfaceCfg;
  late final TextEditingController _targetCfg;

  @override
  void initState() {
    super.initState();
    _config = AppSettings().flashConnectionConfig;
    _target = TextEditingController(text: _config.target);
    _probeId = TextEditingController(text: _config.probeId);
    _clock = TextEditingController(text: '${_config.clockKhz}');
    _jlink = TextEditingController(text: _config.jlinkExecutablePath);
    _openocd = TextEditingController(text: _config.openocdExecutablePath);
    _interfaceCfg = TextEditingController(text: _config.openOcdInterfaceConfig);
    _targetCfg = TextEditingController(text: _config.openOcdTargetConfig);
  }

  @override
  void dispose() {
    for (final controller in [
      _target,
      _probeId,
      _clock,
      _jlink,
      _openocd,
      _interfaceCfg,
      _targetCfg,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _usesJlink =>
      _config.backend == ProgrammingBackendSelection.externalJlink ||
      (_config.backend == ProgrammingBackendSelection.automatic &&
          _config.probeKind == FlashProbeKind.jlink);

  bool get _usesOpenOcd => !_usesJlink;

  Future<void> _pickExecutable(TextEditingController controller) async {
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: '选择编程工具',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['exe'],
      initialDirectory:
          controller.text.trim().isEmpty
              ? null
              : File(controller.text.trim()).parent.path,
    );
    final path = result?.files.single.path;
    if (path != null) setState(() => controller.text = path);
  }

  Future<void> _pickCfg(
    TextEditingController controller,
    String subdirectory,
  ) async {
    String? initialDirectory;
    var executable = _openocd.text.trim();
    if (executable.isEmpty) {
      executable = await BundledOpenOcdRuntime().ensureReady() ?? '';
    }
    if (executable.isNotEmpty) {
      final scripts = Directory(
        '${File(executable).parent.parent.path}${Platform.pathSeparator}share'
        '${Platform.pathSeparator}openocd${Platform.pathSeparator}scripts'
        '${Platform.pathSeparator}$subdirectory',
      );
      if (scripts.existsSync()) initialDirectory = scripts.path;
    }
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: '选择OpenOCD配置',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['cfg'],
      initialDirectory: initialDirectory,
    );
    final path = result?.files.single.path;
    if (path != null) setState(() => controller.text = path);
  }

  Future<void> _save() async {
    final clock = int.tryParse(_clock.text.trim());
    if (_target.text.trim().isEmpty) {
      _showError('必须填写目标芯片');
      return;
    }
    if (clock == null || clock < 1 || clock > 50000) {
      _showError('调试时钟必须在1～50000 kHz之间');
      return;
    }
    if (_usesOpenOcd &&
        (_interfaceCfg.text.trim().isEmpty || _targetCfg.text.trim().isEmpty)) {
      _showError('OpenOCD需要接口配置和目标配置');
      return;
    }
    final value = _config.copyWith(
      probeId: _probeId.text.trim(),
      target: _target.text.trim(),
      clockKhz: clock,
      jlinkExecutablePath: _jlink.text.trim(),
      openocdExecutablePath: _openocd.text.trim(),
      openOcdInterfaceConfig: _interfaceCfg.text.trim(),
      openOcdTargetConfig: _targetCfg.text.trim(),
    );
    AppSettings().flashConnectionConfig = value;
    await AppSettings().save();
    if (mounted) Navigator.pop(context, value);
  }

  void _showError(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    title: const Text('Flash连接配置'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<ProgrammingBackendSelection>(
              initialValue: _config.backend,
              decoration: const InputDecoration(labelText: '编程后端'),
              items: [
                for (final value in ProgrammingBackendSelection.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _config = _config.copyWith(
                    backend: value,
                    probeKind:
                        value == ProgrammingBackendSelection.externalJlink
                            ? FlashProbeKind.jlink
                            : value ==
                                    ProgrammingBackendSelection
                                        .externalOpenocd ||
                                value ==
                                    ProgrammingBackendSelection.bundledOpenocd
                            ? FlashProbeKind.cmsisDap
                            : _config.probeKind,
                  );
                });
              },
            ),
            if (_config.backend == ProgrammingBackendSelection.automatic)
              DropdownButtonFormField<FlashProbeKind>(
                initialValue: _config.probeKind,
                decoration: const InputDecoration(labelText: '探针类型'),
                items: [
                  for (final value in FlashProbeKind.values)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged:
                    (value) => setState(
                      () => _config = _config.copyWith(probeKind: value),
                    ),
              ),
            Row(
              children: [
                Expanded(child: _field(_target, '目标芯片')),
                const SizedBox(width: 10),
                Expanded(child: _field(_probeId, '探针序列号（可选）')),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<FlashWireProtocol>(
                    initialValue: _config.wireProtocol,
                    decoration: const InputDecoration(labelText: '调试接口'),
                    items: [
                      for (final value in FlashWireProtocol.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged:
                        (value) => setState(
                          () => _config = _config.copyWith(wireProtocol: value),
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _field(_clock, '调试时钟（kHz）')),
              ],
            ),
            if (_usesJlink)
              _pathField(
                _jlink,
                'JLink.exe（可留空自动查找）',
                () => _pickExecutable(_jlink),
              ),
            if (_usesOpenOcd) ...[
              if (_config.backend != ProgrammingBackendSelection.bundledOpenocd)
                _pathField(
                  _openocd,
                  '外置OpenOCD（自动模式可留空）',
                  () => _pickExecutable(_openocd),
                ),
              _pathField(
                _interfaceCfg,
                'OpenOCD接口配置',
                () => _pickCfg(_interfaceCfg, 'interface'),
              ),
              _pathField(
                _targetCfg,
                'OpenOCD目标配置',
                () => _pickCfg(_targetCfg, 'target'),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );

  Widget _field(TextEditingController controller, String label) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
  );

  Widget _pathField(
    TextEditingController controller,
    String label,
    VoidCallback onPick,
  ) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        tooltip: '选择文件',
        onPressed: onPick,
        icon: const Icon(Icons.folder_open),
      ),
    ),
  );
}
