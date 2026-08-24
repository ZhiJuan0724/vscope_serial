import 'package:flutter/material.dart';

import '../services/data_connection_service.dart';

/// 基础 ViewModel
abstract class BaseViewModel extends ChangeNotifier {
  final DataConnectionService connectionService;
  bool _disposed = false;
  bool _serviceNotifyScheduled = false;

  BaseViewModel(this.connectionService) {
    connectionService.addListener(_onServiceChanged);
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
    connectionService.removeListener(_onServiceChanged);
    super.dispose();
  }
}
