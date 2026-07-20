import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/serial_config.dart';
import '../../services/serial_service.dart';
import '../widgets/common_widgets.dart';

/// 状态栏点击弹出的连接修改对话框
/// 串口连接配置和端口刷新窗口。
///
/// 默认只显示 COM 号；用户主动勾选详细信息后才在后台查询设备友好名称。
class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key});

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  bool _showPortDetails = false;

  @override
  void initState() {
    super.initState();
    // 打开弹窗时自动刷新串口列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(context.read<SerialService>().refreshConnectionStatus());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SerialService>(
      builder: (context, service, child) {
        final selectedPort = service.config.port;
        final displayedPorts =
            <String>{
              if (selectedPort != null) selectedPort,
              ...service.availablePorts,
            }.toList();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: Text(AppStrings.serial.connectionTitle),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          content: SizedBox(
            key: const ValueKey('serial-dialog-content'),
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 串口选择 + 刷新
                Row(
                  children: [
                    Expanded(
                      child: NoAnimDropdown<String>(
                        value: service.config.port,
                        hint: AppStrings.serial.selectPortHint,
                        decoration: InputDecoration(
                          labelText: AppStrings.serial.port,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            displayedPorts.map((port) {
                              final displayLabel = service.portDisplayLabel(
                                port,
                                showDetails: _showPortDetails,
                              );
                              final unavailable = service.isPortUnavailable(
                                port,
                              );
                              return DropdownMenuItem(
                                value: port,
                                child: Text(
                                  unavailable
                                      ? AppStrings.serial.portUnavailable(
                                        displayLabel,
                                      )
                                      : displayLabel,
                                ),
                              );
                            }).toList(),
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) {
                                  service.updateConfig(
                                    service.config.copyWith(port: value),
                                  );
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed:
                          service.isRefreshingPorts
                              ? null
                              : () => unawaited(
                                _showPortDetails
                                    ? service.refreshPortsWithDetails()
                                    : service.refreshPorts(reason: '用户手动刷新'),
                              ),
                      icon:
                          service.isRefreshingPorts
                              ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.refresh, size: 18),
                      label: Text(AppStrings.common.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 波特率 + 串口详细信息
                Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('baud-rate-field-container'),
                      width: 220,
                      child: ComboInput(
                        value: service.config.baudRate.toString(),
                        hint: AppStrings.serial.baudRate,
                        items: const [
                          '9600',
                          '19200',
                          '38400',
                          '57600',
                          '115200',
                          '230400',
                          '460800',
                          '512000',
                          '921600',
                          '1152000',
                        ],
                        enabled: !service.isConnected,
                        decoration: InputDecoration(
                          labelText: AppStrings.serial.baudRate,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        onChanged: (value) {
                          final rate = int.tryParse(value);
                          if (rate != null && rate > 0) {
                            service.updateConfig(
                              service.config.copyWith(baudRate: rate),
                            );
                          }
                        },
                      ),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          key: const ValueKey('show-port-details-checkbox'),
                          value: _showPortDetails,
                          visualDensity: VisualDensity.compact,
                          onChanged: (value) {
                            setState(() => _showPortDetails = value ?? false);
                          },
                        ),
                        Text(
                          AppStrings.serial.showPortDetails,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 数据位、停止位、校验位
                Row(
                  children: [
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.dataBits,
                        hint: AppStrings.serial.dataBits,
                        decoration: InputDecoration(
                          labelText: AppStrings.serial.dataBits,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            [5, 6, 7, 8].map((bits) {
                              return DropdownMenuItem(
                                value: bits,
                                child: Text('$bits'),
                              );
                            }).toList(),
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) {
                                  service.updateConfig(
                                    service.config.copyWith(dataBits: value),
                                  );
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.stopBits,
                        hint: AppStrings.serial.stopBits,
                        decoration: InputDecoration(
                          labelText: AppStrings.serial.stopBits,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items:
                            [1, 2].map((bits) {
                              return DropdownMenuItem(
                                value: bits,
                                child: Text('$bits'),
                              );
                            }).toList(),
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) {
                                  service.updateConfig(
                                    service.config.copyWith(stopBits: value),
                                  );
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.parity,
                        hint: AppStrings.serial.parity,
                        decoration: InputDecoration(
                          labelText: AppStrings.serial.parity,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: SerialParity.none,
                            child: Text(AppStrings.serial.noParity),
                          ),
                          DropdownMenuItem(
                            value: SerialParity.odd,
                            child: Text(AppStrings.serial.oddParity),
                          ),
                          DropdownMenuItem(
                            value: SerialParity.even,
                            child: Text(AppStrings.serial.evenParity),
                          ),
                        ],
                        onChanged:
                            service.isConnected
                                ? null
                                : (value) {
                                  service.updateConfig(
                                    service.config.copyWith(parity: value),
                                  );
                                },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // RTS / DTR
                Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: service.config.rts,
                          onChanged: (value) => service.updateRts(value!),
                        ),
                        const Text('RTS'),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: service.config.dtr,
                          onChanged: (value) => service.updateDtr(value!),
                        ),
                        const Text('DTR'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppStrings.common.close),
            ),
            if (service.isConnecting)
              ElevatedButton.icon(
                onPressed: null,
                icon: const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                label: Text(AppStrings.status.connecting),
              )
            else if (service.isConnected)
              ElevatedButton.icon(
                onPressed: () async {
                  await service.disconnect();
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.stop),
                label: Text(AppStrings.serial.disconnect),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              )
            else
              ElevatedButton.icon(
                onPressed:
                    service.canConnectSelectedPort
                        ? () {
                          service.connect();
                          Navigator.of(context).pop();
                        }
                        : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(AppStrings.serial.connect),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
          ],
        );
      },
    );
  }
}
