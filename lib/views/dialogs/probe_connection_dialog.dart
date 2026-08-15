import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/flash_programming_models.dart';
import '../../data/models/probe_connection_config.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/flash_programming_service.dart';
import '../../services/rtt_process_backends.dart';
import '../../services/probe_connection_service.dart';
import '../widgets/common_widgets.dart';

class ProbeConnectionDialog extends StatefulWidget {
  const ProbeConnectionDialog({
    super.key,
    this.forFlashProgramming = false,
    this.openOcdConfigFilePicker,
    this.openOcdConfigDirectoryResolver,
  });

  /// 只复用探针枚举、芯片选择和配置表单；实际连接交给独立Flash服务。
  final bool forFlashProgramming;

  final Future<String?> Function(String dialogTitle, String? initialDirectory)?
  openOcdConfigFilePicker;
  final Future<String?> Function(String configuredPath, String category)?
  openOcdConfigDirectoryResolver;

  @override
  State<ProbeConnectionDialog> createState() => _ProbeConnectionDialogState();
}

class _ProbeConnectionDialogState extends State<ProbeConnectionDialog> {
  late ProbeBackendSelection _backend;
  late ProbeKind _kind;
  late ProbeWireProtocol _wireProtocol;
  late PyOcdCmsisDapVersion _pyOcdCmsisDapVersion;
  late bool _autoDetect;
  late String _probeId;
  late String _target;
  late final TextEditingController _targetController;
  late final TextEditingController _clockController;
  late final TextEditingController _openOcdInterfaceController;
  late final TextEditingController _openOcdTargetController;
  List<ProbeInfo> _probes = const [];
  bool _refreshing = false;
  bool _connecting = false;
  bool _cancellingConnection = false;
  int _refreshGeneration = 0;
  int _backendPreviewGeneration = 0;
  String? _expectedBackend;
  String? _expectedBackendError;
  bool _checkingExpectedBackend = false;
  bool _initializedBackendPreview = false;
  String? _error;
  Timer? _configSaveTimer;
  Future<void> _pendingConfigSave = Future<void>.value();

  bool get _showsOpenOcdConfig =>
      _backend == ProbeBackendSelection.bundledOpenocd ||
      _backend == ProbeBackendSelection.externalOpenocd ||
      (_backend == ProbeBackendSelection.automatic &&
          _kind == ProbeKind.cmsisDap);

  bool get _isProgramming => widget.forFlashProgramming;

  ProbeConnectionConfig _draftConfig() {
    // pyOCD 的刷新列表使用合成 ID 展示 USB 设备；正式连接必须把选中项
    // 还原成 VID/PID，才能让 Worker 跳过全量 USB 探针发现。
    final selectedProbe =
        _probes.where((item) => item.id == _probeId).firstOrNull;
    return ProbeConnectionConfig(
      backend: _backend,
      probeKind: _kind,
      probeId: _probeId,
      usbVendorId: selectedProbe?.usbVendorId,
      usbProductId: selectedProbe?.usbProductId,
      target: _targetController.text.trim(),
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

  FlashConnectionConfig _draftFlashConfig() => FlashConnectionConfig(
    backend: _toProgrammingBackend(_backend),
    probeKind:
        _kind == ProbeKind.jlink
            ? FlashProbeKind.jlink
            : FlashProbeKind.cmsisDap,
    probeId: _probeId,
    target: _targetController.text.trim(),
    wireProtocol:
        _wireProtocol == ProbeWireProtocol.swd
            ? FlashWireProtocol.swd
            : FlashWireProtocol.jtag,
    clockKhz: int.tryParse(_clockController.text.trim()) ?? 4000,
    // Flash与普通探针连接复用高级设置中的工具定位；这里只隔离连接会话，
    // 不再要求用户在Flash窗口重复填写外部工具路径。
    jlinkExecutablePath: AppSettings().rttJlinkExecutablePath,
    openocdExecutablePath: AppSettings().rttOpenocdExecutablePath,
    openOcdInterfaceConfig: _openOcdInterfaceController.text.trim(),
    openOcdTargetConfig: _openOcdTargetController.text.trim(),
  );

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    final flashConfig = settings.flashConnectionConfig;
    _backend =
        _isProgramming
            ? _toProbeBackend(flashConfig.backend)
            : ProbeBackendSelection.fromString(settings.rttBackendSelection);
    _kind =
        _isProgramming
            ? flashConfig.probeKind == FlashProbeKind.jlink
                ? ProbeKind.jlink
                : ProbeKind.cmsisDap
            : ProbeKind.fromString(settings.rttProbeKind);
    _kind = switch (_backend) {
      ProbeBackendSelection.externalJlink => ProbeKind.jlink,
      ProbeBackendSelection.bundledOpenocd ||
      ProbeBackendSelection.externalOpenocd ||
      ProbeBackendSelection.externalPyocd => ProbeKind.cmsisDap,
      ProbeBackendSelection.automatic => _kind,
    };
    _wireProtocol =
        _isProgramming
            ? flashConfig.wireProtocol == FlashWireProtocol.swd
                ? ProbeWireProtocol.swd
                : ProbeWireProtocol.jtag
            : ProbeWireProtocol.fromString(settings.rttWireProtocol);
    _pyOcdCmsisDapVersion = PyOcdCmsisDapVersion.fromString(
      settings.rttPyocdCmsisDapVersion,
    );
    _autoDetect = _isProgramming ? false : settings.rttAutoDetectTarget;
    // 探针尚未枚举时必须显式使用自动选择，不能暗中沿用一个未验证的旧 ID。
    _probeId = '';
    _target = _isProgramming ? flashConfig.target : settings.rttTarget;
    _targetController = TextEditingController(text: _target);
    _clockController = TextEditingController(
      text: '${_isProgramming ? flashConfig.clockKhz : settings.rttClockKhz}',
    );
    _openOcdInterfaceController = TextEditingController(
      text:
          _isProgramming
              ? flashConfig.openOcdInterfaceConfig.trim().isNotEmpty
                  ? flashConfig.openOcdInterfaceConfig
                  : settings.rttOpenocdInterfaceConfig
              : settings.rttOpenocdInterfaceConfig,
    );
    _openOcdTargetController = TextEditingController(
      text:
          _isProgramming
              ? flashConfig.openOcdTargetConfig.trim().isNotEmpty
                  ? flashConfig.openOcdTargetConfig
                  : settings.rttOpenocdTargetConfig
              : settings.rttOpenocdTargetConfig,
    );
    for (final controller in [
      _targetController,
      _clockController,
      _openOcdInterfaceController,
      _openOcdTargetController,
    ]) {
      controller.addListener(_scheduleConfigSave);
    }
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
    _configSaveTimer?.cancel();
    unawaited(_flushConfigSave(showError: false));
    _refreshGeneration++;
    _backendPreviewGeneration++;
    _targetController.dispose();
    _clockController.dispose();
    _openOcdInterfaceController.dispose();
    _openOcdTargetController.dispose();
    super.dispose();
  }

  void _scheduleConfigSave() {
    _configSaveTimer?.cancel();
    _configSaveTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_flushConfigSave(showError: false)),
    );
  }

  Future<void> _persistDraftConfig(Object config) async {
    if (config is ProbeConnectionConfig) {
      await persistProbeConnectionConfig(config);
      return;
    }
    final flashConfig = config as FlashConnectionConfig;
    final settings = AppSettings();
    final previous = settings.flashConnectionConfig;
    settings.flashConnectionConfig = flashConfig;
    try {
      await settings.save();
    } catch (_) {
      settings.flashConnectionConfig = previous;
      rethrow;
    }
  }

  Future<bool> _flushConfigSave({bool showError = true}) async {
    _configSaveTimer?.cancel();
    final clock = int.tryParse(_clockController.text.trim());
    if (clock == null || clock < 100 || clock > 50000) {
      if (showError && mounted) {
        setState(() => _error = AppStrings.probe.clockRangeError);
      }
      return false;
    }
    final targetRequired =
        _isProgramming
            ? _backend == ProbeBackendSelection.externalJlink ||
                (_backend == ProbeBackendSelection.automatic &&
                    _kind == ProbeKind.jlink)
            : _backend != ProbeBackendSelection.externalOpenocd &&
                _backend != ProbeBackendSelection.bundledOpenocd &&
                !_autoDetect;
    if (targetRequired && _targetController.text.trim().isEmpty) return false;
    final config = _isProgramming ? _draftFlashConfig() : _draftConfig();
    _pendingConfigSave = _pendingConfigSave.then(
      (_) => _persistDraftConfig(config),
      onError: (_) => _persistDraftConfig(config),
    );
    try {
      await _pendingConfigSave;
      return true;
    } catch (error) {
      if (showError && mounted) {
        setState(() => _error = AppStrings.probe.saveConfigFailed('$error'));
      }
      return false;
    }
  }

  Future<void> _updateExpectedBackend() async {
    _scheduleConfigSave();
    final generation = ++_backendPreviewGeneration;
    final kind = _kind;
    final backend = _backend;
    setState(() {
      _checkingExpectedBackend = true;
      _expectedBackendError = null;
    });
    try {
      final name =
          _isProgramming
              ? await context
                  .read<FlashProgrammingService>()
                  .expectedBackendName(_draftFlashConfig())
              : await context
                  .read<ProbeConnectionService>()
                  .expectedBackendName(
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
      final suffix =
          backend == ProbeBackendSelection.automatic
              ? AppStrings.probe.autoSelectedSuffix
              : '';
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
      final service = context.read<ProbeConnectionService>();
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
            ProbeInfo(
              id: _probeId,
              name: AppStrings.probe.probeUnavailable(_probeId),
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
    final selected = await showDialog<ProbeTargetInfo>(
      context: context,
      builder:
          (_) => _RttTargetSearchDialog(
            loadTargets:
                () => context.read<ProbeConnectionService>().listTargets(
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
    try {
      final configuredPath = AppSettings().rttOpenocdExecutablePath;
      final directoryResolver = widget.openOcdConfigDirectoryResolver;
      var initialDirectory =
          directoryResolver != null
              ? await directoryResolver(configuredPath, category)
              : _backend == ProbeBackendSelection.bundledOpenocd
              ? await findBundledOpenOcdConfigDirectory(category)
              : _backend == ProbeBackendSelection.automatic
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
    } catch (error) {
      if (mounted) setState(() => _error = _displayRttError(error));
    }
  }

  Widget _buildOpenOcdConfigField({
    required String name,
    required String keyPrefix,
    required String hintText,
    required String category,
    required TextEditingController controller,
    required bool enabled,
  }) {
    return AppLabeledField(
      label: name,
      child: TextField(
        key: ValueKey('$keyPrefix-field'),
        controller: controller,
        enabled: enabled,
        onChanged: (_) => unawaited(_updateExpectedBackend()),
        decoration: _connectionFieldDecoration(hintText: hintText).copyWith(
          suffixIcon: IconButton(
            key: ValueKey('$keyPrefix-file-button'),
            tooltip: AppStrings.probe.chooseConfigFile(name),
            splashRadius: 18,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            onPressed:
                enabled
                    ? () => unawaited(
                      _selectOpenOcdConfigFile(
                        dialogTitle: AppStrings.probe.chooseConfigFile(name),
                        category: category,
                        controller: controller,
                      ),
                    )
                    : null,
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmFlashConnection(FlashConnectionConfig config) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => AlertDialog(
              shape: kAdvancedSettingsDialogShape,
              title: Text(AppStrings.probe.connectHighPrivilegeFlashTitle),
              content: Text(
                AppStrings.probe.flashConnectionConfirmMessage(
                  target:
                      config.target.isEmpty
                          ? config.openOcdTargetConfig
                          : config.target,
                  backendLabel: config.backend.label,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(AppStrings.common.cancel),
                ),
                DialogPrimaryActionButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  label: AppStrings.probe.confirmConnect,
                ),
              ],
            ),
      ) ??
      false;

  Future<void> _connect() async {
    final flashService =
        _isProgramming ? context.read<FlashProgrammingService>() : null;
    final probeService =
        _isProgramming ? null : context.read<ProbeConnectionService>();
    final clock = int.tryParse(_clockController.text.trim());
    if (clock == null || clock < 100 || clock > 50000) {
      setState(() => _error = AppStrings.probe.clockRangeError);
      return;
    }
    final targetRequired =
        _isProgramming
            ? _backend == ProbeBackendSelection.externalJlink ||
                (_backend == ProbeBackendSelection.automatic &&
                    _kind == ProbeKind.jlink)
            : _backend != ProbeBackendSelection.externalOpenocd &&
                _backend != ProbeBackendSelection.bundledOpenocd &&
                !_autoDetect;
    if (targetRequired && _target.trim().isEmpty) {
      setState(() => _error = AppStrings.probe.selectOrInputTargetChip);
      return;
    }
    final openOcdConfigRequired =
        _backend == ProbeBackendSelection.externalOpenocd ||
        _backend == ProbeBackendSelection.bundledOpenocd ||
        (_isProgramming &&
            _backend == ProbeBackendSelection.automatic &&
            _kind == ProbeKind.cmsisDap);
    if (openOcdConfigRequired) {
      if (_openOcdInterfaceController.text.trim().isEmpty ||
          _openOcdTargetController.text.trim().isEmpty) {
        setState(() => _error = AppStrings.probe.openOcdRequiresConfigs);
        return;
      }
    }
    if (!await _flushConfigSave()) return;
    if (!mounted) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      if (_isProgramming) {
        final config = _draftFlashConfig();
        if (!await _confirmFlashConnection(config)) return;
        if (!mounted) return;
        await flashService!.connect(config);
      } else {
        await probeService!.connect(_draftConfig());
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted && !_cancellingConnection) {
        setState(() => _error = _displayRttError(error));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _cancelConnection() async {
    if (!_connecting || _cancellingConnection) return;
    setState(() => _cancellingConnection = true);
    final probeService = context.read<ProbeConnectionService>();
    final flashService = context.read<FlashProgrammingService?>();
    // 连接窗口本身不应被慢速驱动枚举或外部进程退出阻塞；先响应用户关闭，
    // 服务层继续等待后端完整收敛，并以连接代次阻止旧请求重新变为已连接。
    Navigator.of(context).pop();
    try {
      if (_isProgramming) {
        await flashService?.forceTerminate();
      } else {
        await probeService.disconnect();
      }
    } catch (error) {
      AppNotifications.show('取消连接失败：${_displayRttError(error)}');
    }
  }

  Future<void> _close() async {
    await _flushConfigSave(showError: false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final probeService = context.watch<ProbeConnectionService>();
    final flashService =
        _isProgramming ? context.watch<FlashProgrammingService>() : null;
    final isConnected =
        _isProgramming
            ? flashService?.isConnected ?? false
            : probeService.isConnected;
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
                AppDialogDropdown<ProbeBackendSelection>(
                  key: const ValueKey('rtt-backend-field'),
                  value: _backend,
                  hint: AppStrings.probe.selectBackendHint,
                  labelText: AppStrings.common.settingsProbeBackend,
                  items:
                      ProbeBackendSelection.values
                          .where(
                            (item) =>
                                !_isProgramming ||
                                item != ProbeBackendSelection.externalPyocd,
                          )
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item.label),
                            ),
                          )
                          .toList(),
                  onChanged:
                      isConnected || _connecting
                          ? null
                          : (value) {
                            if (value == null) return;
                            setState(() {
                              _refreshGeneration++;
                              _refreshing = false;
                              _backend = value;
                              if (value ==
                                  ProbeBackendSelection.externalJlink) {
                                _kind = ProbeKind.jlink;
                              } else if (value ==
                                      ProbeBackendSelection.bundledOpenocd ||
                                  value ==
                                      ProbeBackendSelection.externalOpenocd ||
                                  value ==
                                      ProbeBackendSelection.externalPyocd) {
                                _kind = ProbeKind.cmsisDap;
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
                      child: AppDialogDropdown<ProbeKind>(
                        key: const ValueKey('rtt-probe-kind-field'),
                        value: _kind,
                        hint: AppStrings.probe.probeKind,
                        labelText: AppStrings.probe.probeKind,
                        items:
                            ProbeKind.values
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
                            isConnected || _connecting
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
                                      _backend =
                                          ProbeBackendSelection.automatic;
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
                      child: AppDialogDropdown<String>(
                        key: const ValueKey('rtt-probe-field'),
                        value:
                            _probeId.isEmpty ||
                                    _probes.any((item) => item.id == _probeId)
                                ? _probeId
                                : null,
                        hint: AppStrings.probe.autoSelect,
                        labelText: AppStrings.probe.probeFieldLabel,
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(AppStrings.probe.autoSelect),
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
                            isConnected
                                ? null
                                : (value) {
                                  setState(() => _probeId = value ?? '');
                                  _scheduleConfigSave();
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          _backend == ProbeBackendSelection.externalPyocd
                              ? AppStrings.probe.scanUsbDevices
                              : AppStrings.probe.refreshProbes,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap:
                            isConnected || _refreshing || _connecting
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
                                          isConnected || _connecting
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
                      Tooltip(
                        message: AppStrings.probe.expectedBackendTooltip,
                        child: const Icon(
                          Icons.account_tree_outlined,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _checkingExpectedBackend
                            ? AppStrings.probe.expectedBackendChecking
                            : _expectedBackendError != null
                            ? AppStrings.probe.expectedBackendUnavailable(
                              _expectedBackendError!,
                            )
                            : AppStrings.probe.expectedBackendResolved(
                              _expectedBackend ?? AppStrings.appInfo.unknown,
                            ),
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
                if (_backend == ProbeBackendSelection.externalPyocd) ...[
                  const SizedBox(height: 12),
                  AppDialogDropdown<PyOcdCmsisDapVersion>(
                    key: const ValueKey('rtt-pyocd-cmsis-dap-version'),
                    value: _pyOcdCmsisDapVersion,
                    hint: AppStrings.probe.selectCmsisDapVersionHint,
                    labelText: AppStrings.probe.cmsisDapVersionLabel,
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
                        isConnected || _connecting
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
                              _scheduleConfigSave();
                            },
                  ),
                ],
                if (_showsOpenOcdConfig) ...[
                  const SizedBox(height: 12),
                  _buildOpenOcdConfigField(
                    name: AppStrings.probe.openOcdInterfaceConfig,
                    keyPrefix: 'rtt-openocd-interface',
                    hintText: AppStrings.probe.openOcdInterfaceHint,
                    category: 'interface',
                    controller: _openOcdInterfaceController,
                    enabled: !isConnected && !_connecting,
                  ),
                  const SizedBox(height: 12),
                  _buildOpenOcdConfigField(
                    name: AppStrings.probe.openOcdTargetConfig,
                    keyPrefix: 'rtt-openocd-target',
                    hintText: AppStrings.probe.openOcdTargetHint,
                    category: 'target',
                    controller: _openOcdTargetController,
                    enabled: !isConnected && !_connecting,
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      AppStrings.probe.openOcdConfigHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (_backend != ProbeBackendSelection.externalOpenocd &&
                    _backend != ProbeBackendSelection.bundledOpenocd)
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: AppLabeledField(
                          key: const ValueKey('rtt-target-field-container'),
                          label: AppStrings.probe.targetChipLabel,
                          child: TextField(
                            key: const ValueKey('rtt-target-field'),
                            controller: _targetController,
                            onChanged: (value) => _target = value,
                            enabled: !_autoDetect && !isConnected,
                            decoration: _connectionFieldDecoration(
                              hintText: AppStrings.probe.targetChipHint,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        key: const ValueKey('rtt-target-search-button'),
                        tooltip: AppStrings.probe.searchSupportedChips,
                        onPressed:
                            _autoDetect || isConnected || _connecting
                                ? null
                                : () => unawaited(_selectTarget()),
                        icon: const Icon(Icons.manage_search),
                      ),
                      const SizedBox(width: 4),
                      Checkbox(
                        value: _autoDetect,
                        onChanged:
                            isConnected || _isProgramming
                                ? null
                                : (value) {
                                  setState(() => _autoDetect = value ?? false);
                                  _scheduleConfigSave();
                                },
                      ),
                      Text(AppStrings.probe.autoDetect),
                    ],
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AppDialogDropdown<ProbeWireProtocol>(
                        value: _wireProtocol,
                        hint: AppStrings.probe.interfaceHint,
                        labelText: AppStrings.probe.debugInterfaceLabel,
                        items:
                            ProbeWireProtocol.values
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item,
                                    child: Text(item.label),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            isConnected
                                ? null
                                : (value) {
                                  setState(
                                    () =>
                                        _wireProtocol = value ?? _wireProtocol,
                                  );
                                  _scheduleConfigSave();
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppLabeledField(
                        key: const ValueKey('rtt-clock-field-container'),
                        label: AppStrings.probe.debugClockLabel,
                        child: TextField(
                          key: const ValueKey('rtt-clock-field'),
                          controller: _clockController,
                          enabled: !isConnected,
                          keyboardType: TextInputType.number,
                          decoration: _connectionFieldDecoration(
                            suffixText: 'kHz',
                          ),
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
          onPressed:
              _connecting
                  ? (_cancellingConnection ? null : _cancelConnection)
                  : _close,
          child: Text(
            _connecting
                ? (_cancellingConnection
                    ? AppStrings.probe.cancelling
                    : AppStrings.probe.cancelConnect)
                : AppStrings.common.close,
          ),
        ),
        if (isConnected)
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
                      if (_isProgramming) {
                        await flashService!.disconnect();
                      } else {
                        await probeService.disconnect();
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
            icon: const Icon(Icons.stop),
            label: Text(AppStrings.serial.disconnect),
          )
        else
          ElevatedButton.icon(
            onPressed: _refreshing || _connecting ? null : _connect,
            icon: const Icon(Icons.link),
            label: Text(AppStrings.serial.connect),
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

bool _backendSupportsProbe(ProbeBackendSelection backend, ProbeKind kind) =>
    switch (backend) {
      ProbeBackendSelection.externalJlink => kind == ProbeKind.jlink,
      ProbeBackendSelection.bundledOpenocd ||
      ProbeBackendSelection.externalOpenocd ||
      ProbeBackendSelection.externalPyocd => kind == ProbeKind.cmsisDap,
      ProbeBackendSelection.automatic => true,
    };

ProbeBackendSelection _toProbeBackend(ProgrammingBackendSelection value) =>
    switch (value) {
      ProgrammingBackendSelection.automatic => ProbeBackendSelection.automatic,
      ProgrammingBackendSelection.externalJlink =>
        ProbeBackendSelection.externalJlink,
      ProgrammingBackendSelection.externalOpenocd =>
        ProbeBackendSelection.externalOpenocd,
      ProgrammingBackendSelection.bundledOpenocd =>
        ProbeBackendSelection.bundledOpenocd,
    };

ProgrammingBackendSelection _toProgrammingBackend(
  ProbeBackendSelection value,
) => switch (value) {
  ProbeBackendSelection.externalJlink =>
    ProgrammingBackendSelection.externalJlink,
  ProbeBackendSelection.externalOpenocd =>
    ProgrammingBackendSelection.externalOpenocd,
  ProbeBackendSelection.bundledOpenocd =>
    ProgrammingBackendSelection.bundledOpenocd,
  ProbeBackendSelection.automatic ||
  ProbeBackendSelection.externalPyocd => ProgrammingBackendSelection.automatic,
};

class _RttTargetSearchDialog extends StatefulWidget {
  const _RttTargetSearchDialog({required this.loadTargets});

  final Future<List<ProbeTargetInfo>> Function() loadTargets;

  @override
  State<_RttTargetSearchDialog> createState() => _RttTargetSearchDialogState();
}

class _RttTargetSearchDialogState extends State<_RttTargetSearchDialog> {
  late Future<List<ProbeTargetInfo>> _targetsFuture;
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
      title: Text(AppStrings.probe.selectTargetChipTitle),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('rtt-target-search-field'),
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: AppStrings.probe.targetSearchHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<List<ProbeTargetInfo>>(
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
                            AppStrings.probe.loadTargetListFailed(
                              '${snapshot.error}',
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh),
                            label: Text(AppStrings.probe.retry),
                          ),
                        ],
                      ),
                    );
                  }
                  final matches = (snapshot.data ?? const <ProbeTargetInfo>[])
                      .where((item) => _matchesTarget(item, _query))
                      .toList(growable: false);
                  if (matches.isEmpty) {
                    return Center(
                      child: Text(AppStrings.probe.noMatchingTargetChip),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.probe.matchedTargetCount(matches.length),
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
          child: Text(AppStrings.common.close),
        ),
      ],
    );
  }
}

bool _matchesTarget(ProbeTargetInfo target, String query) {
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
InputDecoration _connectionFieldDecoration({
  String? hintText,
  String? suffixText,
}) {
  return InputDecoration(
    hintText: hintText,
    suffixText: suffixText,
    isDense: true,
    constraints: const BoxConstraints.tightFor(
      height: kSecondaryDialogControlHeight,
    ),
    border: const OutlineInputBorder(),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );
}

Future<void> showProbeConnectionDialog(BuildContext context) async {
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ProbeConnectionDialog(),
    );
  } catch (error) {
    AppNotifications.show('打开探针连接窗口失败: $error');
  }
}
