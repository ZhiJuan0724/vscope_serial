import 'dart:ffi';
import 'dart:typed_data';

import 'native_serial_reader.dart';

/// 单个串口 open/close 生命周期的可替换 transport。
///
/// SerialService 负责操作排序和 generation 隔离；transport 只拥有本次
/// 打开的句柄、读取流和写队列，便于用 fake 精确验证竞态。
abstract interface class SerialTransport {
  Stream<NativeSerialData> get dataStream;
  bool get isOpen;

  Future<bool> open(String port, int baudRate);
  bool setConfig(int dataBits, int stopBits, int parity);
  void setRts(bool value);
  void setDtr(bool value);
  bool startReading({required int timeoutMs});
  Future<int> write(Uint8List data);
  Future<void> close();
}

/// 支持由 [SerialService] 按活动页面切换原生接收合并策略的 transport。
///
/// 测试 transport 和未来非 Windows 实现可以不实现此接口，串口基础收发不受影响。
abstract interface class PlotReceiveAggregationTransport {
  void setPlotReceiveAggregation(bool enabled);
}

class NativeSerialTransport
    implements SerialTransport, PlotReceiveAggregationTransport {
  final NativeSerialReader _reader = NativeSerialReader();

  @override
  Stream<NativeSerialData> get dataStream => _reader.dataStream;

  @override
  bool get isOpen => _reader.isOpen;

  @override
  Future<bool> open(String port, int baudRate) async {
    _reader.initDartApi(NativeApi.initializeApiDLData);
    final opened = await NativeSerialReader.openInBackground(port, baudRate);
    return opened && _reader.attachToOpenPort();
  }

  @override
  bool setConfig(int dataBits, int stopBits, int parity) =>
      _reader.setConfig(dataBits, stopBits, parity);

  @override
  void setRts(bool value) => _reader.setRts(value);

  @override
  void setDtr(bool value) => _reader.setDtr(value);

  @override
  bool startReading({required int timeoutMs}) =>
      _reader.startReading(timeoutMs: timeoutMs);

  @override
  void setPlotReceiveAggregation(bool enabled) =>
      _reader.setPlotReceiveAggregation(enabled);

  @override
  Future<int> write(Uint8List data) => _reader.write(data);

  @override
  Future<void> close() => _reader.close();
}
