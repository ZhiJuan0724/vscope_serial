import 'dart:async';

import '../core/utils/app_logger.dart';

typedef PortEnumerator = Future<List<String>> Function();

/// 串口目录缓存。
///
/// 底层枚举必须在 UI isolate 之外执行。本类负责合并并发刷新、保留最后一次
/// 成功结果，并允许业务流程在等待超时后继续运行。
class SerialPortCatalog {
  SerialPortCatalog({
    required PortEnumerator enumerator,
    required void Function() onChanged,
  }) : _enumerator = enumerator,
       _onChanged = onChanged;

  final PortEnumerator _enumerator;
  final void Function() _onChanged;

  List<String> _ports = const [];
  bool _isRefreshing = false;
  DateTime? _lastSuccessAt;
  Duration? _lastDuration;
  String? _lastError;
  Future<bool>? _pendingRefresh;

  List<String> get ports => _ports;
  bool get isRefreshing => _isRefreshing;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  Duration? get lastDuration => _lastDuration;
  String? get lastError => _lastError;

  Future<bool> refresh({
    required String reason,
    Duration waitTimeout = const Duration(seconds: 2),
  }) {
    final existing = _pendingRefresh;
    if (existing != null) {
      return _waitFor(existing, waitTimeout, reason);
    }

    final stopwatch = Stopwatch()..start();
    _isRefreshing = true;
    _lastError = null;
    _onChanged();
    AppLogger().info('开始刷新串口列表：原因=$reason', category: 'SERIAL');

    late final Future<bool> operation;
    operation = Future<List<String>>.sync(_enumerator)
        .then((ports) {
          _ports = List<String>.unmodifiable(ports);
          _lastSuccessAt = DateTime.now();
          _lastDuration = stopwatch.elapsed;
          AppLogger().info(
            '串口列表刷新完成：耗时=${stopwatch.elapsedMilliseconds}ms，'
            '数量=${ports.length}，端口=${ports.isEmpty ? "<无>" : ports.join(",")}',
            category: 'SERIAL',
          );
          if (stopwatch.elapsed >= const Duration(seconds: 1)) {
            AppLogger().warning(
              '串口枚举耗时较长：${stopwatch.elapsedMilliseconds}ms',
              category: 'SERIAL',
            );
          }
          return true;
        })
        .catchError((Object error, StackTrace stack) {
          _lastDuration = stopwatch.elapsed;
          _lastError = error.toString();
          AppLogger().warning(
            '刷新串口列表失败：原因=$reason，'
            '耗时=${stopwatch.elapsedMilliseconds}ms，错误=$error',
            category: 'SERIAL',
          );
          return false;
        })
        .whenComplete(() {
          stopwatch.stop();
          if (identical(_pendingRefresh, operation)) {
            _pendingRefresh = null;
            _isRefreshing = false;
            _onChanged();
          }
        });
    _pendingRefresh = operation;
    return _waitFor(operation, waitTimeout, reason);
  }

  Future<bool> _waitFor(
    Future<bool> operation,
    Duration timeout,
    String reason,
  ) async {
    try {
      return await operation.timeout(timeout);
    } on TimeoutException {
      AppLogger().warning(
        '等待串口列表超时：原因=$reason，等待=${timeout.inMilliseconds}ms；'
        '后台枚举将继续，保留现有端口列表',
        category: 'SERIAL',
      );
      return false;
    }
  }
}
