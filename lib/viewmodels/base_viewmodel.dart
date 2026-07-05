import 'package:flutter/material.dart';

import '../services/serial_service.dart';

/// 基础 ViewModel
abstract class BaseViewModel extends ChangeNotifier {
  final SerialService serialService;
  bool _disposed = false;
  bool _serviceNotifyScheduled = false;

  BaseViewModel(this.serialService) {
    serialService.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    if (_disposed || _serviceNotifyScheduled) return;
    _serviceNotifyScheduled = true;
    Future.microtask(() {
      _serviceNotifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    serialService.removeListener(_onServiceChanged);
    super.dispose();
  }
}
