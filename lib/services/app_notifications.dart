import 'package:flutter/material.dart';

/// Application-wide transient notifications.
class AppNotifications {
  AppNotifications._();

  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static String? lastMessage;
  static String? _lastShownMessage;
  static DateTime? _lastShownAt;
  static const Duration _duplicateSuppressWindow = Duration(seconds: 2);

  static void show(
    String message, {
    Duration duration = const Duration(seconds: 2),
    ScaffoldMessengerState? messenger,
  }) {
    lastMessage = message;
    final state = messenger ?? _currentMessenger();
    if (state == null) return;

    final now = DateTime.now();
    if (_lastShownMessage == message &&
        _lastShownAt != null &&
        now.difference(_lastShownAt!) < _duplicateSuppressWindow) {
      return;
    }
    _lastShownMessage = message;
    _lastShownAt = now;

    final isWarning = _isWarning(message);
    state
      ..clearSnackBars()
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
