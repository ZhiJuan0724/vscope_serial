import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/modbus_models.dart';
import 'package:vscope_serial/services/modbus_codec.dart';

void main() {
  ModbusRequest request(ModbusMode mode, {int transactionId = 1}) =>
      ModbusRequest(
        mode: mode,
        unitId: 1,
        function: ModbusFunction.readHoldingRegisters,
        address: 0,
        quantity: 2,
        transactionId: transactionId,
      );

  test('RTU读取保持寄存器黄金帧', () {
    expect(
      ModbusCodec.encodeRequest(request(ModbusMode.rtu)),
      Uint8List.fromList([0x01, 0x03, 0, 0, 0, 2, 0xC4, 0x0B]),
    );
  });

  test('ASCII读取保持寄存器黄金帧', () {
    expect(
      ascii.decode(ModbusCodec.encodeRequest(request(ModbusMode.ascii))),
      ':010300000002FA\r\n',
    );
  });

  test('TCP读取保持寄存器黄金帧', () {
    expect(
      ModbusCodec.encodeRequest(request(ModbusMode.tcp)),
      Uint8List.fromList([0, 1, 0, 0, 0, 6, 1, 3, 0, 0, 0, 2]),
    );
  });

  test('解析RTU寄存器响应并校验CRC', () {
    final body = Uint8List.fromList([1, 3, 4, 0, 10, 1, 2]);
    final crc = ModbusCodec.crc16(body);
    final frame = Uint8List.fromList([...body, crc & 0xFF, crc >> 8]);
    final response = ModbusCodec.decodeResponse(request(ModbusMode.rtu), frame);
    expect(response.registerValues, [10, 258]);

    frame.last ^= 1;
    expect(
      () => ModbusCodec.decodeResponse(request(ModbusMode.rtu), frame),
      throwsFormatException,
    );
  });

  test('分包器支持拆包和粘包', () {
    final parser = ModbusFrameParser(ModbusMode.tcp);
    final first = Uint8List.fromList([0, 1, 0, 0, 0, 5, 1, 3, 2, 0, 1]);
    final second = Uint8List.fromList([0, 2, 0, 0, 0, 5, 1, 3, 2, 0, 2]);
    expect(parser.add(Uint8List.sublistView(first, 0, 4)), isEmpty);
    final frames = parser.add(
      Uint8List.fromList([...first.sublist(4), ...second]),
    );
    expect(frames, [first, second]);
  });

  test('写多个寄存器编码和值数量校验', () {
    final frame = ModbusCodec.encodeRequest(
      ModbusRequest(
        mode: ModbusMode.rtu,
        unitId: 1,
        function: ModbusFunction.writeMultipleRegisters,
        address: 0x10,
        quantity: 2,
        registerValues: const [0x1234, 0x5678],
      ),
    );
    expect(frame.sublist(0, 11), [
      1,
      0x10,
      0,
      0x10,
      0,
      2,
      4,
      0x12,
      0x34,
      0x56,
      0x78,
    ]);
  });

  test('八种功能码均可构造有效PDU', () {
    for (final function in ModbusFunction.values) {
      final isSingle =
          function == ModbusFunction.writeSingleCoil ||
          function == ModbusFunction.writeSingleRegister;
      final encoded = ModbusCodec.encodeRequest(
        ModbusRequest(
          mode: ModbusMode.rtu,
          unitId: 1,
          function: function,
          address: 10,
          quantity: isSingle ? 1 : 2,
          coilValues:
              function == ModbusFunction.writeSingleCoil
                  ? const [true]
                  : function == ModbusFunction.writeMultipleCoils
                  ? const [true, false]
                  : const [],
          registerValues:
              function == ModbusFunction.writeSingleRegister
                  ? const [7]
                  : function == ModbusFunction.writeMultipleRegisters
                  ? const [7, 8]
                  : const [],
        ),
      );
      expect(encoded[1], function.code);
    }
  });
}
