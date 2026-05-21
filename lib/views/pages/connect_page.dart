import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:provider/provider.dart';

import '../../services/app_settings.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/connect_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 连接页面
class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SerialService>(context, listen: false);
    return ChangeNotifierProvider(
      create: (_) => ConnectViewModel(service),
      child: const _ConnectPageContent(),
    );
  }
}

class _ConnectPageContent extends StatefulWidget {
  const _ConnectPageContent();

  @override
  State<_ConnectPageContent> createState() => _ConnectPageContentState();
}

class _ConnectPageContentState extends State<_ConnectPageContent> {
  bool _settingsLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_settingsLoaded) {
      _settingsLoaded = true;
      _loadLastPort();
    }
  }

  void _loadLastPort() {
    final vm = Provider.of<ConnectViewModel>(context, listen: false);
    final settings = AppSettings();
    vm.serialService.loadSettings();
    // 刷新串口列表，检查上次连接的串口是否仍然可用
    vm.refreshPorts();
    final lastPort = settings.lastPort;
    if (lastPort != null && vm.availablePorts.contains(lastPort)) {
      vm.selectPort(lastPort);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectViewModel>(
      builder: (context, vm, child) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionTitle('串口'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: NoAnimDropdown<String>(
                      value: vm.selectedPort,
                      hint: '选择串口',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: vm.availablePorts.map((port) {
                        return DropdownMenuItem(
                          value: port,
                          child: Text(port),
                        );
                      }).toList(),
                      onChanged: vm.isConnected
                          ? null
                          : (value) => vm.selectPort(value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: vm.isConnected ? null : () => vm.refreshPorts(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新'),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              _buildSectionTitle('通信参数'),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 500;
                  if (isWide) {
                    return Row(
                      children: [
                        Expanded(child: _buildBaudRateCombo(vm)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildDataBitsDropdown(vm)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildStopBitsDropdown(vm)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildParityDropdown(vm)),
                      ],
                    );
                  } else {
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(child: _buildBaudRateCombo(vm)),
                            const SizedBox(width: 8),
                            Expanded(child: _buildDataBitsDropdown(vm)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(child: _buildStopBitsDropdown(vm)),
                            const SizedBox(width: 8),
                            Expanded(child: _buildParityDropdown(vm)),
                          ],
                        ),
                      ],
                    );
                  }
                },
              ),
              const SizedBox(height: 24),

              _buildSectionTitle('高级设置'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: vm.rts,
                          onChanged: (value) => vm.setRts(value!),
                        ),
                        const Text('RTS'),
                      ],
                    ),
                    const SizedBox(width: 24),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: vm.dtr,
                          onChanged: (value) => vm.setDtr(value!),
                        ),
                        const Text('DTR'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: vm.isConnecting
                      ? null
                      : (vm.isConnected ? vm.disconnect : vm.connect),
                  icon: vm.isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          vm.isConnected ? Icons.stop : Icons.play_arrow,
                          size: 24,
                        ),
                  label: Text(
                    vm.isConnecting
                        ? '打开中...'
                        : (vm.isConnected ? '断开连接' : '连接串口'),
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: vm.isConnected
                        ? Colors.red
                        : (vm.isConnecting ? Colors.orange : Colors.green),
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: vm.isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      vm.isConnected
                          ? '已连接: ${vm.selectedPort} @ ${vm.baudRate}'
                          : '未连接',
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildBaudRateCombo(ConnectViewModel vm) {
    return ComboInput(
      value: vm.baudRate.toString(),
      hint: '波特率',
      items: const [
        '9600', '19200', '38400', '57600', '115200',
        '230400', '460800', '512000', '921600', '1152000',
      ],
      enabled: !vm.isConnected,
      decoration: const InputDecoration(
        labelText: '波特率',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onChanged: (value) {
        final rate = int.tryParse(value);
        if (rate != null && rate > 0) {
          vm.setBaudRate(rate);
        }
      },
    );
  }

  Widget _buildDataBitsDropdown(ConnectViewModel vm) {
    return NoAnimDropdown<int>(
      value: vm.dataBits,
      hint: '数据位',
      decoration: const InputDecoration(
        labelText: '数据位',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: [5, 6, 7, 8].map((bits) {
        return DropdownMenuItem(
          value: bits,
          child: Text('$bits'),
        );
      }).toList(),
      onChanged: vm.isConnected
          ? null
          : (value) => vm.setDataBits(value!),
    );
  }

  Widget _buildStopBitsDropdown(ConnectViewModel vm) {
    return NoAnimDropdown<int>(
      value: vm.stopBits,
      hint: '停止位',
      decoration: const InputDecoration(
        labelText: '停止位',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: [1, 2].map((bits) {
        return DropdownMenuItem(
          value: bits,
          child: Text('$bits'),
        );
      }).toList(),
      onChanged: vm.isConnected
          ? null
          : (value) => vm.setStopBits(value!),
    );
  }

  Widget _buildParityDropdown(ConnectViewModel vm) {
    return NoAnimDropdown<int>(
      value: vm.parity,
      hint: '校验位',
      decoration: const InputDecoration(
        labelText: '校验位',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
      onChanged: vm.isConnected
          ? null
          : (value) => vm.setParity(value!),
    );
  }
}
