import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_packet.dart';
import 'package:vscope_serial/data/models/modbus_models.dart';
import 'package:vscope_serial/services/modbus_client_service.dart';
import 'package:vscope_serial/services/modbus_codec.dart';

class _FakeLink implements ModbusDataLink {
  // 测试用链路在各用例tearDown中显式关闭两个控制器。
  // ignore: close_sinks
  final controller = StreamController<DataPacket>.broadcast();
  // ignore: close_sinks
  final disconnectController = StreamController<void>.broadcast();
  bool connected = true;
  bool acquired = false;
  int sendCount = 0;
  bool failSend = false;
  void Function(Uint8List data)? onSend;

  @override
  bool acquire() => acquired ? true : (acquired = true);

  @override
  Stream<DataPacket> get dataStream => controller.stream;

  @override
  Stream<void> get disconnectStream => disconnectController.stream;

  @override
  bool get isConnected => connected;

  @override
  void release() => acquired = false;

  @override
  Future<void> send(Uint8List data) async {
    sendCount++;
    if (failSend) throw StateError('写入失败');
    onSend?.call(data);
  }
}

void main() {
  test('请求保持单在途并解析拆分响应', () async {
    final link = _FakeLink();
    addTearDown(link.controller.close);
    addTearDown(link.disconnectController.close);
    final service = ModbusClientService(link, timeoutMs: 500);
    link.onSend = (_) {
      final body = Uint8List.fromList([1, 3, 2, 0, 42]);
      final crc = ModbusCodec.crc16(body);
      final frame = Uint8List.fromList([...body, crc & 0xFF, crc >> 8]);
      scheduleMicrotask(() {
        link.controller.add(
          DataPacket(data: Uint8List.sublistView(frame, 0, 3)),
        );
        link.controller.add(DataPacket(data: Uint8List.sublistView(frame, 3)));
      });
    };
    final response = await service.execute(
      ModbusRequest(
        mode: ModbusMode.rtu,
        unitId: 1,
        function: ModbusFunction.readHoldingRegisters,
        address: 0,
        quantity: 1,
      ),
    );
    expect(response.registerValues, [42]);
    expect(link.sendCount, 1);
    await service.stop();
    expect(link.acquired, isFalse);
  });

  test('写操作失败不自动重试', () async {
    final link = _FakeLink()..failSend = true;
    addTearDown(link.controller.close);
    addTearDown(link.disconnectController.close);
    final service = ModbusClientService(link);
    await expectLater(
      service.execute(
        ModbusRequest(
          mode: ModbusMode.rtu,
          unitId: 1,
          function: ModbusFunction.writeSingleRegister,
          address: 0,
          registerValues: const [1],
        ),
        readRetries: 3,
      ),
      throwsStateError,
    );
    expect(link.sendCount, 1);
    await service.stop();
  });

  test('任务导入逐项报告错误且保留有效项', () {
    final link = _FakeLink();
    addTearDown(link.controller.close);
    addTearDown(link.disconnectController.close);
    final service = ModbusClientService(link);
    final result = service.importTasks('''
      {"schemaVersion":1,"tasks":[
        {"id":"ok","name":"温度","unitId":1,"function":"readHoldingRegisters","address":0,"quantity":1,"intervalMs":1000},
        {"id":"bad","name":"","unitId":999}
      ]}
    ''');
    expect(result.tasks, hasLength(1));
    expect(result.errors, ['第2项无效']);
    expect(service.exportTasks(), contains('"schemaVersion": 1'));
  });
}
