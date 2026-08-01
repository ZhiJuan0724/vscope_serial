import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/data/protocol/plot_protocol_codec.dart';
import 'package:vscope_serial/data/protocol/send_protocol.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';
import 'package:vscope_serial/services/plot_protocol_initializer.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/services/serial_transport.dart';

void main() {
  group('PlotProtocolInitializer', () {
    test('数据连接未建立时返回结构化失败结果', () async {
      final service = SerialService.forTesting(
        transportFactory: _RecordingTransport.new,
      );
      addTearDown(service.dispose);

      final result = await PlotProtocolInitializer(service).initialize(
        protocol: zobowDeviceSendProtocol,
        config: ZobowDeviceProtocolInitializationConfig(const [1, 2, 3, 4]),
      );

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('数据连接未建立'));
    });

    test('众邦设备初始化通过统一串口链路发送协议帧', () async {
      final transport = _RecordingTransport();
      final service = SerialService.forTesting(
        transportFactory: () => transport,
      )..config = SerialConfig(port: 'COM7');
      addTearDown(service.dispose);
      await service.connect();

      final result = await PlotProtocolInitializer(service).initialize(
        protocol: zobowDeviceSendProtocol,
        config: ZobowDeviceProtocolInitializationConfig(const [1, 2, 3, 4]),
      );

      expect(result.succeeded, isTrue);
      expect(transport.writes, [
        zobowDeviceSendProtocol.buildInitFrame(const [1, 2, 3, 4]),
      ]);
      await service.shutdown();
    });

    test('r协议配置错误不会写入串口', () async {
      final transport = _RecordingTransport();
      final service = SerialService.forTesting(
        transportFactory: () => transport,
      )..config = SerialConfig(port: 'COM7');
      addTearDown(service.dispose);
      await service.connect();

      final result = await PlotProtocolInitializer(service).initialize(
        protocol: rSendProtocol,
        config: RProtocolInitializationConfig(addresses: const ['1', '', '3']),
      );

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('通道地址配置错误'));
      expect(transport.writes, isEmpty);
      await service.shutdown();
    });
  });
}

class _RecordingTransport implements SerialTransport {
  final StreamController<NativeSerialData> _controller =
      StreamController<NativeSerialData>.broadcast();
  final List<Uint8List> writes = [];
  bool _isOpen = false;

  @override
  Stream<NativeSerialData> get dataStream => _controller.stream;

  @override
  bool get isOpen => _isOpen;

  @override
  Future<bool> open(String port, int baudRate) async {
    _isOpen = true;
    return true;
  }

  @override
  Future<void> close() async {
    _isOpen = false;
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  bool setConfig(int dataBits, int stopBits, int parity) => true;

  @override
  void setDtr(bool value) {}

  @override
  void setRts(bool value) {}

  @override
  bool startReading({required int timeoutMs}) => true;

  @override
  Future<int> write(Uint8List data) async {
    writes.add(Uint8List.fromList(data));
    return data.length;
  }
}
