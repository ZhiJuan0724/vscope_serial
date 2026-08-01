import 'dart:async';
import 'dart:typed_data';

import '../../services/data_connection_service.dart';
import '../models/data_source_config.dart';
import 'random_data_source.dart';
import 'connection_data_source.dart';

/// 数据源管理器
/// 管理多个数据源，根据配置合并或切换输出
class DataSourceManager {
  final DataConnectionService _connectionService;
  final DataSourceConfig config;

  ConnectionDataSource? _serialSource;
  RandomDataSource? _randomSource;
  final List<StreamSubscription> _subscriptions = [];
  final _controller = StreamController<Uint8List>.broadcast();
  Future<void> _operations = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;

  DataSourceManager(this._connectionService, {DataSourceConfig? config})
    : config = config ?? DataSourceConfig();

  /// 合并后的字节流
  Stream<Uint8List> get byteStream => _controller.stream;

  /// 是否有任何数据源处于活动状态
  bool get isActive =>
      _serialSource?.isActive == true || _randomSource?.isActive == true;

  /// 更新配置
  Future<void> updateConfig(DataSourceConfig newConfig) {
    final snapshot = newConfig.copyWith();
    return _serialize(() async {
      final wasActive = isActive;
      _copyConfig(snapshot);
      if (!wasActive) return;
      await _cleanupLocked();
      await _startLocked();
    });
  }

  /// 只更新运行中随机 isolate 的频率，不更换订阅或重启绘图会话。
  Future<void> updateRandomFrequency(double frequencyHz) {
    final next = frequencyHz.clamp(1.0, 100000.0);
    config.randomFrequencyHz = next;
    config.randomIntervalMs = (1000 / next).round().clamp(1, 1000);
    return _serialize(() async {
      await _randomSource?.updateFrequency(next);
    });
  }

  /// 启动数据源
  Future<void> start() => _serialize(() async {
    await _cleanupLocked();
    await _startLocked();
  });

  Future<void> _startLocked() async {
    if (_disposed) return;
    final generation = ++_generation;

    // 当前活动的数据连接，可能来自串口、TCP或UDP。
    if (config.useConnection) {
      _serialSource = ConnectionDataSource(_connectionService);
      _subscribe(_serialSource!.byteStream, generation);
      await _serialSource!.start();
    }

    // 随机数据源
    if (config.useRandom) {
      _randomSource = RandomDataSource(
        channelCount: config.randomChannelCount,
        minValue: config.randomMinValue,
        maxValue: config.randomMaxValue,
        frequencyHz: config.randomFrequencyHz,
      );
      _subscribe(_randomSource!.byteStream, generation);
      await _randomSource!.start();
    }
  }

  /// 停止数据源
  Future<void> stop() => _serialize(_cleanupLocked);

  void _subscribe(Stream<Uint8List> stream, int generation) {
    final sub = stream.listen(
      (data) {
        if (generation == _generation && !_controller.isClosed) {
          _controller.add(data);
        }
      },
      onError: (_) {
        // 数据源错误静默处理
      },
    );
    _subscriptions.add(sub);
  }

  /// 获取随机数据源的输出流（用于原始数据页面显示）
  Stream<Uint8List>? get randomDataStream => _randomSource?.byteStream;

  Future<void> _cleanupLocked() async {
    _generation++;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    await _serialSource?.dispose();
    _serialSource = null;

    await _randomSource?.dispose();
    _randomSource = null;
  }

  void _copyConfig(DataSourceConfig value) {
    config.useConnection = value.useConnection;
    config.useRandom = value.useRandom;
    config.randomChannelCount = value.randomChannelCount;
    config.randomMinValue = value.randomMinValue;
    config.randomMaxValue = value.randomMaxValue;
    config.randomIntervalMs = value.randomIntervalMs;
    config.randomFrequencyHz = value.randomFrequencyHz;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object _) {});
    return result;
  }

  Future<void> dispose() {
    _disposed = true;
    return _serialize(() async {
      await _cleanupLocked();
      await _controller.close();
    });
  }
}
