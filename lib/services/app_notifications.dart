import 'package:flutter/material.dart';

/// Application-wide transient notifications.
class AppNotifications {
  AppNotifications._();

  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static String? lastMessage;

  static void show(
    String message, {
    Duration duration = const Duration(seconds: 4),
    ScaffoldMessengerState? messenger,
  }) {
    lastMessage = message;
    final state = messenger ?? _currentMessenger();
    if (state == null) return;

    final isWarning = _isWarning(message);
    state
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          duration:
              duration > Duration.zero ? duration : const Duration(days: 1),
          behavior: SnackBarBehavior.floating,
          backgroundColor: isWarning ? Colors.orange.shade800 : null,
        ),
      );
  }

  static bool _isWarning(String message) {
    const warningWords = ['失败', '无法', '断开', '错误', '请输入', '请选择'];
    return warningWords.any(message.contains);
  }

  static ScaffoldMessengerState? _currentMessenger() {
    try {
      return scaffoldMessengerKey.currentState;
    } on FlutterError {
      return null;
    }
  }
}
