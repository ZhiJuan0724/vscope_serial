import 'package:flutter/foundation.dart';

/// 当前占用应用硬件连接入口的传输类型。
///
/// `serial`为兼容旧调用保留名称，实际代表串口/TCP/UDP数据连接；数据连接
/// 内部仍由 `SerialActivityOwner` 区分数据收发、Shell和绘图。
enum ConnectionOwner { none, serial, rtt }

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
