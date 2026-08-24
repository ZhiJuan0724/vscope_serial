import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import 'text_encoding_codec.dart';

/// 数据收发页面的发送负载编码器。
class OutboundDataCodec {
  bool sendHex = false;
  bool keepSendText = false;
  bool appendLineEnding = false;
  String lineEnding = '\r\n';
  bool enableCrc = false;
  CrcByteOrder crcByteOrder = CrcByteOrder.big;
  CrcType crcType = CrcType.crc16;
  String crcPolyName = 'CRC-16/MODBUS';

  Uint8List? prepare(String text, {required String encoding}) {
    if (text.isEmpty) return null;
    try {
      var data =
          sendHex ? _parseHex(text) : prepareText(text, encoding: encoding);
      if (data == null) return null;
      if (enableCrc && sendHex) data = _appendCrc(data);
      return data;
    } catch (error) {
      AppLogger().error('发送负载编码失败: $error', category: 'DATA');
      return null;
    }
  }

  Uint8List prepareText(String text, {required String encoding}) {
    final content = appendLineEnding ? '$text$lineEnding' : text;
    return encodeTextBytes(content, encoding);
  }

  Uint8List? prepareMulti(
    String text, {
    required bool isHex,
    required String encoding,
  }) {
    if (text.isEmpty) return null;
    if (!isHex) return encodeTextBytes(text, encoding);
    return _parseHex(text);
  }

  Uint8List? _parseHex(String text) {
    final hex = text.replaceAll(RegExp(r'\s+'), '');
    if (hex.isEmpty || hex.length.isOdd) {
      AppLogger().error('十六进制数据长度必须为偶数', category: 'DATA');
      return null;
    }
    final bytes = <int>[];
    for (var index = 0; index < hex.length; index += 2) {
      final value = int.tryParse(hex.substring(index, index + 2), radix: 16);
      if (value == null) {
        AppLogger().error('无效的十六进制数据', category: 'DATA');
        return null;
      }
      bytes.add(value);
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _appendCrc(Uint8List data) {
    final poly = getPolysByType(crcType)[crcPolyName];
    if (poly == null) return data;
    final crc = calculateCrc(data, poly);
    var crcBytes = crcToBytes(crc, poly.width);
    if (crcByteOrder == CrcByteOrder.little) {
      crcBytes = crcBytes.reversed.toList();
    }
    final result =
        Uint8List(data.length + crcBytes.length)
          ..setRange(0, data.length, data)
          ..setRange(data.length, data.length + crcBytes.length, crcBytes);
    return result;
  }
}
