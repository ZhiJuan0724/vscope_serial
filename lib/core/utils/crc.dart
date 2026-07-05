/// CRC 校验计算库
/// 支持 CRC-8, CRC-16, CRC-32 多种算法和多项式
library;

import 'dart:typed_data';

/// CRC 算法类型
enum CrcType { none, crc8, crc16, crc32 }

/// CRC 附加到发送数据时的字节序。
enum CrcByteOrder {
  big('大端'),
  little('小端');

  final String label;

  const CrcByteOrder(this.label);
}

/// CRC 多项式配置
class CrcPoly {
  final String name;
  final int width;
  final int poly;
  final int init;
  final bool refIn;
  final bool refOut;
  final int xorOut;

  const CrcPoly({
    required this.name,
    required this.width,
    required this.poly,
    required this.init,
    required this.refIn,
    required this.refOut,
    required this.xorOut,
  });
}

/// CRC-8 多项式
final Map<String, CrcPoly> crc8Polys = {
  'CRC-8': const CrcPoly(
    name: 'CRC-8',
    width: 8,
    poly: 0x07,
    init: 0x00,
    refIn: false,
    refOut: false,
    xorOut: 0x00,
  ),
  'CRC-8/CDMA2000': const CrcPoly(
    name: 'CRC-8/CDMA2000',
    width: 8,
    poly: 0x9B,
    init: 0xFF,
    refIn: false,
    refOut: false,
    xorOut: 0x00,
  ),
  'CRC-8/DARC': const CrcPoly(
    name: 'CRC-8/DARC',
    width: 8,
    poly: 0x39,
    init: 0x00,
    refIn: true,
    refOut: true,
    xorOut: 0x00,
  ),
  'CRC-8/DVB-S2': const CrcPoly(
    name: 'CRC-8/DVB-S2',
    width: 8,
    poly: 0xD5,
    init: 0x00,
    refIn: false,
    refOut: false,
    xorOut: 0x00,
  ),
  'CRC-8/EBU': const CrcPoly(
    name: 'CRC-8/EBU',
    width: 8,
    poly: 0x1D,
    init: 0xFF,
    refIn: true,
    refOut: true,
    xorOut: 0x00,
  ),
  'CRC-8/I-CODE': const CrcPoly(
    name: 'CRC-8/I-CODE',
    width: 8,
    poly: 0x1D,
    init: 0xFD,
    refIn: false,
    refOut: false,
    xorOut: 0x00,
  ),
  'CRC-8/ITU': const CrcPoly(
    name: 'CRC-8/ITU',
    width: 8,
    poly: 0x07,
    init: 0x00,
    refIn: false,
    refOut: false,
    xorOut: 0x55,
  ),
  'CRC-8/MAXIM': const CrcPoly(
    name: 'CRC-8/MAXIM',
    width: 8,
    poly: 0x31,
    init: 0x00,
    refIn: true,
    refOut: true,
    xorOut: 0x00,
  ),
  'CRC-8/ROHC': const CrcPoly(
    name: 'CRC-8/ROHC',
    width: 8,
    poly: 0x07,
    init: 0xFF,
    refIn: true,
    refOut: true,
    xorOut: 0x00,
  ),
  'CRC-8/WCDMA': const CrcPoly(
    name: 'CRC-8/WCDMA',
    width: 8,
    poly: 0x9B,
    init: 0x00,
    refIn: true,
    refOut: true,
    xorOut: 0x00,
  ),
};

/// CRC-16 多项式
final Map<String, CrcPoly> crc16Polys = {
  'CRC-16/CCITT-FALSE': const CrcPoly(
    name: 'CRC-16/CCITT-FALSE',
    width: 16,
    poly: 0x1021,
    init: 0xFFFF,
    refIn: false,
    refOut: false,
    xorOut: 0x0000,
  ),
  'CRC-16/ARC': const CrcPoly(
    name: 'CRC-16/ARC',
    width: 16,
    poly: 0x8005,
    init: 0x0000,
    refIn: true,
    refOut: true,
    xorOut: 0x0000,
  ),
  'CRC-16/AUG-CCITT': const CrcPoly(
    name: 'CRC-16/AUG-CCITT',
    width: 16,
    poly: 0x1021,
    init: 0x1D0F,
    refIn: false,
    refOut: false,
    xorOut: 0x0000,
  ),
  'CRC-16/BUYPASS': const CrcPoly(
    name: 'CRC-16/BUYPASS',
    width: 16,
    poly: 0x8005,
    init: 0x0000,
    refIn: false,
    refOut: false,
    xorOut: 0x0000,
  ),
  'CRC-16/CCITT': const CrcPoly(
    name: 'CRC-16/CCITT',
    width: 16,
    poly: 0x1021,
    init: 0x0000,
    refIn: true,
    refOut: true,
    xorOut: 0x0000,
  ),
  'CRC-16/CRC-IBM': const CrcPoly(
    name: 'CRC-16/CRC-IBM',
    width: 16,
    poly: 0x8005,
    init: 0x0000,
    refIn: true,
    refOut: true,
    xorOut: 0x0000,
  ),
  'CRC-16/IBM': const CrcPoly(
    name: 'CRC-16/IBM',
    width: 16,
    poly: 0x8005,
    init: 0x0000,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFF,
  ),
  'CRC-16/MODBUS': const CrcPoly(
    name: 'CRC-16/MODBUS',
    width: 16,
    poly: 0x8005,
    init: 0xFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0x0000,
  ),
  'CRC-16/USB': const CrcPoly(
    name: 'CRC-16/USB',
    width: 16,
    poly: 0x8005,
    init: 0xFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFF,
  ),
  'CRC-16/X-25': const CrcPoly(
    name: 'CRC-16/X-25',
    width: 16,
    poly: 0x1021,
    init: 0xFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFF,
  ),
  'CRC-16/XMODEM': const CrcPoly(
    name: 'CRC-16/XMODEM',
    width: 16,
    poly: 0x1021,
    init: 0x0000,
    refIn: false,
    refOut: false,
    xorOut: 0x0000,
  ),
};

/// CRC-32 多项式
final Map<String, CrcPoly> crc32Polys = {
  'CRC-32': const CrcPoly(
    name: 'CRC-32',
    width: 32,
    poly: 0x04C11DB7,
    init: 0xFFFFFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFFFFFF,
  ),
  'CRC-32/BZIP2': const CrcPoly(
    name: 'CRC-32/BZIP2',
    width: 32,
    poly: 0x04C11DB7,
    init: 0xFFFFFFFF,
    refIn: false,
    refOut: false,
    xorOut: 0xFFFFFFFF,
  ),
  'CRC-32/JAMCRC': const CrcPoly(
    name: 'CRC-32/JAMCRC',
    width: 32,
    poly: 0x04C11DB7,
    init: 0xFFFFFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0x00000000,
  ),
  'CRC-32/MPEG-2': const CrcPoly(
    name: 'CRC-32/MPEG-2',
    width: 32,
    poly: 0x04C11DB7,
    init: 0xFFFFFFFF,
    refIn: false,
    refOut: false,
    xorOut: 0x00000000,
  ),
  'CRC-32/POSIX': const CrcPoly(
    name: 'CRC-32/POSIX',
    width: 32,
    poly: 0x04C11DB7,
    init: 0x00000000,
    refIn: false,
    refOut: false,
    xorOut: 0xFFFFFFFF,
  ),
  'CRC-32/SATA': const CrcPoly(
    name: 'CRC-32/SATA',
    width: 32,
    poly: 0x04C11DB7,
    init: 0x52325032,
    refIn: false,
    refOut: false,
    xorOut: 0x00000000,
  ),
  'CRC-32C': const CrcPoly(
    name: 'CRC-32C',
    width: 32,
    poly: 0x1EDC6F41,
    init: 0xFFFFFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFFFFFF,
  ),
  'CRC-32D': const CrcPoly(
    name: 'CRC-32D',
    width: 32,
    poly: 0xA833982B,
    init: 0xFFFFFFFF,
    refIn: true,
    refOut: true,
    xorOut: 0xFFFFFFFF,
  ),
  'CRC-32Q': const CrcPoly(
    name: 'CRC-32Q',
    width: 32,
    poly: 0x814141AB,
    init: 0x00000000,
    refIn: false,
    refOut: false,
    xorOut: 0x00000000,
  ),
};

/// 获取指定类型的所有多项式
Map<String, CrcPoly> getPolysByType(CrcType type) {
  switch (type) {
    case CrcType.crc8:
      return crc8Polys;
    case CrcType.crc16:
      return crc16Polys;
    case CrcType.crc32:
      return crc32Polys;
    default:
      return {};
  }
}

/// 计算 CRC 校验值
int calculateCrc(Uint8List data, CrcPoly poly) {
  final calculator = CrcCalculator(poly)..add(data);
  return calculator.digest;
}

/// 可分块追加数据的 CRC 计算器，适合大文件流式读写。
class CrcCalculator {
  final CrcPoly poly;
  late final int _mask;
  late final int _topBit;
  late int _crc;

  CrcCalculator(this.poly) {
    if (poly.width != 8 && poly.width != 16 && poly.width != 32) {
      throw ArgumentError.value(poly.width, 'poly.width', '仅支持 8/16/32');
    }
    _mask = (1 << poly.width) - 1;
    _topBit = 1 << (poly.width - 1);
    _crc = poly.init & _mask;
  }

  void add(List<int> data) {
    final shift = poly.width - 8;
    for (final byte in data) {
      final input = poly.refIn ? _reverse8(byte) : byte;
      _crc ^= input << shift;
      for (var i = 0; i < 8; i++) {
        _crc =
            (_crc & _topBit) != 0
                ? ((_crc << 1) & _mask) ^ poly.poly
                : (_crc << 1) & _mask;
      }
    }
  }

  int get digest {
    final reflected = switch (poly.width) {
      8 => _reverse8(_crc),
      16 => _reverse16(_crc),
      32 => _reverse32(_crc),
      _ => _crc,
    };
    return ((poly.refOut ? reflected : _crc) ^ poly.xorOut) & _mask;
  }
}

int _reverse8(int value) {
  int result = 0;
  for (int i = 0; i < 8; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

int _reverse16(int value) {
  int result = 0;
  for (int i = 0; i < 16; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

int _reverse32(int value) {
  int result = 0;
  for (int i = 0; i < 32; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

/// 将 CRC 值转换为字节列表（大端序）
List<int> crcToBytes(int crc, int width) {
  final bytes = <int>[];
  if (width == 8) {
    bytes.add(crc & 0xFF);
  } else if (width == 16) {
    bytes.add((crc >> 8) & 0xFF);
    bytes.add(crc & 0xFF);
  } else if (width == 32) {
    bytes.add((crc >> 24) & 0xFF);
    bytes.add((crc >> 16) & 0xFF);
    bytes.add((crc >> 8) & 0xFF);
    bytes.add(crc & 0xFF);
  }
  return bytes;
}
