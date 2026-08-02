import 'package:flutter/material.dart';

import '../../services/app_notifications.dart';
import 'probe_connection_dialog.dart';

/// Flash与RTT共用同一套探针枚举和目标配置界面。
///
/// [ProbeConnectionDialog] 的Flash模式只复用表单与只读枚举能力；点击连接
/// 后创建的是独立FlashProgrammingService后端，不会复用RTT监控会话。
Future<void> showFlashConnectionDialog(BuildContext context) async {
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ProbeConnectionDialog(forFlashProgramming: true),
    );
  } catch (error) {
    AppNotifications.show('打开Flash连接窗口失败: $error');
  }
}
