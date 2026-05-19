import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/serial_service.dart';
import '../dialogs/status_dialog.dart';

/// 底部共享状态栏
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SerialService>(
      builder: (context, service, child) {
        return Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          child: Row(
            children: [
              // 串口状态（可点击弹窗）
              InkWell(
                onTap: () => _showStatusDialog(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: service.isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      service.isConnected ? '已连接' : '未连接',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (service.isConnected && service.config.port != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        '(${service.config.port})',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    Icon(
                      Icons.edit,
                      size: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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

  void _showStatusDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const StatusDialog(),
    );
  }
}
