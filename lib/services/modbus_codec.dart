import 'dart:convert';
import 'dart:typed_data';

import '../data/models/modbus_models.dart';

abstract final class ModbusCodec {
  static Uint8List encodeRequest(ModbusRequest request) {
    final pdu = _encodePdu(request);
    return switch (request.mode) {
      ModbusMode.rtu => _encodeRtu(request.unitId, pdu),
      ModbusMode.ascii => _encodeAscii(request.unitId, pdu),
      ModbusMode.tcp => _encodeTcp(request.transactionId, request.unitId, pdu),
    };
  }

  static ModbusResponse decodeResponse(ModbusRequest request, Uint8List frame) {
    final decoded = switch (request.mode) {
      ModbusMode.rtu => _decodeRtu(frame),
      ModbusMode.ascii => _decodeAscii(frame),
      ModbusMode.tcp => _decodeTcp(frame, request.transactionId),
    };
    if (decoded.unitId != request.unitId) {
      throw const FormatException('Modbus 单元号不匹配');
    }
    final pdu = decoded.pdu;
    if (pdu.isEmpty) throw const FormatException('Modbus 响应缺少 PDU');
    if (pdu[0] == (request.function.code | 0x80)) {
      if (pdu.length != 2) {
        throw const FormatException('Modbus 异常响应长度无效');
      }
      return ModbusResponse(
        request: request,
        rawFrame: frame,
        exceptionCode: pdu[1],
      );
    }
    if (pdu[0] != request.function.code) {
      throw const FormatException('Modbus 功能码不匹配');
    }
    if (request.function.isRead) {
      if (pdu.length < 2 || pdu.length != pdu[1] + 2) {
        throw const FormatException('Modbus 读取响应长度无效');
      }
      if (request.function.isBitFunction) {
        final values = <bool>[];
        for (var index = 0; index < request.quantity; index++) {
          values.add((pdu[2 + index ~/ 8] & (1 << (index % 8))) != 0);
        }
        return ModbusResponse(
          request: request,
          rawFrame: frame,
          coilValues: values,
        );
      }
      if (pdu[1] != request.quantity * 2) {
        throw const FormatException('Modbus 寄存器数量不匹配');
      }
      return ModbusResponse(
        request: request,
        rawFrame: frame,
        registerValues: [
          for (var index = 2; index < pdu.length; index += 2)
            (pdu[index] << 8) | pdu[index + 1],
        ],
      );
    }
    if (pdu.length != 5) throw const FormatException('Modbus 写入响应长度无效');
    final responseAddress = (pdu[1] << 8) | pdu[2];
    if (responseAddress != request.address) {
      throw const FormatException('Modbus 写入地址不匹配');
    }
    final echoedValue = (pdu[3] << 8) | pdu[4];
    final expectedValue = switch (request.function) {
      ModbusFunction.writeSingleCoil =>
        (request.coilValues.firstOrNull ?? false) ? 0xFF00 : 0,
      ModbusFunction.writeSingleRegister => request.registerValues.firstOrNull,
      ModbusFunction.writeMultipleCoils ||
      ModbusFunction.writeMultipleRegisters => request.quantity,
      _ => null,
    };
    if (expectedValue == null || echoedValue != expectedValue) {
      throw const FormatException('Modbus 写入响应回显值不匹配');
    }
    return ModbusResponse(request: request, rawFrame: frame);
  }

  static int expectedRtuResponseLength(Uint8List buffer) {
    if (buffer.length < 2) return 0;
    if ((buffer[1] & 0x80) != 0) return 5;
    if (buffer[1] >= 1 && buffer[1] <= 4) {
      return buffer.length < 3 ? 0 : 5 + buffer[2];
    }
    return 8;
  }

  static Uint8List _encodePdu(ModbusRequest request) {
    _validateQuantity(request);
    final bytes = <int>[
      request.function.code,
      request.address >> 8,
      request.address & 0xFF,
    ];
    switch (request.function) {
      case ModbusFunction.readCoils ||
          ModbusFunction.readDiscreteInputs ||
          ModbusFunction.readHoldingRegisters ||
          ModbusFunction.readInputRegisters:
        bytes.addAll([request.quantity >> 8, request.quantity & 0xFF]);
      case ModbusFunction.writeSingleCoil:
        final value = request.coilValues.firstOrNull ?? false;
        bytes.addAll(value ? [0xFF, 0] : [0, 0]);
      case ModbusFunction.writeSingleRegister:
        final value = request.registerValues.firstOrNull;
        if (value == null || value < 0 || value > 0xFFFF) {
          throw const FormatException('写单寄存器需要一个 0~65535 的值');
        }
        bytes.addAll([value >> 8, value & 0xFF]);
      case ModbusFunction.writeMultipleCoils:
        if (request.coilValues.length != request.quantity) {
          throw const FormatException('多线圈值数量与写入数量不一致');
        }
        final packed = List<int>.filled((request.quantity + 7) ~/ 8, 0);
        for (var index = 0; index < request.coilValues.length; index++) {
          if (request.coilValues[index]) packed[index ~/ 8] |= 1 << (index % 8);
        }
        bytes.addAll([
          request.quantity >> 8,
          request.quantity & 0xFF,
          packed.length,
          ...packed,
        ]);
      case ModbusFunction.writeMultipleRegisters:
        if (request.registerValues.length != request.quantity ||
            request.registerValues.any(
              (value) => value < 0 || value > 0xFFFF,
            )) {
          throw const FormatException('多寄存器值数量或范围无效');
        }
        bytes.addAll([
          request.quantity >> 8,
          request.quantity & 0xFF,
          request.quantity * 2,
          for (final value in request.registerValues) ...[
            value >> 8,
            value & 0xFF,
          ],
        ]);
    }
    return Uint8List.fromList(bytes);
  }

  static void _validateQuantity(ModbusRequest request) {
    final maximum = switch (request.function) {
      ModbusFunction.readCoils || ModbusFunction.readDiscreteInputs => 2000,
      ModbusFunction.readHoldingRegisters ||
      ModbusFunction.readInputRegisters => 125,
      ModbusFunction.writeSingleCoil || ModbusFunction.writeSingleRegister => 1,
      ModbusFunction.writeMultipleCoils => 1968,
      ModbusFunction.writeMultipleRegisters => 123,
    };
    if (request.quantity > maximum) {
      throw FormatException('${request.function.label}数量不能超过$maximum');
    }
  }

  static Uint8List _encodeRtu(int unitId, Uint8List pdu) {
    final body = Uint8List.fromList([unitId, ...pdu]);
    final crc = crc16(body);
    return Uint8List.fromList([...body, crc & 0xFF, crc >> 8]);
  }

  static Uint8List _encodeAscii(int unitId, Uint8List pdu) {
    final body = Uint8List.fromList([unitId, ...pdu]);
    final withLrc = [...body, lrc(body)];
    final text =
        ':${withLrc.map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase()).join()}\r\n';
    return Uint8List.fromList(ascii.encode(text));
  }

  static Uint8List _encodeTcp(int transactionId, int unitId, Uint8List pdu) =>
      Uint8List.fromList([
        transactionId >> 8,
        transactionId & 0xFF,
        0,
        0,
        (pdu.length + 1) >> 8,
        (pdu.length + 1) & 0xFF,
        unitId,
        ...pdu,
      ]);

  static ({int unitId, Uint8List pdu}) _decodeRtu(Uint8List frame) {
    if (frame.length < 5) throw const FormatException('Modbus RTU 响应过短');
    final expected = frame[frame.length - 2] | (frame.last << 8);
    if (crc16(Uint8List.sublistView(frame, 0, frame.length - 2)) != expected) {
      throw const FormatException('Modbus RTU CRC 校验失败');
    }
    return (
      unitId: frame[0],
      pdu: Uint8List.sublistView(frame, 1, frame.length - 2),
    );
  }

  static ({int unitId, Uint8List pdu}) _decodeAscii(Uint8List frame) {
    final text = ascii.decode(frame).trim();
    if (!text.startsWith(':') || (text.length - 1).isOdd) {
      throw const FormatException('Modbus ASCII 帧格式无效');
    }
    final body = <int>[];
    for (var index = 1; index < text.length; index += 2) {
      final value = int.tryParse(text.substring(index, index + 2), radix: 16);
      if (value == null) throw const FormatException('Modbus ASCII 包含非十六进制字符');
      body.add(value);
    }
    if (body.length < 4 ||
        lrc(Uint8List.fromList(body.sublist(0, body.length - 1))) !=
            body.last) {
      throw const FormatException('Modbus ASCII LRC 校验失败');
    }
    return (
      unitId: body[0],
      pdu: Uint8List.fromList(body.sublist(1, body.length - 1)),
    );
  }

  static ({int unitId, Uint8List pdu}) _decodeTcp(
    Uint8List frame,
    int transactionId,
  ) {
    if (frame.length < 9) throw const FormatException('Modbus TCP 响应过短');
    final responseTransaction = (frame[0] << 8) | frame[1];
    final protocol = (frame[2] << 8) | frame[3];
    final length = (frame[4] << 8) | frame[5];
    if (responseTransaction != transactionId) {
      throw const FormatException('Modbus TCP 事务号不匹配');
    }
    if (protocol != 0 || frame.length != length + 6) {
      throw const FormatException('Modbus TCP MBAP 长度无效');
    }
    return (unitId: frame[6], pdu: Uint8List.sublistView(frame, 7));
  }

  static int crc16(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc & 0xFFFF;
  }

  static int lrc(Uint8List data) =>
      (-data.fold<int>(0, (sum, byte) => sum + byte)) & 0xFF;
}

class ModbusFrameParser {
  ModbusFrameParser(this.mode);
  final ModbusMode mode;
  final List<int> _buffer = [];

  List<Uint8List> add(Uint8List data) {
    _buffer.addAll(data);
    final frames = <Uint8List>[];
    while (true) {
      final frame = switch (mode) {
        ModbusMode.rtu => _takeRtu(),
        ModbusMode.ascii => _takeAscii(),
        ModbusMode.tcp => _takeTcp(),
      };
      if (frame == null) break;
      frames.add(frame);
    }
    return frames;
  }

  Uint8List? _takeRtu() {
    final length = ModbusCodec.expectedRtuResponseLength(
      Uint8List.fromList(_buffer),
    );
    return _take(length);
  }

  Uint8List? _takeAscii() {
    final start = _buffer.indexOf(0x3A);
    if (start < 0) {
      _buffer.clear();
      return null;
    }
    if (start > 0) _buffer.removeRange(0, start);
    for (var index = 1; index + 1 < _buffer.length; index++) {
      if (_buffer[index] == 0x0D && _buffer[index + 1] == 0x0A) {
        return _take(index + 2);
      }
    }
    return null;
  }

  Uint8List? _takeTcp() {
    if (_buffer.length < 6) return null;
    final length = (_buffer[4] << 8) | _buffer[5];
    if (length < 3 || length > 260) {
      _buffer.removeAt(0);
      return _takeTcp();
    }
    return _take(length + 6);
  }

  Uint8List? _take(int length) {
    if (length <= 0 || _buffer.length < length) return null;
    final frame = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return frame;
  }

  void reset() => _buffer.clear();
}
