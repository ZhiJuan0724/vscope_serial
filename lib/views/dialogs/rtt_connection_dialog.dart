import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/rtt_config.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/rtt_process_backends.dart';
import '../../services/rtt_service.dart';
import '../widgets/common_widgets.dart';

class RttConnectionDialog extends StatefulWidget {
  const RttConnectionDialog({
    super.key,
    this.openOcdConfigFilePicker,
    this.openOcdConfigDirectoryResolver,
  });

  final Future<String?> Function(String dialogTitle, String? initialDirectory)?
  openOcdConfigFilePicker;
  final Future<String?> Function(String configuredPath, String category)?
  openOcdConfigDirectoryResolver;

  @override
  State<RttConnectionDialog> createState() => _RttConnectionDialogState();
}

class _RttConnectionDialogState extends State<RttConnectionDialog> {
  late RttBackendSelection _backend;
  late RttProbeKind _kind;
  late RttWireProtocol _wireProtocol;
  late PyOcdCmsisDapVersion _pyOcdCmsisDapVersion;
  late bool _autoDetect;
  late String _probeId;
  late String _target;
  late final TextEditingController _targetController;
  late final TextEditingController _clockController;
  late final TextEditingController _openOcdInterfaceController;
  late final TextEditingController _openOcdTargetController;
  List<RttProbeInfo> _probes = const [];
  bool _refreshing = false;
  bool _connecting = false;
  int _refreshGeneration = 0;
  int _backendPreviewGeneration = 0;
  String? _expectedBackend;
  String? _expectedBackendError;
  bool _checkingExpectedBackend = false;
  bool _initializedBackendPreview = false;
  String? _error;

  bool get _showsOpenOcdConfig =>
      _backend == RttBackendSelection.bundledOpenocd ||
      _backend == RttBackendSelection.externalOpenocd ||
      (_backend == RttBackendSelection.automatic &&
          _kind == RttProbeKind.cmsisDap);

  RttConnectionConfig _draftConfig() {
    // pyOCD 的刷新列表使用合成 ID 展示 USB 设备；正式连接必须把选中项
    // 还原成 VID/PID，才能让 Worker 跳过全量 USB 探针发现。
    final selectedProbe =
        _probes.where((item) => item.id == _probeId).firstOrNull;
    return RttConnectionConfig(
      backend: _backend,
      probeKind: _kind,
      probeId: _probeId,
      usbVendorId: selectedProbe?.usbVendorId,
      usbProductId: selectedProbe?.usbProductId,
      target: _target.trim(),
      autoDetectTarget: _autoDetect,
      wireProtocol: _wireProtocol,
      clockKhz: int.tryParse(_clockController.text.trim()) ?? 4000,
      controlBlockMode: RttControlBlockMode.fromString(
        AppSettings().rttControlBlockMode,
      ),
      controlBlockAddress: AppSettings().rttControlBlockAddress,
      controlBlockRangeStart: AppSettings().rttControlBlockRangeStart,
      controlBlockRangeEnd: AppSettings().rttControlBlockRangeEnd,
      openOcdInterfaceConfig: _openOcdInterfaceController.text.trim(),
      openOcdTargetConfig: _openOcdTargetController.text.trim(),
      pyOcdCmsisDapVersion: _pyOcdCmsisDapVersion,
    );
  }

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _backend = RttBackendSelection.fromString(settings.rttBackendSelection);
    _kind = RttProbeKind.fromString(settings.rttProbeKind);
    _kind = switch (_backend) {
      RttBackendSelection.externalJlink => RttProbeKind.jlink,
      RttBackendSelection.bundledOpenocd ||
      RttBackendSelection.externalOpenocd ||
      RttBackendSelection.externalPyocd => RttProbeKind.cmsisDap,
      RttBackendSelection.automatic => _kind,
    };
    _wireProtocol = RttWireProtocol.fromString(settings.rttWireProtocol);
    _pyOcdCmsisDapVersion = PyOcdCmsisDapVersion.fromString(
      settings.rttPyocdCmsisDapVersion,
    );
    _autoDetect = settings.rttAutoDetectTarget;
    // 探针尚未枚举时必须显式使用自动选择，不能暗中沿用一个未验证的旧 ID。
    _probeId = '';
    _target = settings.rttTarget;
    _targetController = TextEditingController(text: _target);
    _clockController = TextEditingController(text: '${settings.rttClockKhz}');
    _openOcdInterfaceController = TextEditingController(
      text: settings.rttOpenocdInterfaceConfig,
    );
    _openOcdTargetController = TextEditingController(
      text: settings.rttOpenocdTargetConfig,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedBackendPreview) return;
    _initializedBackendPreview = true;
    unawaited(_updateExpectedBackend());
  }

  @override
  void dispose() {
    _refreshGeneration++;
    _backendPreviewGeneration++;
    _targetController.dispose();
    _clockController.dispose();
    _openOcdInterfaceController.dispose();
    _openOcdTargetController.dispose();
    super.dispose();
  }

  Future<void> _updateExpectedBackend() async {
    final generation = ++_backendPreviewGeneration;
    final kind = _kind;
    final backend = _backend;
    setState(() {
      _checkingExpectedBackend = true;
      _expectedBackendError = null;
    });
    try {
      final name = await context.read<RttService>().expectedBackendName(
        kind,
        backend: backend,
        connectionConfig: _draftConfig(),
      );
      if (!mounted ||
          generation != _backendPreviewGeneration ||
          kind != _kind ||
          backend != _backend) {
        return;
      }
      final suffix = backend == RttBackendSelection.automatic ? '（自动选择）' : '';
      setState(() => _expectedBackend = '$name$suffix');
    } catch (error) {
      if (!mounted || generation != _backendPreviewGeneration) return;
      setState(() {
        _expectedBackend = null;
        _expectedBackendError = '$error';
      });
    } finally {
      if (mounted && generation == _backendPreviewGeneration) {
        setState(() => _checkingExpectedBackend = false);
      }
    }
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final kind = _kind;
    final backend = _backend;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final service = context.read<RttService>();
      final probes = await service.listProbes(
        kind,
        backend: backend,
        connectionConfig: _draftConfig(),
      );
      if (!mounted ||
          generation != _refreshGeneration ||
          kind != _kind ||
          backend != _backend) {
        return;
      }
      setState(() {
        _probes = probes;
        if (_probeId.isNotEmpty &&
            !_probes.any((item) => item.id == _probeId)) {
          _probes = [
            RttProbeInfo(
              id: _probeId,
              name: '$_probeId（当前不存在）',
              kind: _kind,
              available: false,
            ),
            ..._probes,
          ];
        }
      });
    } catch (error) {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _error = _displayRttError(error));
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _selectTarget() async {
    final kind = _kind;
    final backend = _backend;
    final selected = await showDialog<RttTargetInfo>(
      context: context,
      builder:
          (_) => _RttTargetSearchDialog(
            loadTargets:
                () => context.read<RttService>().listTargets(
                  kind,
                  backend: backend,
                  connectionConfig: _draftConfig(),
                ),
          ),
    );
    if (!mounted || selected == null || kind != _kind || backend != _backend) {
      return;
    }
    setState(() {
      _target = selected.name;
      _targetController.text = selected.name;
    });
  }

  Future<void> _selectOpenOcdConfigFile({
    required String dialogTitle,
    required String category,
    required TextEditingController controller,
  }) async {
    final configuredPath = AppSettings().rttOpenocdExecutablePath;
    final directoryResolver = widget.openOcdConfigDirectoryResolver;
    var initialDirectory =
        directoryResolver != null
            ? await directoryResolver(configuredPath, category)
            : _backend == RttBackendSelection.bundledOpenocd
            ? await findBundledOpenOcdConfigDirectory(category)
            : _backend == RttBackendSelection.automatic
            ? await findOpenOcdConfigDirectory(configuredPath, category)
            : await findExternalOpenOcdConfigDirectory(
              configuredPath,
              category,
            );
    if (initialDirectory == null) {
      final currentFile = File(controller.text.trim());
      if (currentFile.isAbsolute && await currentFile.parent.exists()) {
        initialDirectory = currentFile.parent.absolute.path;
      }
    }
    if (!mounted) return;
    final picker = widget.openOcdConfigFilePicker;
    final path =
        picker != null
            ? await picker(dialogTitle, initialDirectory)
            : (await FilePicker.pickFiles(
              dialogTitle: dialogTitle,
              initialDirectory: initialDirectory,
              type: FileType.custom,
              allowedExtensions: const ['cfg'],
              allowMultiple: false,
              lockParentWindow: true,
            ))?.files.single.path;
    if (!mounted || path == null || path.trim().isEmpty) return;
    setState(() {
      controller.text = path;
      _error = null;
    });
    unawaited(_updateExpectedBackend());
  }

  Widget _buildOpenOcdConfigField({
    required String name,
    required String keyPrefix,
    required String hintText,
    required String category,
    required TextEditingController controller,
    required bool enabled,
  }) {
    return TextField(
      key: ValueKey('$keyPrefix-field'),
      controller: controller,
      enabled: enabled,
      onChanged: (_) => unawaited(_updateExpectedBackend()),
      decoration: _connectionFieldDecoration(name, hintText: hintText).copyWith(
        suffixIcon: IconButton(
          key: ValueKey('$keyPrefix-file-button'),
          tooltip: '选择$name文件',
          splashRadius: 18,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          onPressed:
              enabled
                  ? () => unawaited(
                    _selectOpenOcdConfigFile(
                      dialogTitle: '选择$name文件',
                      category: category,
                      controller: controller,
                    ),
                  )
                  : null,
          icon: const Icon(Icons.folder_open_outlined),
        ),
      ),
    );
  }

  Future<void> _connect() async {
    final clock = int.tryParse(_clockController.text.trim());
    if (clock == null || clock < 100 || clock > 50000) {
      setState(() => _error = '调试时钟范围为 100~50000 kHz');
      return;
    }
    if (_backend != RttBackendSelection.externalOpenocd &&
        _backend != RttBackendSelection.bundledOpenocd &&
        !_autoDetect &&
        _target.trim().isEmpty) {
      setState(() => _error = '请选择或输入目标芯片');
      return;
    }
    if (_backend == RttBackendSelection.externalOpenocd ||
        _backend == RttBackendSelection.bundledOpenocd) {
      if (_openOcdInterfaceController.text.trim().isEmpty ||
          _openOcdTargetController.text.trim().isEmpty) {
        setState(() => _error = 'OpenOCD 需要接口配置和目标配置');
        return;
      }
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await context.read<RttService>().connect(_draftConfig());
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = _displayRttError(error));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<RttService>();
    return AlertDialog(
      shape: kAdvancedSettingsDialogShape,
      title: Text(AppStrings.rtt.connect),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NoAnimDropdown<RttBackendSelection>(
                  key: const ValueKey('rtt-backend-field'),
                  value: _backend,
                  hint: '选择后端',
                  decoration: _connectionFieldDecoration('探针后端'),
                  items:
                      RttBackendSelection.values
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item.label),
                            ),
                          )
                          .toList(),
                  onChanged:
                      service.isConnected || _connecting
                          ? null
                          : (value) {
                            if (value == null) return;
                            setState(() {
                              _refreshGeneration++;
                              _refreshing = false;
                              _backend = value;
                              if (value == RttBackendSelection.externalJlink) {
                                _kind = RttProbeKind.jlink;
                              } else if (value ==
                                      RttBackendSelection.bundledOpenocd ||
                                  value ==
                                      RttBackendSelection.externalOpenocd ||
                                  value == RttBackendSelection.externalPyocd) {
                                _kind = RttProbeKind.cmsisDap;
                              }
                              _probeId = '';
                              _probes = const [];
                              _error = null;
                            });
                            unawaited(_updateExpectedBackend());
                          },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: NoAnimDropdown<RttProbeKind>(
                        key: const ValueKey('rtt-probe-kind-field'),
                        value: _kind,
                        hint: '探针类型',
                        decoration: _connectionFieldDecoration('探针类型'),
                        items:
                            RttProbeKind.values
                                .where(
                                  (item) =>
                                      _backendSupportsProbe(_backend, item),
                                )
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item,
                                    child: Text(item.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            service.isConnected || _connecting
                                ? null
                                : (value) {
                                  if (value == null) return;
                                  setState(() {
                                    // 探针类型变化后等待用户主动刷新，避免启动耗时枚举。
                                    _refreshGeneration++;
                                    _refreshing = false;
                                    _kind = value;
                                    if (!_backendSupportsProbe(
                                      _backend,
                                      value,
                                    )) {
                                      _backend = RttBackendSelection.automatic;
                                    }
                                    _probeId = '';
                                    _probes = const [];
                                  });
                                  unawaited(_updateExpectedBackend());
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAnimDropdown<String>(
                        key: const ValueKey('rtt-probe-field'),
                        value:
                            _probeId.isEmpty ||
                                    _probes.any((item) => item.id == _probeId)
                                ? _probeId
                                : null,
                        hint: '自动选择',
                        decoration: _connectionFieldDecoration('调试探针'),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('自动选择'),
                          ),
                          ..._probes.map(
                            (item) => DropdownMenuItem(
                              value: item.id,
                              enabled: item.available,
                              child: Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) =>
                                    setState(() => _probeId = value ?? ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          _backend == RttBackendSelection.externalPyocd
                              ? '扫描 USB 设备'
                              : '刷新探针',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap:
                            service.isConnected || _refreshing || _connecting
                                ? null
                                : () => unawaited(_refresh()),
                        child: SizedBox.square(
                          dimension: kToolbarControlExtent,
                          child: Center(
                            child:
                                _refreshing
                                    ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : Icon(
                                      Icons.refresh,
                                      size: kToolbarIconSize,
                                      color:
                                          service.isConnected || _connecting
                                              ? Theme.of(context).disabledColor
                                              : null,
                                    ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Tooltip(
                        message: '仅按当前设置和工具可用性预测；探针占用、目标错误或工具启动失败仍可能导致连接失败',
                        child: Icon(Icons.account_tree_outlined, size: 16),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _checkingExpectedBackend
                            ? '预计使用后端：检测中…'
                            : _expectedBackendError != null
                            ? '预计使用后端：不可用（$_expectedBackendError）'
                            : '预计使用后端：${_expectedBackend ?? '未知'}',
                        key: const ValueKey('rtt-expected-backend'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              _expectedBackendError == null
                                  ? Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant
                                  : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_backend == RttBackendSelection.externalPyocd) ...[
                  const SizedBox(height: 12),
                  NoAnimDropdown<PyOcdCmsisDapVersion>(
                    key: const ValueKey('rtt-pyocd-cmsis-dap-version'),
                    value: _pyOcdCmsisDapVersion,
                    hint: '选择 CMSIS-DAP 版本',
                    decoration: _connectionFieldDecoration('CMSIS-DAP 版本'),
                    items:
                        PyOcdCmsisDapVersion.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(item.label),
                              ),
                            )
                            .toList(),
                    onChanged:
                        service.isConnected || _connecting
                            ? null
                            : (value) {
                              if (value == null) return;
                              setState(() {
                                _refreshGeneration++;
                                _refreshing = false;
                                _pyOcdCmsisDapVersion = value;
                                _probeId = '';
                                _probes = const [];
                                _error = null;
                              });
                              AppSettings().rttPyocdCmsisDapVersion =
                                  value.value;
                              unawaited(AppSettings().save());
                            },
                  ),
                ],
                if (_showsOpenOcdConfig) ...[
                  const SizedBox(height: 12),
                  _buildOpenOcdConfigField(
                    name: 'OpenOCD 接口配置',
                    keyPrefix: 'rtt-openocd-interface',
                    hintText: '例如 interface/cmsis-dap.cfg',
                    category: 'interface',
                    controller: _openOcdInterfaceController,
                    enabled: !service.isConnected && !_connecting,
                  ),
                  const SizedBox(height: 12),
                  _buildOpenOcdConfigField(
                    name: 'OpenOCD 目标配置',
                    keyPrefix: 'rtt-openocd-target',
                    hintText: '例如 target/stm32f4x.cfg',
                    category: 'target',
                    controller: _openOcdTargetController,
                    enabled: !service.isConnected && !_connecting,
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '可直接输入 OpenOCD scripts 相对配置名，也可从右侧按钮选择 .cfg 文件。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (_backend != RttBackendSelection.externalOpenocd &&
                    _backend != RttBackendSelection.bundledOpenocd)
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          key: const ValueKey('rtt-target-field'),
                          controller: _targetController,
                          onChanged: (value) => _target = value,
                          enabled: !_autoDetect && !service.isConnected,
                          decoration: _connectionFieldDecoration(
                            '目标芯片',
                            hintText: '输入芯片型号',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        key: const ValueKey('rtt-target-search-button'),
                        tooltip: '检索支持的芯片',
                        onPressed:
                            _autoDetect || service.isConnected || _connecting
                                ? null
                                : () => unawaited(_selectTarget()),
                        icon: const Icon(Icons.manage_search),
                      ),
                      const SizedBox(width: 4),
                      Checkbox(
                        value: _autoDetect,
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) => setState(
                                  () => _autoDetect = value ?? false,
                                ),
                      ),
                      const Text('自动识别'),
                    ],
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: NoAnimDropdown<RttWireProtocol>(
                        value: _wireProtocol,
                        hint: '接口',
                        decoration: _connectionFieldDecoration('调试接口'),
                        items:
                            RttWireProtocol.values
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item,
                                    child: Text(item.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) => setState(
                                  () => _wireProtocol = value ?? _wireProtocol,
                                ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('rtt-clock-field'),
                        controller: _clockController,
                        enabled: !service.isConnected,
                        keyboardType: TextInputType.number,
                        decoration: _connectionFieldDecoration(
                          '调试时钟',
                          suffixText: 'kHz',
                        ),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _connecting ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (service.isConnected)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed:
                _connecting
                    ? null
                    : () async {
                      setState(() => _connecting = true);
                      await service.disconnect();
                      if (context.mounted) Navigator.of(context).pop();
                    },
            icon: const Icon(Icons.stop),
            label: const Text('断开'),
          )
        else
          ElevatedButton.icon(
            onPressed: _refreshing || _connecting ? null : _connect,
            icon: const Icon(Icons.link),
            label: const Text('连接'),
          ),
      ],
    );
  }
}

/// 去掉 Dart 异常类型前缀，连接窗口只展示可操作的错误内容。
String _displayRttError(Object error) => '$error'.replaceFirst(
  RegExp(r'^(?:Bad state|TimeoutException|FormatException):\s*'),
  '',
);

bool _backendSupportsProbe(RttBackendSelection backend, RttProbeKind kind) =>
    switch (backend) {
      RttBackendSelection.externalJlink => kind == RttProbeKind.jlink,
      RttBackendSelection.bundledOpenocd ||
      RttBackendSelection.externalOpenocd ||
      RttBackendSelection.externalPyocd => kind == RttProbeKind.cmsisDap,
      RttBackendSelection.automatic => true,
    };

class _RttTargetSearchDialog extends StatefulWidget {
  const _RttTargetSearchDialog({required this.loadTargets});

  final Future<List<RttTargetInfo>> Function() loadTargets;

  @override
  State<_RttTargetSearchDialog> createState() => _RttTargetSearchDialogState();
}

class _RttTargetSearchDialogState extends State<_RttTargetSearchDialog> {
  late Future<List<RttTargetInfo>> _targetsFuture;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _targetsFuture = widget.loadTargets();
  }

  void _reload() {
    setState(() => _targetsFuture = widget.loadTargets());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: kAdvancedSettingsDialogShape,
      title: const Text('选择目标芯片'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('rtt-target-search-field'),
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '输入型号、厂商或来源进行模糊搜索',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<List<RttTargetInfo>>(
                future: _targetsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '加载支持列表失败：${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试'),
                          ),
                        ],
                      ),
                    );
                  }
                  final matches = (snapshot.data ?? const <RttTargetInfo>[])
                      .where((item) => _matchesTarget(item, _query))
                      .toList(growable: false);
                  if (matches.isEmpty) {
                    return const Center(child: Text('没有匹配的目标芯片'));
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '匹配 ${matches.length} 项',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: ListView.separated(
                          itemCount: matches.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final target = matches[index];
                            final details = [
                              if (target.vendor.isNotEmpty) target.vendor,
                              if (target.source.isNotEmpty) target.source,
                            ].join(' · ');
                            return ListTile(
                              key: ValueKey('rtt-target-option-${target.name}'),
                              dense: true,
                              title: Text(target.name),
                              subtitle: details.isEmpty ? null : Text(details),
                              onTap: () => Navigator.of(context).pop(target),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

bool _matchesTarget(RttTargetInfo target, String query) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((item) => item.isNotEmpty);
  if (tokens.isEmpty) return true;
  final candidates = [target.name, target.vendor, target.source]
      .where((item) => item.isNotEmpty)
      .map(_normalizeTargetSearchText)
      .toList(growable: false);
  return tokens.every((token) {
    final normalized = _normalizeTargetSearchText(token);
    return candidates.any(
      (candidate) =>
          candidate.contains(normalized) ||
          _containsOrderedCharacters(candidate, normalized),
    );
  });
}

String _normalizeTargetSearchText(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s_\-./()]+'), '');

bool _containsOrderedCharacters(String candidate, String query) {
  if (query.isEmpty) return true;
  var queryIndex = 0;
  for (final codeUnit in candidate.codeUnits) {
    if (codeUnit == query.codeUnitAt(queryIndex)) {
      queryIndex++;
      if (queryIndex == query.length) return true;
    }
  }
  return false;
}

/// RTT 连接下拉框与串口连接窗口保持相同的可见高度和内容留白。
InputDecoration _connectionFieldDecoration(
  String labelText, {
  String? hintText,
  String? suffixText,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    suffixText: suffixText,
    border: const OutlineInputBorder(),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );
}

Future<void> showRttConnectionDialog(BuildContext context) async {
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RttConnectionDialog(),
    );
  } catch (error) {
    AppNotifications.show('打开探针连接窗口失败: $error');
  }
}
