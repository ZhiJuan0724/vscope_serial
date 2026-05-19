import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:provider/provider.dart';

import '../../services/serial_service.dart';
import '../widgets/common_widgets.dart';

/// 状态栏点击弹出的连接修改对话框
class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key});

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  @override
  void initState() {
    super.initState();
    // 打开弹窗时自动刷新串口列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SerialService>().refreshPorts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SerialService>(
      builder: (context, service, child) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('串口连接'),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          content: SizedBox(
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
                        hint: '选择串口',
                        decoration: const InputDecoration(
                          labelText: '串口',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: service.availablePorts.map((port) {
                          return DropdownMenuItem(
                            value: port,
                            child: Text(port),
                          );
                        }).toList(),
                        onChanged: service.isConnected
                            ? null
                            : (value) {
                                service.config = service.config.copyWith(port: value);
                                // ignore: invalid_use_of_protected_member
                                service.notifyListeners();
                              },
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: service.isConnected ? null : () => service.refreshPorts(),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('刷新'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 波特率
                ComboInput(
                  value: service.config.baudRate.toString(),
                  hint: '波特率',
                  items: const [
                    '1200', '2400', '4800', '9600', '19200',
                    '38400', '57600', '115200', '230400',
                    '460800', '921600',
                  ],
                  enabled: !service.isConnected,
                  decoration: const InputDecoration(
                    labelText: '波特率',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (value) {
                    final rate = int.tryParse(value);
                    if (rate != null && rate > 0) {
                      service.config = service.config.copyWith(baudRate: rate);
                    }
                  },
                ),
                const SizedBox(height: 12),
                // 数据位、停止位、校验位
                Row(
                  children: [
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.dataBits,
                        hint: '数据位',
                        decoration: const InputDecoration(
                          labelText: '数据位',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: [5, 6, 7, 8].map((bits) {
                          return DropdownMenuItem(
                            value: bits,
                            child: Text('$bits'),
                          );
                        }).toList(),
                        onChanged: service.isConnected
                            ? null
                            : (value) {
                                service.config = service.config.copyWith(
                                    dataBits: value);
                                // ignore: invalid_use_of_protected_member
                                service.notifyListeners();
                              },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.stopBits,
                        hint: '停止位',
                        decoration: const InputDecoration(
                          labelText: '停止位',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: [1, 2].map((bits) {
                          return DropdownMenuItem(
                            value: bits,
                            child: Text('$bits'),
                          );
                        }).toList(),
                        onChanged: service.isConnected
                            ? null
                            : (value) {
                                service.config = service.config.copyWith(
                                    stopBits: value);
                                // ignore: invalid_use_of_protected_member
                                service.notifyListeners();
                              },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NoAnimDropdown<int>(
                        value: service.config.parity,
                        hint: '校验位',
                        decoration: const InputDecoration(
                          labelText: '校验位',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: SerialPortParity.none,
                            child: const Text('无校验'),
                          ),
                          DropdownMenuItem(
                            value: SerialPortParity.odd,
                            child: const Text('奇校验'),
                          ),
                          DropdownMenuItem(
                            value: SerialPortParity.even,
                            child: const Text('偶校验'),
                          ),
                        ],
                        onChanged: service.isConnected
                            ? null
                            : (value) {
                                service.config = service.config.copyWith(
                                    parity: value);
                                // ignore: invalid_use_of_protected_member
                                service.notifyListeners();
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
              child: const Text('关闭'),
            ),
            if (service.isConnected)
              ElevatedButton.icon(
                onPressed: () {
                  service.disconnect();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.stop),
                label: const Text('断开'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: () {
                  service.connect();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('连接'),
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
