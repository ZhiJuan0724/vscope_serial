import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/rtt_config.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/rtt_service.dart';
import '../widgets/common_widgets.dart';

class RttConnectionDialog extends StatefulWidget {
  const RttConnectionDialog({super.key});

  @override
  State<RttConnectionDialog> createState() => _RttConnectionDialogState();
}

class _RttConnectionDialogState extends State<RttConnectionDialog> {
  late RttProbeKind _kind;
  late RttWireProtocol _wireProtocol;
  late RttControlBlockMode _controlBlockMode;
  late bool _autoDetect;
  late String _probeId;
  late String _target;
  late final TextEditingController _targetController;
  late final TextEditingController _clockController;
  late final TextEditingController _addressController;
  late final TextEditingController _rangeStartController;
  late final TextEditingController _rangeEndController;
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

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _kind = RttProbeKind.fromString(settings.rttProbeKind);
    _wireProtocol = RttWireProtocol.fromString(settings.rttWireProtocol);
    _controlBlockMode = RttControlBlockMode.fromString(
      settings.rttControlBlockMode,
    );
    _autoDetect = settings.rttAutoDetectTarget;
    _probeId = settings.rttLastProbeId;
    _target = settings.rttTarget;
    _targetController = TextEditingController(text: _target);
    _clockController = TextEditingController(text: '${settings.rttClockKhz}');
    _addressController = TextEditingController(
      text:
          settings.rttControlBlockAddress == null
              ? ''
              : '0x${settings.rttControlBlockAddress!.toRadixString(16)}',
    );
    _rangeStartController = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeStart),
    );
    _rangeEndController = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeEnd),
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
    _addressController.dispose();
    _rangeStartController.dispose();
    _rangeEndController.dispose();
    super.dispose();
  }

  Future<void> _updateExpectedBackend() async {
    final generation = ++_backendPreviewGeneration;
    final kind = _kind;
    setState(() {
      _checkingExpectedBackend = true;
      _expectedBackendError = null;
    });
    try {
      final name = await context.read<RttService>().expectedBackendName(kind);
      if (!mounted ||
          generation != _backendPreviewGeneration ||
          kind != _kind) {
        return;
      }
      final mode = RttBackendMode.fromString(AppSettings().rttBackendMode);
      final suffix = switch (mode) {
        RttBackendMode.automatic when name == '内置 probe-rs' => '（自动回退）',
        RttBackendMode.automatic => '（自动选择）',
        _ => '',
      };
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
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final service = context.read<RttService>();
      final probes = await service.listProbes(kind);
      if (!mounted || generation != _refreshGeneration || kind != _kind) {
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
    final selected = await showDialog<RttTargetInfo>(
      context: context,
      builder:
          (_) => _RttTargetSearchDialog(
            loadTargets: () => context.read<RttService>().listTargets(kind),
          ),
    );
    if (!mounted || selected == null || kind != _kind) return;
    setState(() {
      _target = selected.name;
      _targetController.text = selected.name;
    });
  }

  int? _parseAddress(String input) {
    final value = input.trim();
    if (value.isEmpty) return null;
    return int.tryParse(
      value.startsWith('0x') || value.startsWith('0X')
          ? value.substring(2)
          : value,
      radix: value.startsWith('0x') || value.startsWith('0X') ? 16 : 10,
    );
  }

  Future<void> _connect() async {
    final clock = int.tryParse(_clockController.text.trim());
    if (clock == null || clock < 100 || clock > 50000) {
      setState(() => _error = '调试时钟范围为 100~50000 kHz');
      return;
    }
    if (!_autoDetect && _target.trim().isEmpty) {
      setState(() => _error = '请选择或输入目标芯片');
      return;
    }
    final addressText = _addressController.text.trim();
    final address = _parseAddress(addressText);
    final rangeStartText = _rangeStartController.text.trim();
    final rangeEndText = _rangeEndController.text.trim();
    final rangeStart = _parseAddress(rangeStartText);
    final rangeEnd = _parseAddress(rangeEndText);
    if (_controlBlockMode == RttControlBlockMode.address &&
        (address == null || address < 0)) {
      setState(() => _error = '请输入有效的 RTT 控制块地址');
      return;
    }
    if (_controlBlockMode == RttControlBlockMode.range &&
        (rangeStart == null ||
            rangeStart < 0 ||
            rangeEnd == null ||
            rangeEnd <= rangeStart)) {
      setState(() => _error = 'RTT 搜索范围无效，结束地址必须大于起始地址');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await context.read<RttService>().connect(
        RttConnectionConfig(
          probeKind: _kind,
          probeId: _probeId,
          target: _target.trim(),
          autoDetectTarget: _autoDetect,
          wireProtocol: _wireProtocol,
          clockKhz: clock,
          controlBlockMode: _controlBlockMode,
          // 非当前模式的输入也一并保留，用户切回该模式时无需重新填写。
          controlBlockAddress: address,
          controlBlockRangeStart: rangeStart,
          controlBlockRangeEnd: rangeEnd,
        ),
      );
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
      title: const Text('RTT 连接'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    value:
                        _probes.any((item) => item.id == _probeId)
                            ? _probeId
                            : null,
                    hint: '选择探针',
                    decoration: _connectionFieldDecoration('调试探针'),
                    items:
                        _probes
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.id,
                                enabled: item.available,
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                    onChanged:
                        service.isConnected
                            ? null
                            : (value) => setState(() => _probeId = value ?? ''),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新探针',
                  onPressed:
                      service.isConnected || _refreshing || _connecting
                          ? null
                          : () => unawaited(_refresh()),
                  icon:
                      _refreshing
                          ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.refresh),
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
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
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
                          : (value) =>
                              setState(() => _autoDetect = value ?? false),
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
            const SizedBox(height: 12),
            NoAnimDropdown<RttControlBlockMode>(
              value: _controlBlockMode,
              hint: '控制块定位',
              decoration: _connectionFieldDecoration('RTT 控制块定位'),
              items:
                  RttControlBlockMode.values
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
                      : (value) {
                        if (value == null) return;
                        setState(() => _controlBlockMode = value);
                      },
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _controlBlockMode.description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_controlBlockMode == RttControlBlockMode.address) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _addressController,
                enabled: !service.isConnected,
                decoration: _connectionFieldDecoration(
                  'RTT 控制块地址',
                  hintText: '例如 0x20000000',
                ),
              ),
            ],
            if (_controlBlockMode == RttControlBlockMode.range) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rangeStartController,
                      enabled: !service.isConnected,
                      decoration: _connectionFieldDecoration(
                        '搜索起始地址',
                        hintText: '例如 0x20000000',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rangeEndController,
                      enabled: !service.isConnected,
                      decoration: _connectionFieldDecoration(
                        '搜索结束地址',
                        hintText: '例如 0x20010000',
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
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

String _formatAddress(int? value) =>
    value == null ? '' : '0x${value.toRadixString(16)}';

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
    AppNotifications.show('打开 RTT 连接窗口失败: $error');
  }
}
