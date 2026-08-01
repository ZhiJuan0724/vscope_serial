import 'package:flutter/foundation.dart';

/// 当前占用应用连接入口的会话类型。
///
/// 数据连接涵盖串口、TCP和UDP；探针连接涵盖RTT Viewer、RTT绘图和HSS。
enum ConnectionOwner { none, data, probe }

/// 应用级硬件连接所有权。
class ConnectionOwnerService extends ChangeNotifier {
  ConnectionOwnerService._();

  static final ConnectionOwnerService _instance = ConnectionOwnerService._();
  factory ConnectionOwnerService() => _instance;

  ConnectionOwner _owner = ConnectionOwner.none;

  ConnectionOwner get owner => _owner;

  bool tryAcquire(ConnectionOwner owner) {
    if (owner == ConnectionOwner.none) return false;
    if (_owner != ConnectionOwner.none && _owner != owner) return false;
    if (_owner == owner) return true;
    _owner = owner;
    notifyListeners();
    return true;
  }

  void release(ConnectionOwner owner) {
    if (_owner != owner) return;
    _owner = ConnectionOwner.none;
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    if (_owner == ConnectionOwner.none) return;
    _owner = ConnectionOwner.none;
    notifyListeners();
  }
}
