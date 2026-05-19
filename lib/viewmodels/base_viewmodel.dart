import 'package:flutter/material.dart';

import '../services/serial_service.dart';

/// 基础 ViewModel
abstract class BaseViewModel extends ChangeNotifier {
  final SerialService serialService;

  BaseViewModel(this.serialService) {
    serialService.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    Future.microtask(() => notifyListeners());
  }

  @override
  void dispose() {
    serialService.removeListener(_onServiceChanged);
    super.dispose();
  }
}
