import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/data_packet.dart';
import 'data_transport_session.dart';
import 'native_serial_reader.dart';

/// 单个串口 open/close 生命周期的可替换 transport。
///
/// DataConnectionService 负责操作排序和 generation 隔离；transport 只拥有本次
/// 打开的句柄、读取流和写队列，便于用 fake 精确验证竞态。
abstract interface class SerialTransport implements DataTransportSession {
  Future<bool> open(String port, int baudRate);
  bool setConfig(int dataBits, int stopBits, int parity);
  void setRts(bool value);
  void setDtr(bool value);
  bool startReading({required int timeoutMs});
  @override
  Future<int> write(Uint8List data);
  @override
  Future<void> close();
}

/// 支持由 [DataConnectionService] 按活动页面切换原生接收合并策略的 transport。
///
/// 测试 transport 和未来非 Windows 实现可以不实现此接口，串口基础收发不受影响。
abstract interface class PlotReceiveAggregationTransport {
  void setPlotReceiveAggregation(bool enabled);
}

class NativeSerialTransport
    implements SerialTransport, PlotReceiveAggregationTransport {
  final NativeSerialReader _reader = NativeSerialReader();

  @override
  Stream<DataPacket> get dataStream => _reader.dataStream.map(
    (event) => DataPacket(
      data: event.data,
      timestamp: DateTime.fromMicrosecondsSinceEpoch(event.wallClockUs),
      monotonicUs: event.monotonicUs,
    ),
  );

  @override
  Stream<Object> get errorStream => const Stream<Object>.empty();

  @override
  bool get isOpen => _reader.isOpen;

  @override
  bool get canSend => isOpen;

  @override
  String get description => '串口';

  @override
  Future<bool> open(String port, int baudRate) async {
    final logger = AppLogger();
    final stopwatch = Stopwatch()..start();
    logger.debug(
      '原生 transport 打开开始: port=$port, baudRate=$baudRate, '
      'pid=$pid, exe=${Platform.resolvedExecutable}',
      category: 'SERIAL',
    );
    NativeSerialReader.configureDiagnosticLogging(
      logger.diagnosticEnabled,
      logger.logFilePath,
    );
    final dartApiReady = _reader.initDartApi(NativeApi.initializeApiDLData);
    logger.debug('Dart API DL 初始化结果: $dartApiReady', category: 'SERIAL');
    if (!dartApiReady) return false;

    final result = await NativeSerialReader.openInBackgroundDetailed(
      port,
      baudRate,
    );
    logger.debug(
      '原生 open 返回: opened=${result.opened}, '
      'stage=${result.stage}(${result.stageName}), '
      'win32Error=${result.errorCode}, '
      'elapsed=${stopwatch.elapsedMilliseconds}ms',
      category: 'SERIAL',
    );
    if (!result.opened) {
      throw NativeSerialOpenException(result.failureDescription);
    }

    final attached = _reader.attachToOpenPort();
    logger.debug(
      'UI isolate 挂接原生句柄: attached=$attached, '
      'isOpen=${_reader.isOpen}, elapsed=${stopwatch.elapsedMilliseconds}ms',
      category: 'SERIAL',
    );
    return attached;
  }

  @override
  bool setConfig(int dataBits, int stopBits, int parity) {
    final result = _reader.setConfig(dataBits, stopBits, parity);
    AppLogger().debug(
      '应用串口参数: dataBits=$dataBits, stopBits=$stopBits, '
      'parity=$parity, result=$result',
      category: 'SERIAL',
    );
    return result;
  }

  @override
  void setRts(bool value) {
    _reader.setRts(value);
    AppLogger().debug('应用 RTS=$value 完成', category: 'SERIAL');
  }

  @override
  void setDtr(bool value) {
    _reader.setDtr(value);
    AppLogger().debug('应用 DTR=$value 完成', category: 'SERIAL');
  }

  @override
  bool startReading({required int timeoutMs}) {
    final result = _reader.startReading(timeoutMs: timeoutMs);
    AppLogger().debug(
      '启动原生读取线程: timeoutMs=$timeoutMs, result=$result',
      category: 'SERIAL',
    );
    return result;
  }

  @override
  void setPlotReceiveAggregation(bool enabled) =>
      _reader.setPlotReceiveAggregation(enabled);

  @override
  Future<int> write(Uint8List data) => _reader.write(data);

  @override
  Future<void> close() async {
    AppLogger().debug('原生 transport 关闭开始', category: 'SERIAL');
    await _reader.close();
    AppLogger().debug('原生 transport 关闭完成', category: 'SERIAL');
  }
}
