import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_logger.dart';

/// 全部日志查看对话框
class LogDialog extends StatelessWidget {
  const LogDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppLogger>(
      builder: (context, logger, child) {
        final logs = logger.allLogs.toList().reversed.toList();
        return Dialog(
          child: Container(
            width: 800,
            height: 600,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题栏
                Row(
                  children: [
                    const Text(
                      '日志',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '共 ${logs.length} 条',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                const Divider(),
                // 日志列表
                Expanded(
                  child: logs.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无日志',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          reverse: false,
                          itemCount: logs.length,
                          itemBuilder: (context, index) {
                            final log = logs[index];
                            return _buildLogItem(context, log);
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogItem(BuildContext context, LogEntry log) {
    final levelFull = LogEntry.levelFullName(log.level);
    Color levelColor;
    switch (log.level) {
      case 'T':
        levelColor = Colors.grey;
        break;
      case 'D':
        levelColor = Colors.blue;
        break;
      case 'I':
        levelColor = Colors.green;
        break;
      case 'W':
        levelColor = Colors.orange;
        break;
      case 'E':
      case 'F':
        levelColor = Colors.red;
        break;
      default:
        levelColor = Colors.grey;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间
          SizedBox(
            width: 90,
            child: Text(
              _formatTime(log.timestamp),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // 级别
          SizedBox(
            width: 70,
            child: Text(
              levelFull,
              style: TextStyle(
                fontSize: 11,
                color: levelColor,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // 分类
          if (log.category != null)
            SizedBox(
              width: 70,
              child: Text(
                log.category!,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.blueGrey,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          // 消息
          Expanded(
            child: Text(
              log.message,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
