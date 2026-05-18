import 'dart:async';
import 'dart:typed_data';

import '../../services/serial_service.dart';
import '../models/data_source_config.dart';
import 'random_data_source.dart';
import 'serial_data_source.dart';

/// 数据源管理器
/// 管理多个数据源，根据配置合并或切换输出
class DataSourceManager {
  final SerialService _serialService;
  final DataSourceConfig config;

  SerialDataSource? _serialSource;
  RandomDataSource? _randomSource;
  final List<StreamSubscription> _subscriptions = [];
  final _controller = StreamController<Uint8List>.broadcast();

  DataSourceManager(this._serialService, {DataSourceConfig? config})
      : config = config ?? DataSourceConfig();

  /// 合并后的字节流
  Stream<Uint8List> get byteStream => _controller.stream;

  /// 是否有任何数据源处于活动状态
  bool get isActive => _serialSource?.isActive == true || _randomSource?.isActive == true;

  /// 更新配置
  void updateConfig(DataSourceConfig newConfig) {
    final wasActive = isActive;
    final oldUseSerial = config.useSerial;
    final oldUseRandom = config.useRandom;

    // 复制新配置
    config.useSerial = newConfig.useSerial;
    config.useRandom = newConfig.useRandom;
    config.randomChannelCount = newConfig.randomChannelCount;
    config.randomMinValue = newConfig.randomMinValue;
    config.randomMaxValue = newConfig.randomMaxValue;
    config.randomIntervalMs = newConfig.randomIntervalMs;

    // 如果配置变化且正在运行，重启数据源
    if (wasActive) {
      if (oldUseSerial != config.useSerial || oldUseRandom != config.useRandom) {
        stop();
        start();
      } else if (_randomSource != null && config.useRandom) {
        // 随机源参数变化，重建
        _randomSource?.stop();
        _randomSource = RandomDataSource(
          channelCount: config.randomChannelCount,
          minValue: config.randomMinValue,
          maxValue: config.randomMaxValue,
          intervalMs: config.randomIntervalMs,
        );
        _randomSource!.start();
        _subscribe(_randomSource!.byteStream);
      }
    }
  }

  /// 启动数据源
  void start() {
    // 清理旧订阅
    _cleanup();

    // 串口数据源
    if (config.useSerial) {
      _serialSource = SerialDataSource(_serialService);
      _serialSource!.start();
      _subscribe(_serialSource!.byteStream);
    }

    // 随机数据源
    if (config.useRandom) {
      _randomSource = RandomDataSource(
        channelCount: config.randomChannelCount,
        minValue: config.randomMinValue,
        maxValue: config.randomMaxValue,
        intervalMs: config.randomIntervalMs,
      );
      _randomSource!.start();
      _subscribe(_randomSource!.byteStream);
    }
  }

  /// 停止数据源
  void stop() {
    _cleanup();
  }

  void _subscribe(Stream<Uint8List> stream) {
    final sub = stream.listen(
      (data) {
        if (!_controller.isClosed) {
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

  void _cleanup() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    _serialSource?.stop();
    _serialSource = null;

    _randomSource?.stop();
    _randomSource = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
