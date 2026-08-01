import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/serial_config.dart';
import '../../data/models/data_connection_config.dart';
import '../../services/app_settings.dart';
import '../../services/serial_service.dart';
import '../widgets/common_widgets.dart';

/// 打开串口连接配置窗口，供状态栏和主窗口快捷键共用。
Future<void> showSerialConnectionDialog(
  BuildContext context, {
  String pageId = 'rawData',
}) {
  return showDialog(
    context: context,
    builder: (context) => StatusDialog(pageId: pageId),
  );
}

/// 状态栏点击弹出的连接修改对话框
/// 串口连接配置和端口刷新窗口。
///
/// 默认只显示 COM 号；用户主动勾选详细信息后才在后台查询设备友好名称。
class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key, this.pageId = 'rawData'});
  final String pageId;

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  bool _showPortDetails = false;
  late DataConnectionType _connectionType;
  late NetworkConnectionConfig _networkConfig;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    final service = context.read<SerialService>();
    _connectionType =
        service.isConnectionBusy
            ? service.activeConnectionType
            : settings.connectionTypeForPage(widget.pageId);
    _networkConfig =
        service.isNetworkConnection && service.activeNetworkConfig != null
            ? service.activeNetworkConfig!
            : settings.networkConfigForPage(widget.pageId);
    service.selectSerialProfile(widget.pageId, notify: false);
    // 打开弹窗时自动刷新串口列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(context.read<SerialService>().refreshConnectionStatus());
    });
  }

  void _saveNetworkConfig(NetworkConnectionConfig value) {
    setState(() => _networkConfig = value);
    final settings = AppSettings();
    settings.saveNetworkConfigForPage(widget.pageId, value);
    unawaited(settings.save());
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
                if (AppSettings().networkConnectionsEnabled &&
                    widget.pageId != 'shell') ...[
                  NoAnimDropdown<DataConnectionType>(
                    value: _connectionType,
                    hint: '连接类型',
                    decoration: const InputDecoration(
                      labelText: '连接类型',
                      border: OutlineInputBorder(),
                    ),
                    items:
                        [
                              DataConnectionType.serial,
                              DataConnectionType.tcpClient,
                              if (widget.pageId == 'rawData')
                                DataConnectionType.tcpServer,
                              DataConnectionType.udp,
                            ]
                            .map(
                              (type) => DropdownMenuItem(
                                value: type,
                                child: Text(type.label),
                              ),
                            )
                            .toList(),
                    onChanged:
                        service.isConnectionBusy
                            ? null
                            : (value) {
                              if (value == null) return;
                              setState(() => _connectionType = value);
                              if (value == DataConnectionType.tcpServer &&
                                  _networkConfig.host == '127.0.0.1') {
                                _saveNetworkConfig(
                                  _networkConfig.copyWith(host: '0.0.0.0'),
                                );
                              }
                              final settings =
                                  AppSettings()..saveConnectionTypeForPage(
                                    widget.pageId,
                                    value,
                                  );
                              unawaited(settings.save());
                            },
                  ),
                  const SizedBox(height: 12),
                ],
                if (_connectionType == DataConnectionType.serial) ...[
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
                ] else ...[
                  TextFormField(
                    initialValue: _networkConfig.host,
                    enabled: !service.isConnectionBusy,
                    decoration: InputDecoration(
                      labelText:
                          _connectionType == DataConnectionType.tcpServer
                              ? '监听地址'
                              : '远端地址',
                      helperText:
                          _connectionType == DataConnectionType.tcpServer
                              ? '默认监听全部本机网络接口'
                              : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged:
                        (value) => _saveNetworkConfig(
                          _networkConfig.copyWith(host: value),
                        ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: _networkConfig.port.toString(),
                          enabled: !service.isConnectionBusy,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText:
                                _connectionType == DataConnectionType.tcpServer
                                    ? '监听端口'
                                    : '远端端口',
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (value) {
                            final port = int.tryParse(value);
                            if (port != null && port >= 1 && port <= 65535) {
                              _saveNetworkConfig(
                                _networkConfig.copyWith(port: port),
                              );
                            }
                          },
                        ),
                      ),
                      if (_connectionType == DataConnectionType.udp) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            initialValue:
                                _networkConfig.localPort?.toString() ?? '',
                            enabled: !service.isConnectionBusy,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '本地端口（可选）',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) {
                              final port = int.tryParse(value);
                              _saveNetworkConfig(
                                value.trim().isEmpty
                                    ? _networkConfig.copyWith(
                                      clearLocalPort: true,
                                    )
                                    : _networkConfig.copyWith(localPort: port),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
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
                    (_connectionType == DataConnectionType.serial
                            ? service.canConnectSelectedPort
                            : _networkConfig.host.trim().isNotEmpty &&
                                _networkConfig.port >= 1 &&
                                _networkConfig.port <= 65535)
                        ? () {
                          if (_connectionType == DataConnectionType.serial) {
                            service.connect();
                          } else {
                            final config = _networkConfig.copyWith(
                              type: _connectionType,
                              host:
                                  _connectionType ==
                                              DataConnectionType.tcpServer &&
                                          _networkConfig.host.trim().isEmpty
                                      ? '0.0.0.0'
                                      : _networkConfig.host.trim(),
                            );
                            _saveNetworkConfig(config);
                            service.connectNetwork(
                              config,
                              pageId: widget.pageId,
                            );
                          }
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
