import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../../core/constants/plot_configuration.dart';
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

  /// 目标生成频率（Hz）
  double _frequencyHz;

  double get frequencyHz => _frequencyHz;

  /// 兼容旧调用的生成间隔（毫秒），高频模式下可能小于 1ms，不能直接作为 Timer 间隔。
  double get intervalMs => 1000.0 / frequencyHz;

  final _controller = StreamController<Uint8List>.broadcast();

  /// 与生成 Isolate 通信的端口
  SendPort? _sendPort;

  /// 接收生成数据的端口
  ReceivePort? _receivePort;

  /// Isolate 实例
  Isolate? _isolate;
  StreamSubscription<dynamic>? _receiveSubscription;
  Completer<void>? _readyCompleter;
  int _generation = 0;

  RandomDataSource({
    this.channelCount = 4,
    this.minValue = PlotConfiguration.randomSourceDefaultMin,
    this.maxValue = PlotConfiguration.randomSourceDefaultMax,
    double? frequencyHz,
    int? intervalMs,
  }) : _frequencyHz = (frequencyHz ??
               (intervalMs == null ? 10.0 : 1000.0 / intervalMs))
           .clamp(1.0, 100000.0);

  @override
  Stream<Uint8List> get byteStream => _controller.stream;

  @override
  bool get isActive => _isolate != null;

  @override
  String get name => '随机数据';

  @override
  Future<void> start() async {
    if (_isolate != null) return;

    final generation = ++_generation;
    _receivePort = ReceivePort();
    _readyCompleter = Completer<void>();
    _receiveSubscription = _receivePort!.listen(
      (message) => _handleMessage(message, generation),
    );

    final initData = _IsolateInitData(
      sendPort: _receivePort!.sendPort,
      channelCount: channelCount,
      minValue: minValue,
      maxValue: maxValue,
      frequencyHz: _frequencyHz,
    );

    final isolate = await Isolate.spawn(_isolateEntry, initData);
    if (generation != _generation) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    _isolate = isolate;
    await _readyCompleter!.future.timeout(const Duration(seconds: 2));
  }

  void _handleMessage(dynamic message, int generation) {
    if (generation != _generation) return;
    if (message is SendPort) {
      // Isolate 启动完成，获取通信端口
      _sendPort = message;
      // 发送开始命令
      _sendPort!.send('start');
      final ready = _readyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete();
    } else if (message is Uint8List) {
      // 收到生成的数据
      if (!_controller.isClosed) {
        _controller.add(message);
      }
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _sendPort?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    await _receiveSubscription?.cancel();
    _receiveSubscription = null;
    _receivePort?.close();
    _receivePort = null;
    _readyCompleter = null;
  }

  /// 在线更新生成频率，不重建 isolate、订阅或波形相位。
  Future<void> updateFrequency(double value) async {
    _frequencyHz = value.clamp(1.0, 100000.0);
    if (_isolate == null) return;
    final sendPort = _sendPort;
    if (sendPort == null) {
      await _readyCompleter?.future.timeout(const Duration(seconds: 2));
    }
    _sendPort?.send(<Object>['frequency', _frequencyHz]);
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Isolate 入口函数
  static void _isolateEntry(_IsolateInitData initData) {
    final receivePort = ReceivePort();
    initData.sendPort.send(receivePort.sendPort);

    final generator = _DataGenerator(initData);
    Timer? timer;

    void startTimer() {
      timer?.cancel();
      final tickMs =
          generator.targetFrequencyHz <= 1000
              ? (1000 / generator.targetFrequencyHz).round().clamp(1, 1000)
              : 1;
      timer = Timer.periodic(
        Duration(milliseconds: tickMs),
        (_) => generator.generateForTick(tickMs),
      );
      generator.generateForTick(tickMs);
    }

    receivePort.listen((message) {
      if (message == 'start') {
        startTimer();
      } else if (message == 'stop') {
        timer?.cancel();
        timer = null;
      } else if (message is List &&
          message.length == 2 &&
          message.first == 'frequency' &&
          message[1] is num) {
        generator.updateFrequency((message[1] as num).toDouble());
        startTimer();
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
  final double frequencyHz;

  _IsolateInitData({
    required this.sendPort,
    required this.channelCount,
    required this.minValue,
    required this.maxValue,
    required this.frequencyHz,
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
  double _targetFrequencyHz;
  double _packetRemainder = 0;
  double _time = 0;
  final _random = Random();

  _DataGenerator(_IsolateInitData initData)
    : channelCount = initData.channelCount,
      minValue = initData.minValue,
      maxValue = initData.maxValue,
      sendPort = initData.sendPort,
      _targetFrequencyHz = initData.frequencyHz {
    _phaseOffsets = List.generate(
      channelCount,
      (i) => (i * pi / channelCount) + _random.nextDouble() * 0.5,
    );
    _frequencies = List.generate(channelCount, (i) => 0.05 + (i + 1) * 0.02);
  }

  double get targetFrequencyHz => _targetFrequencyHz;

  void updateFrequency(double value) {
    _targetFrequencyHz = value.clamp(1.0, 100000.0);
    _packetRemainder = 0;
  }

  void generateForTick(int tickMs) {
    final int packetCount;
    if (_targetFrequencyHz <= 1000) {
      packetCount = 1;
      _packetRemainder = 0;
    } else {
      final exactPackets =
          _targetFrequencyHz * tickMs / 1000 + _packetRemainder;
      packetCount = exactPackets.floor().clamp(1, 100000).toInt();
      _packetRemainder = exactPackets - packetCount;
    }

    final buffer = StringBuffer();
    for (int i = 0; i < packetCount; i++) {
      buffer.write(_generateLine());
    }
    sendPort.send(Uint8List.fromList(buffer.toString().codeUnits));
  }

  String _generateLine() {
    final amplitude = (maxValue - minValue) / 2 * 0.8;
    final center = (maxValue + minValue) / 2;

    final values = List.generate(channelCount, (i) {
      final sine = sin(_time * _frequencies[i] + _phaseOffsets[i]);
      final noise = (_random.nextDouble() - 0.5) * amplitude * 0.1;
      return center + sine * amplitude + noise;
    });

    _time += 1;

    return '${values.map((v) => v.clamp(minValue, maxValue).toStringAsFixed(2)).join(',')}\n';
  }
}
