import 'dart:async';

/// 串行化串口连接生命周期，并唯一持有连接 generation 与 single-flight 状态。
///
/// 具体的端口打开、关闭和健康检查仍由调用方实现；本类只保证这些异步操作
/// 不会重叠，并让较早连接请求可以通过 [isCurrent] 识别自己已经失效。
class SerialConnectionCoordinator {
  Future<void> _tail = Future<void>.value();
  Future<void>? _connectFuture;
  int? _connectFutureGeneration;
  Future<void>? _ioDisconnectFuture;
  Future<void>? _shutdownFuture;
  int _generation = 0;
  bool _isShuttingDown = false;

  int get generation => _generation;
  bool get isShuttingDown => _isShuttingDown;

  /// 创建新的连接意图，并立即使之前尚未完成的意图失效。
  int nextGeneration() => ++_generation;

  /// 使当前连接意图失效，但不创建新的连接。
  void invalidate() => _generation++;

  bool isCurrent(int generation) =>
      !_isShuttingDown && generation == _generation;

  /// 将操作追加到连接生命周期队列，并把错误交还给本次调用者。
  Future<T> enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// 启动连接操作；同一 generation 内的重复请求共享一个 Future。
  Future<void> connect({
    required void Function() onStart,
    required Future<void> Function(int generation) operation,
  }) {
    if (_isShuttingDown) return Future<void>.value();
    final existing = _connectFuture;
    if (existing != null && _connectFutureGeneration == _generation) {
      return existing;
    }

    final generation = nextGeneration();
    onStart();
    late final Future<void> future;
    future = enqueue(() => operation(generation)).whenComplete(() {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
        _connectFutureGeneration = null;
      }
    });
    _connectFuture = future;
    _connectFutureGeneration = generation;
    return future;
  }

  /// 立即使连接意图失效，再按队列顺序执行断开。
  Future<void> disconnect(Future<void> Function() operation) {
    invalidate();
    return enqueue(operation);
  }

  /// 合并由并发读写错误触发的重复断开请求。
  Future<void> disconnectFromIo(Future<void> Function() operation) {
    final existing = _ioDisconnectFuture;
    if (existing != null) return existing;

    invalidate();
    late final Future<void> future;
    future = enqueue(operation).whenComplete(() {
      if (identical(_ioDisconnectFuture, future)) {
        _ioDisconnectFuture = null;
      }
    });
    _ioDisconnectFuture = future;
    return future;
  }

  /// 永久拒绝新的连接意图，并合并重复的应用退出请求。
  Future<void> shutdown(Future<void> Function() operation) {
    final existing = _shutdownFuture;
    if (existing != null) return existing;

    _isShuttingDown = true;
    invalidate();
    final future = enqueue(operation);
    _shutdownFuture = future;
    return future;
  }
}
