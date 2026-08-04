import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/modbus_models.dart';
import 'package:vscope_serial/services/modbus_value_codec.dart';

void main() {
  test('u8/i8 使用寄存器低八位', () {
    expect(
      ModbusValueCodec.decodeRegisters(ModbusVariableType.u8, [0xABCD]),
      0xCD,
    );
    expect(
      ModbusValueCodec.decodeRegisters(ModbusVariableType.i8, [0x00FF]),
      -1,
    );
  });

  test('32位四种字节字序布局', () {
    const type = ModbusVariableType.u32;
    expect(
      ModbusValueCodec.decodeRegisters(type, [0x4142, 0x4344]),
      0x41424344,
    );
    expect(
      ModbusValueCodec.decodeRegisters(type, [
        0x4241,
        0x4443,
      ], byteOrder: ModbusByteOrder.lowByteFirst),
      0x41424344,
    );
    expect(
      ModbusValueCodec.decodeRegisters(type, [
        0x4344,
        0x4142,
      ], wordOrder: ModbusWordOrder.lowWordFirst),
      0x41424344,
    );
    expect(
      ModbusValueCodec.decodeRegisters(
        type,
        [0x4443, 0x4241],
        byteOrder: ModbusByteOrder.lowByteFirst,
        wordOrder: ModbusWordOrder.lowWordFirst,
      ),
      0x41424344,
    );
  });

  test('浮点值支持编码、解码和原始十六进制显示', () {
    final registers = ModbusValueCodec.encodeRegisters(
      ModbusVariableType.floatValue,
      '1.5',
    );
    final value = ModbusValueCodec.decodeRegisters(
      ModbusVariableType.floatValue,
      registers,
    );
    expect(value, closeTo(1.5, 0.00001));
    expect(
      ModbusValueCodec.format(
        ModbusVariableType.floatValue,
        value,
        radix: ModbusDisplayRadix.hexadecimal,
        registers: registers,
      ),
      '0x3FC00000',
    );
  });

  test('稀疏行配置默认值省略且能补全', () {
    final row = ModbusRegisterRow(id: 'r', address: 1);
    expect(row.toSparseJson(ModbusRegisterArea.holdingRegisters), {
      'address': 1,
    });
    final parsed = ModbusRegisterRow.fromJson({
      'address': 1,
    }, ModbusRegisterArea.holdingRegisters);
    expect(parsed, isNotNull);
    expect(parsed!.displayRadix, ModbusDisplayRadix.decimal);
    expect(parsed.pollEnabled, isFalse);
    expect(parsed.sendMode, ModbusSendValueMode.fixed);
  });

  test('轮询和发送周期最低允许10ms', () {
    final minimum = ModbusRegisterRow.fromJson({
      'address': 1,
      'poll': {'enabled': true, 'intervalMs': 10},
      'send': {'enabled': true, 'intervalMs': 10},
    }, ModbusRegisterArea.holdingRegisters);
    expect(minimum, isNotNull);
    expect(minimum!.pollIntervalMs, modbusMinIntervalMs);
    expect(minimum.sendIntervalMs, modbusMinIntervalMs);

    final clamped = ModbusRegisterRow.fromJson({
      'address': 1,
      'poll': {'intervalMs': 1},
      'send': {'intervalMs': 1},
    }, ModbusRegisterArea.holdingRegisters);
    expect(clamped!.pollIntervalMs, modbusMinIntervalMs);
    expect(clamped.sendIntervalMs, modbusMinIntervalMs);
  });
}
