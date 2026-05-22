import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/serial_service.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../dialogs/status_dialog.dart';

/// 底部共享状态栏
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<SerialService, PlotViewModel>(
      builder: (context, service, plotVm, child) {
        final message = plotVm.hintText;
        return Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
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
                    if (plotVm.useRandomSource) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.auto_graph,
                        size: 13,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '随机源',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
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
              const SizedBox(width: 12),
              Expanded(
                child:
                    message.isEmpty
                        ? const SizedBox.shrink()
                        : Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Icon(
                              _messageIcon(message),
                              size: 13,
                              color: _messageColor(context, message),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                message,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _messageColor(context, message),
                                ),
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

  void _showStatusDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => const StatusDialog());
  }

  IconData _messageIcon(String message) {
    if (message.contains('无法') ||
        message.contains('失败') ||
        message.contains('未连接') ||
        message.contains('请选择')) {
      return Icons.warning_amber_rounded;
    }
    return Icons.info_outline;
  }

  Color _messageColor(BuildContext context, String message) {
    if (message.contains('无法') ||
        message.contains('失败') ||
        message.contains('未连接') ||
        message.contains('请选择')) {
      return Colors.orange.shade800;
    }
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}
