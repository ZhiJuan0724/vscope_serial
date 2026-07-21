import 'package:flutter/foundation.dart';

/// 当前占用应用硬件连接入口的传输类型。
///
/// 串口内部仍由 `SerialActivityOwner` 区分数据收发、Shell 和绘图；这里仅
/// 负责阻止串口与 RTT 探针同时连接，避免两个页面显示互相矛盾的连接状态。
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
