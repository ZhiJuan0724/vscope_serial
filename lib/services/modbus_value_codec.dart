import 'dart:typed_data';

import '../data/models/modbus_models.dart';

/// 在带类型的寄存器行与原始 16 位 Modbus 数值之间转换。
abstract final class ModbusValueCodec {
  static Object decodeRegisters(
    ModbusVariableType type,
    List<int> registers, {
    ModbusByteOrder byteOrder = ModbusByteOrder.highByteFirst,
    ModbusWordOrder wordOrder = ModbusWordOrder.highWordFirst,
  }) {
    if (registers.length < type.registerWidth) {
      throw const FormatException('响应寄存器数量不足');
    }
    if (type == ModbusVariableType.boolean) {
      return registers.first != 0;
    }
    if (type == ModbusVariableType.u8) return registers.first & 0xFF;
    if (type == ModbusVariableType.i8) {
      final value = registers.first & 0xFF;
      return value >= 0x80 ? value - 0x100 : value;
    }
    final bytes = _toBytes(
      registers.take(type.registerWidth).toList(growable: false),
      byteOrder: byteOrder,
      wordOrder: wordOrder,
    );
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (type == ModbusVariableType.u64) {
      return _unsignedBigIntFromBytes(bytes);
    }
    return switch (type) {
      ModbusVariableType.u16 => data.getUint16(0, Endian.big),
      ModbusVariableType.i16 => data.getInt16(0, Endian.big),
      ModbusVariableType.u32 => data.getUint32(0, Endian.big),
      ModbusVariableType.i32 => data.getInt32(0, Endian.big),
      ModbusVariableType.floatValue => data.getFloat32(0, Endian.big),
      ModbusVariableType.u64 => throw StateError('已在前面处理的变量类型'),
      ModbusVariableType.i64 => data.getInt64(0, Endian.big),
      ModbusVariableType.doubleValue => data.getFloat64(0, Endian.big),
      ModbusVariableType.boolean ||
      ModbusVariableType.u8 ||
      ModbusVariableType.i8 => throw StateError('已在前面处理的变量类型'),
    };
  }

  static bool decodeCoil(List<bool> values) =>
      values.isNotEmpty && values.first;

  static List<int> encodeRegisters(
    ModbusVariableType type,
    String text, {
    ModbusByteOrder byteOrder = ModbusByteOrder.highByteFirst,
    ModbusWordOrder wordOrder = ModbusWordOrder.highWordFirst,
  }) {
    final value = parse(type, text);
    if (type == ModbusVariableType.boolean) return [value == true ? 1 : 0];
    if (type == ModbusVariableType.u8 || type == ModbusVariableType.i8) {
      return [(value as int) & 0xFF];
    }
    final bytes = Uint8List(type.registerWidth * 2);
    final data = ByteData.sublistView(bytes);
    if (type == ModbusVariableType.u64) {
      var remaining = value as BigInt;
      for (var index = bytes.length - 1; index >= 0; index--) {
        bytes[index] = (remaining & BigInt.from(0xFF)).toInt();
        remaining >>= 8;
      }
    }
    switch (type) {
      case ModbusVariableType.u16:
        data.setUint16(0, value as int, Endian.big);
      case ModbusVariableType.i16:
        data.setInt16(0, value as int, Endian.big);
      case ModbusVariableType.u32:
        data.setUint32(0, value as int, Endian.big);
      case ModbusVariableType.i32:
        data.setInt32(0, value as int, Endian.big);
      case ModbusVariableType.floatValue:
        data.setFloat32(0, value as double, Endian.big);
      case ModbusVariableType.u64:
        break;
      case ModbusVariableType.i64:
        data.setInt64(0, value as int, Endian.big);
      case ModbusVariableType.doubleValue:
        data.setFloat64(0, value as double, Endian.big);
      case ModbusVariableType.boolean ||
          ModbusVariableType.u8 ||
          ModbusVariableType.i8:
        throw StateError('已在前面处理的变量类型');
    }
    final words = <int>[];
    for (var index = 0; index < bytes.length; index += 2) {
      words.add((bytes[index] << 8) | bytes[index + 1]);
    }
    if (wordOrder == ModbusWordOrder.lowWordFirst) {
      final reversed = words.reversed.toList(growable: false);
      words
        ..clear()
        ..addAll(reversed);
    }
    if (byteOrder == ModbusByteOrder.lowByteFirst) {
      for (var index = 0; index < words.length; index++) {
        final word = words[index];
        words[index] = ((word & 0xFF) << 8) | (word >> 8);
      }
    }
    return words;
  }

  static Object parse(ModbusVariableType type, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('值不能为空');
    if (type == ModbusVariableType.boolean) {
      final lower = trimmed.toLowerCase();
      if (lower == 'true' || lower == 'on') return true;
      if (lower == 'false' || lower == 'off') return false;
      return _parseInteger(trimmed) != 0;
    }
    if (type.isFloatingPoint) {
      final value = double.tryParse(trimmed);
      if (value == null || !value.isFinite) {
        throw FormatException('不是有效的 ${type.label} 值');
      }
      return value;
    }
    if (type == ModbusVariableType.u64) {
      final value = _parseBigInteger(trimmed);
      final max = (BigInt.one << 64) - BigInt.one;
      if (value < BigInt.zero || value > max) {
        throw FormatException('${type.label} 超出范围 0..$max');
      }
      return value;
    }
    final value = _parseInteger(trimmed);
    final (min, max) = switch (type) {
      ModbusVariableType.u8 => (0, 0xFF),
      ModbusVariableType.i8 => (-0x80, 0x7F),
      ModbusVariableType.u16 => (0, 0xFFFF),
      ModbusVariableType.i16 => (-0x8000, 0x7FFF),
      ModbusVariableType.u32 => (0, 0xFFFFFFFF),
      ModbusVariableType.i32 => (-0x80000000, 0x7FFFFFFF),
      ModbusVariableType.u64 => throw StateError('已在前面处理的变量类型'),
      ModbusVariableType.i64 => (-0x8000000000000000, 0x7FFFFFFFFFFFFFFF),
      _ => throw StateError('浮点类型已在前面处理'),
    };
    if (value < min || value > max) {
      throw FormatException('${type.label} 超出范围 $min..$max');
    }
    return value;
  }

  static String format(
    ModbusVariableType type,
    Object value, {
    required ModbusDisplayRadix radix,
    List<int> registers = const [],
  }) {
    if (radix == ModbusDisplayRadix.decimal) return '$value';
    final bits = _bitPattern(type, value, registers);
    final width = (type.bitWidth / 4).ceil();
    return '0x${bits.toRadixString(16).toUpperCase().padLeft(width, '0')}';
  }

  static BigInt _bitPattern(
    ModbusVariableType type,
    Object value,
    List<int> registers,
  ) {
    if (registers.length >= type.registerWidth && type.registerWidth > 1) {
      var result = BigInt.zero;
      for (final register in registers.take(type.registerWidth)) {
        result = (result << 16) | BigInt.from(register & 0xFFFF);
      }
      return result;
    }
    if (type == ModbusVariableType.boolean) {
      return value == true ? BigInt.one : BigInt.zero;
    }
    if (type == ModbusVariableType.u8 || type == ModbusVariableType.i8) {
      return BigInt.from((value as int) & 0xFF);
    }
    if (value is BigInt) {
      return value & ((BigInt.one << type.bitWidth) - BigInt.one);
    }
    if (value is int) {
      return BigInt.from(value) & ((BigInt.one << type.bitWidth) - BigInt.one);
    }
    final encoded = type.isFloatingPoint ? value : 0;
    final bytes = Uint8List(type.registerWidth * 2);
    final data = ByteData.sublistView(bytes);
    if (type == ModbusVariableType.floatValue) {
      data.setFloat32(0, encoded as double, Endian.big);
    } else if (type == ModbusVariableType.doubleValue) {
      data.setFloat64(0, encoded as double, Endian.big);
    }
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static List<int> _toBytes(
    List<int> registers, {
    required ModbusByteOrder byteOrder,
    required ModbusWordOrder wordOrder,
  }) {
    final words = List<int>.from(registers);
    if (wordOrder == ModbusWordOrder.lowWordFirst) {
      final reversed = words.reversed.toList(growable: false);
      words
        ..clear()
        ..addAll(reversed);
    }
    final bytes = <int>[];
    for (final word in words) {
      if (byteOrder == ModbusByteOrder.highByteFirst) {
        bytes.addAll([word >> 8, word & 0xFF]);
      } else {
        bytes.addAll([word & 0xFF, word >> 8]);
      }
    }
    return bytes;
  }

  static int _parseInteger(String text) {
    final negative = text.startsWith('-');
    final unsigned = negative ? text.substring(1) : text;
    final value =
        unsigned.toLowerCase().startsWith('0x')
            ? int.parse(unsigned.substring(2), radix: 16)
            : int.parse(unsigned);
    return negative ? -value : value;
  }

  static BigInt _parseBigInteger(String text) {
    final negative = text.startsWith('-');
    final unsigned = negative ? text.substring(1) : text;
    final value =
        unsigned.toLowerCase().startsWith('0x')
            ? BigInt.parse(unsigned.substring(2), radix: 16)
            : BigInt.parse(unsigned);
    return negative ? -value : value;
  }

  static BigInt _unsignedBigIntFromBytes(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}
