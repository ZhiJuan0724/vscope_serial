import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'data_source.dart';

/// 内部随机数据源
/// 按 FireWater 格式生成随机数据: "value1,value2,...,valueN\n"
class RandomDataSource implements IDataSource {
  /// 通道数
  final int channelCount;

  /// 数值最小值
  final double minValue;

  /// 数值最大值
  final double maxValue;

  /// 生成间隔（毫秒）
  final int intervalMs;

  Timer? _timer;
  final _controller = StreamController<Uint8List>.broadcast();
  final _random = Random();

  RandomDataSource({
    this.channelCount = 4,
    this.minValue = 0.0,
    this.maxValue = 32768.0,
    this.intervalMs = 100,
  });

  @override
  Stream<Uint8List> get byteStream => _controller.stream;

  @override
  bool get isActive => _timer != null;

  @override
  String get name => '随机数据';

  @override
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _generateData(),
    );
    // 立即生成第一包
    _generateData();
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _generateData() {
    if (_controller.isClosed) return;

    final values = List.generate(
      channelCount,
      (_) => minValue + _random.nextDouble() * (maxValue - minValue),
    );

    // FireWater 格式: "v1,v2,...,vN\n"
    final line = '${values.map((v) => v.toStringAsFixed(2)).join(',')}\n';
    final bytes = Uint8List.fromList(line.codeUnits);
    _controller.add(bytes);
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
