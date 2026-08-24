import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/rtt_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../data/models/probe_connection_config.dart';
import '../../services/app_settings.dart';
import '../../services/probe_connection_service.dart';
import '../widgets/common_widgets.dart';

Future<void> showRttControlBlockDialog(
  BuildContext context, {
  required ProbeConnectionService service,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RttControlBlockDialog(service: service, title: title),
  );
}

class _RttControlBlockDialog extends StatefulWidget {
  const _RttControlBlockDialog({required this.service, required this.title});

  final ProbeConnectionService service;
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
      setState(() => _error = AppStrings.probe.invalidControlBlockAddress);
      return;
    }
    if (pollingInterval == null ||
        pollingInterval < RttConfiguration.minPollingIntervalMs ||
        pollingInterval > RttConfiguration.maxPollingIntervalMs) {
      setState(
        () =>
            _error = AppStrings.probe.pollingIntervalRange(
              min: RttConfiguration.minPollingIntervalMs,
              max: RttConfiguration.maxPollingIntervalMs,
            ),
      );
      return;
    }
    if (_mode == RttControlBlockMode.range &&
        (start == null || start < 0 || end == null || end <= start)) {
      setState(() => _error = AppStrings.probe.rangeEndMustExceedStart);
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
            AppLabeledField(
              label: AppStrings.probe.controlBlockPositioning,
              child: NoAnimDropdown<RttControlBlockMode>(
                key: const ValueKey('rtt-activity-control-block-mode'),
                value: _mode,
                hint: AppStrings.probe.controlBlockPositioningHint,
                decoration: secondaryDialogFieldDecoration(),
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
              AppLabeledField(
                label: AppStrings.probe.controlBlockAddressLabel,
                child: TextField(
                  key: const ValueKey('rtt-activity-control-block-address'),
                  controller: _address,
                  decoration: secondaryDialogFieldDecoration(
                    hintText: AppStrings.probe.controlBlockAddressHint,
                  ),
                ),
              ),
            ],
            if (_mode == RttControlBlockMode.range) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: AppLabeledField(
                      label: AppStrings.probe.rangeStartLabel,
                      child: TextField(
                        key: const ValueKey('rtt-activity-range-start'),
                        controller: _rangeStart,
                        decoration: secondaryDialogFieldDecoration(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppLabeledField(
                      label: AppStrings.probe.rangeEndLabel,
                      child: TextField(
                        key: const ValueKey('rtt-activity-range-end'),
                        controller: _rangeEnd,
                        decoration: secondaryDialogFieldDecoration(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            AppLabeledField(
              label: AppStrings.probe.pollingIntervalLabel,
              child: TextField(
                key: const ValueKey('rtt-activity-polling-interval'),
                controller: _pollingInterval,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: secondaryDialogFieldDecoration(suffixText: 'ms'),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.probe.controlBlockPollingIntervalHelp,
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
          child: Text(AppStrings.common.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(AppStrings.common.confirm)),
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
