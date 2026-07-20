import 'dart:async';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/data_source_config.dart';
import '../data/models/parse_result.dart';
import '../data/parser/data_parser.dart';
import '../data/source/data_source_manager.dart';
import '../services/serial_service.dart';

typedef PlotSessionPrepare = Future<bool> Function(int generation);
typedef PlotSessionData =
    void Function(List<ParseResult> results, DateTime receivedAt);

/// 绘图解析链和数据源的唯一生命周期所有者。
///
/// 页面门面负责业务预检与历史状态；本类负责 single-flight start/stop、
/// session generation、parser、数据订阅和 DataSourceManager 的释放顺序。
class PlotSessionController {
  PlotSessionController(
    SerialService serialService, {
    required void Function() onStateChanged,
  }) : _sourceManager = DataSourceManager(serialService),
       _onStateChanged = onStateChanged;

  final DataSourceManager _sourceManager;
  final void Function() _onStateChanged;

  IDataParser? _parser;
  // 订阅跨 start/stop 持有，并由 _cleanupResources 统一 cancel。
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _subscription;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  int _generation = 0;
  bool _isStarting = false;
  bool _isStopping = false;
  bool _isRunning = false;
  bool _disposed = false;

  bool get isStarting => _isStarting;
  bool get isStopping => _isStopping;
  bool get isRunning => _isRunning;
  Future<void>? get pendingStart => _startFuture;
  Future<void>? get pendingStop => _stopFuture;

  /// 仅供不启动真实数据源的 ViewModel 单元测试模拟运行状态。
  void debugSetRunning(bool value) {
    _isRunning = value;
  }

  bool isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> updateConfig(DataSourceConfig config) =>
      _sourceManager.updateConfig(config);

  Future<void> updateRandomFrequency(double frequencyHz) =>
      _sourceManager.updateRandomFrequency(frequencyHz);

  Future<void> start({
    required DataSourceConfig config,
    required PlotSessionPrepare prepare,
    required IDataParser Function() createParser,
    required Future<bool> Function() initializeProtocol,
    required PlotSessionData onData,
    required void Function(Object error) onSourceError,
    required void Function() releaseActivity,
    required void Function() onStarted,
    required void Function() onStartRejected,
    required void Function(Object error, StackTrace stackTrace) onStartFailed,
  }) {
    final active = _startFuture;
    if (active != null) return active;
    if (_isStopping || _isRunning || _disposed) return Future<void>.value();

    final generation = ++_generation;
    _isStarting = true;
    _onStateChanged();
    late final Future<void> operation;
    operation = _startInternal(
      generation: generation,
      config: config,
      prepare: prepare,
      createParser: createParser,
      initializeProtocol: initializeProtocol,
      onData: onData,
      onSourceError: onSourceError,
      releaseActivity: releaseActivity,
      onStarted: onStarted,
      onStartRejected: onStartRejected,
      onStartFailed: onStartFailed,
    ).whenComplete(() {
      if (identical(_startFuture, operation)) {
        _startFuture = null;
        _isStarting = false;
        _onStateChanged();
      }
    });
    _startFuture = operation;
    return operation;
  }

  Future<void> _startInternal({
    required int generation,
    required DataSourceConfig config,
    required PlotSessionPrepare prepare,
    required IDataParser Function() createParser,
    required Future<bool> Function() initializeProtocol,
    required PlotSessionData onData,
    required void Function(Object error) onSourceError,
    required void Function() releaseActivity,
    required void Function() onStarted,
    required void Function() onStartRejected,
    required void Function(Object error, StackTrace stackTrace) onStartFailed,
  }) async {
    var activityAcquired = false;
    try {
      activityAcquired = await prepare(generation);
      if (!activityAcquired || !isCurrent(generation)) {
        if (activityAcquired) releaseActivity();
        return;
      }

      _parser = createParser();
      if (!await initializeProtocol()) {
        await _cleanupResources();
        releaseActivity();
        onStartRejected();
        return;
      }
      if (!isCurrent(generation)) {
        await _cleanupResources();
        releaseActivity();
        return;
      }

      await _sourceManager.updateConfig(config);
      _isRunning = true;
      await _sourceManager.start();
      if (!isCurrent(generation)) {
        _isRunning = false;
        await _cleanupResources();
        releaseActivity();
        return;
      }

      _subscription = _sourceManager.byteStream.listen(
        (data) {
          if (!isCurrent(generation) || !_isRunning) return;
          final parser = _parser;
          if (parser == null) return;
          final results = parser.feedBatch(data);
          if (results.isNotEmpty) onData(results, DateTime.now());
        },
        onError: (Object error) {
          if (isCurrent(generation)) onSourceError(error);
        },
      );
      onStarted();
    } catch (error, stackTrace) {
      _isRunning = false;
      await _cleanupResources();
      if (activityAcquired) releaseActivity();
      onStartFailed(error, stackTrace);
    }
  }

  Future<void> stop({
    required void Function() releaseActivity,
    required void Function() onStopped,
  }) {
    final activeStop = _stopFuture;
    if (activeStop != null) return activeStop;
    final pendingStart = _startFuture;
    if (!_isRunning && pendingStart == null) return Future<void>.value();

    _generation++;
    _isStopping = true;
    _isRunning = false;
    _onStateChanged();
    late final Future<void> operation;
    // 将耗时释放放到事件队列，调用方可以先发布“已停止接收”的 UI 状态。
    operation = Future<void>(() async {
      try {
        if (pendingStart != null) {
          try {
            await pendingStart;
          } catch (error) {
            AppLogger().warning('等待绘图启动收敛失败: $error', category: 'PLOT');
          }
        }
        await _cleanupResources();
      } catch (error) {
        AppLogger().error('停止绘图清理失败: $error', category: 'PLOT');
      } finally {
        _isStopping = false;
        releaseActivity();
        onStopped();
        _onStateChanged();
      }
    }).whenComplete(() {
      if (identical(_stopFuture, operation)) _stopFuture = null;
    });
    _stopFuture = operation;
    return operation;
  }

  Future<void> _cleanupResources() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _sourceManager.stop();
    final parser = _parser;
    _parser = null;
    parser?.dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _isRunning = false;
    try {
      await _startFuture;
    } catch (_) {}
    await _cleanupResources();
    await _sourceManager.dispose();
    _isStarting = false;
    _isStopping = false;
    _startFuture = null;
    _stopFuture = null;
  }
}
