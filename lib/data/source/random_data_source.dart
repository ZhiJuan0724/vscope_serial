import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'data_source.dart';

/// 内部随机数据源
/// 按 FireWater 格式生成随机数据: "value1,value2,...,valueN\n"
///
/// 各通道使用正弦波叠加少量噪声，相位不同，呈现有规律的波形而非完全随机。
///
/// 数据生成在独立 Isolate 中执行，避免阻塞 UI 线程。
class RandomDataSource implements IDataSource {
  /// 通道数
  final int channelCount;

  /// 数值最小值
  final double minValue;

  /// 数值最大值
  final double maxValue;

  /// 生成间隔（毫秒）
  final int intervalMs;

  final _controller = StreamController<Uint8List>.broadcast();

  /// 与生成 Isolate 通信的端口
  SendPort? _sendPort;

  /// 接收生成数据的端口
  ReceivePort? _receivePort;

  /// Isolate 实例
  Isolate? _isolate;

  RandomDataSource({
    this.channelCount = 4,
    this.minValue = 0.0,
    this.maxValue = 32768.0,
    this.intervalMs = 100,
  });

  @override
  Stream<Uint8List> get byteStream => _controller.stream;

  @override
  bool get isActive => _isolate != null;

  @override
  String get name => '随机数据';

  @override
  void start() {
    if (_isolate != null) return;

    _receivePort = ReceivePort();
    _receivePort!.listen(_handleMessage);

    final initData = _IsolateInitData(
      sendPort: _receivePort!.sendPort,
      channelCount: channelCount,
      minValue: minValue,
      maxValue: maxValue,
      intervalMs: intervalMs,
    );

    Isolate.spawn(_isolateEntry, initData).then((isolate) {
      _isolate = isolate;
    });
  }

  void _handleMessage(dynamic message) {
    if (message is SendPort) {
      // Isolate 启动完成，获取通信端口
      _sendPort = message;
      // 发送开始命令
      _sendPort!.send('start');
    } else if (message is Uint8List) {
      // 收到生成的数据
      if (!_controller.isClosed) {
        _controller.add(message);
      }
    }
  }

  @override
  void stop() {
    _sendPort?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _receivePort?.close();
    _receivePort = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  /// Isolate 入口函数
  static void _isolateEntry(_IsolateInitData initData) {
    final receivePort = ReceivePort();
    initData.sendPort.send(receivePort.sendPort);

    final generator = _DataGenerator(initData);
    Timer? timer;

    receivePort.listen((message) {
      if (message == 'start') {
        timer?.cancel();
        timer = Timer.periodic(
          Duration(milliseconds: initData.intervalMs),
          (_) => generator.generate(),
        );
        // 立即生成第一包
        generator.generate();
      } else if (message == 'stop') {
        timer?.cancel();
        timer = null;
      }
    });
  }
}

/// Isolate 初始化数据
class _IsolateInitData {
  final SendPort sendPort;
  final int channelCount;
  final double minValue;
  final double maxValue;
  final int intervalMs;

  _IsolateInitData({
    required this.sendPort,
    required this.channelCount,
    required this.minValue,
    required this.maxValue,
    required this.intervalMs,
  });
}

/// 数据生成器（在 Isolate 中运行）
class _DataGenerator {
  final int channelCount;
  final double minValue;
  final double maxValue;
  final SendPort sendPort;

  late final List<double> _phaseOffsets;
  late final List<double> _frequencies;
  double _time = 0;
  final _random = Random();

  _DataGenerator(_IsolateInitData initData)
    : channelCount = initData.channelCount,
      minValue = initData.minValue,
      maxValue = initData.maxValue,
      sendPort = initData.sendPort {
    _phaseOffsets = List.generate(
      channelCount,
      (i) => (i * pi / channelCount) + _random.nextDouble() * 0.5,
    );
    _frequencies = List.generate(channelCount, (i) => 0.05 + (i + 1) * 0.02);
  }

  void generate() {
    final amplitude = (maxValue - minValue) / 2 * 0.8;
    final center = (maxValue + minValue) / 2;

    final values = List.generate(channelCount, (i) {
      final sine = sin(_time * _frequencies[i] + _phaseOffsets[i]);
      final noise = (_random.nextDouble() - 0.5) * amplitude * 0.1;
      return center + sine * amplitude + noise;
    });

    _time += 1;

    final line =
        '${values.map((v) => v.clamp(minValue, maxValue).toStringAsFixed(2)).join(',')}\n';
    final bytes = Uint8List.fromList(line.codeUnits);
    sendPort.send(bytes);
  }
}
