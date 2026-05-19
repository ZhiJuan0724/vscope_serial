import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/app_logger.dart';

/// 全部日志查看对话框
class LogDialog extends StatefulWidget {
  const LogDialog({super.key});

  @override
  State<LogDialog> createState() => _LogDialogState();
}

class _LogDialogState extends State<LogDialog> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppLogger>(
      builder: (context, logger, child) {
        final logs = logger.rawLogs.toList().reversed.toList();
        final filteredLogs = logger.showTraceLogs
            ? logs
            : logs.where((e) => e.level != 'TRACE').toList();
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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
                    // 调试日志勾选框
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: logger.showTraceLogs,
                          onChanged: (value) {
                            logger.setShowTraceLogs(value!);
                          },
                        ),
                        const Text('调试日志'),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '共 ${filteredLogs.length} 条',
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
                  child: filteredLogs.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无日志',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          reverse: false,
                          itemCount: filteredLogs.length,
                          itemBuilder: (context, index) {
                            final log = filteredLogs[index];
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
      case 'TRACE':
        levelColor = Colors.grey;
        break;
      case 'DEBUG':
        levelColor = Colors.blue;
        break;
      case 'INFO':
        levelColor = Colors.green;
        break;
      case 'WARNING':
        levelColor = Colors.orange;
        break;
      case 'ERROR':
      case 'FATAL':
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
