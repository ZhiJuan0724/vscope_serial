import 'package:flutter/material.dart';

import '../services/serial_service.dart';

/// 基础 ViewModel
abstract class BaseViewModel extends ChangeNotifier {
  final SerialService serialService;
  bool _disposed = false;

  BaseViewModel(this.serialService) {
    serialService.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    if (_disposed) return;
    Future.microtask(() {
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
