import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/rtt_configuration.dart';
import '../../data/models/rtt_config.dart';
import '../../services/app_settings.dart';
import '../../services/rtt_service.dart';
import '../widgets/common_widgets.dart';

Future<void> showRttControlBlockDialog(
  BuildContext context, {
  required RttService service,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RttControlBlockDialog(service: service, title: title),
  );
}

class _RttControlBlockDialog extends StatefulWidget {
  const _RttControlBlockDialog({required this.service, required this.title});

  final RttService service;
  final String title;

  @override
  State<_RttControlBlockDialog> createState() => _RttControlBlockDialogState();
}

class _RttControlBlockDialogState extends State<_RttControlBlockDialog> {
  late RttControlBlockMode _mode;
  late final TextEditingController _address;
  late final TextEditingController _rangeStart;
  late final TextEditingController _rangeEnd;
  late final TextEditingController _pollingInterval;
  String? _error;

  bool get _supportsAutomatic => widget.service.supportsAutomaticControlBlock;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _mode = RttControlBlockMode.fromString(settings.rttControlBlockMode);
    if (!_supportsAutomatic && _mode == RttControlBlockMode.automatic) {
      _mode = RttControlBlockMode.address;
    }
    _address = TextEditingController(
      text: _formatAddress(settings.rttControlBlockAddress),
    );
    _rangeStart = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeStart),
    );
    _rangeEnd = TextEditingController(
      text: _formatAddress(settings.rttControlBlockRangeEnd),
    );
    _pollingInterval = TextEditingController(
      text: '${settings.rttViewerPollingIntervalMs}',
    );
  }

  @override
  void dispose() {
    _address.dispose();
    _rangeStart.dispose();
    _rangeEnd.dispose();
    _pollingInterval.dispose();
    super.dispose();
  }

  void _save() {
    final address = _parseAddress(_address.text);
    final start = _parseAddress(_rangeStart.text);
    final end = _parseAddress(_rangeEnd.text);
    final pollingInterval = int.tryParse(_pollingInterval.text);
    if (_mode == RttControlBlockMode.address &&
        (address == null || address < 0)) {
      setState(() => _error = '请输入有效的 RTT 控制块地址');
      return;
    }
    if (pollingInterval == null ||
        pollingInterval < RttConfiguration.minPollingIntervalMs ||
        pollingInterval > RttConfiguration.maxPollingIntervalMs) {
      setState(
        () =>
            _error =
                'RTT 轮询间隔必须为 '
                '${RttConfiguration.minPollingIntervalMs}～'
                '${RttConfiguration.maxPollingIntervalMs} ms',
      );
      return;
    }
    if (_mode == RttControlBlockMode.range &&
        (start == null || start < 0 || end == null || end <= start)) {
      setState(() => _error = '搜索结束地址必须大于起始地址');
      return;
    }
    final settings =
        AppSettings()
          ..rttControlBlockMode = _mode.value
          ..rttControlBlockAddress = address
          ..rttControlBlockRangeStart = start
          ..rttControlBlockRangeEnd = end
          ..rttViewerPollingIntervalMs = pollingInterval;
    unawaited(settings.save());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NoAnimDropdown<RttControlBlockMode>(
              key: const ValueKey('rtt-activity-control-block-mode'),
              value: _mode,
              hint: '控制块定位',
              decoration: secondaryDialogFieldDecoration(
                labelText: 'RTT 控制块定位',
              ),
              items:
                  RttControlBlockMode.values
                      .where(
                        (value) =>
                            _supportsAutomatic ||
                            value != RttControlBlockMode.automatic,
                      )
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _mode = value);
              },
            ),
            const SizedBox(height: 6),
            Text(
              _mode.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (_mode == RttControlBlockMode.address) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('rtt-activity-control-block-address'),
                controller: _address,
                decoration: secondaryDialogFieldDecoration(
                  labelText: 'RTT 控制块地址',
                  hintText: '例如 0x20000410',
                ),
              ),
            ],
            if (_mode == RttControlBlockMode.range) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('rtt-activity-range-start'),
                      controller: _rangeStart,
                      decoration: secondaryDialogFieldDecoration(
                        labelText: '搜索起始地址',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('rtt-activity-range-end'),
                      controller: _rangeEnd,
                      decoration: secondaryDialogFieldDecoration(
                        labelText: '搜索结束地址',
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('rtt-activity-polling-interval'),
              controller: _pollingInterval,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: secondaryDialogFieldDecoration(
                labelText: 'RTT 轮询间隔',
                suffixText: 'ms',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '仅 OpenOCD 后端使用；J-Link 不传递此参数。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('确定')),
      ],
    );
  }
}

int? _parseAddress(String value) {
  final text = value.trim();
  final hex = text.startsWith('0x') || text.startsWith('0X');
  return int.tryParse(hex ? text.substring(2) : text, radix: hex ? 16 : 10);
}

String _formatAddress(int? value) =>
    value == null ? '' : '0x${value.toRadixString(16)}';
