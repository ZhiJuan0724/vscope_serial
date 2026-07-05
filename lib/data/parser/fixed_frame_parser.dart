import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../../core/utils/crc.dart';
import '../models/channel_config.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// 固定帧协议解析器
/// 格式：[帧头] + [数据] + [可选 CRC] + [可选帧尾]
/// 或：[帧头] + [数据] + [可选帧尾] + [可选 CRC]
class FixedFrameParser extends IDataParser {
  final _buffer = <int>[];
  final _controller = StreamController<ParseResult>.broadcast();

  FixedFrameParser([ParserConfig? config])
    : super(config ?? ParserConfig.fixedFrameDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  void feed(Uint8List data) {
    for (final result in feedBatch(data)) {
      if (!_controller.isClosed) {
        _controller.add(result);
      }
    }
  }

  @override
  List<ParseResult> feedBatch(Uint8List data) {
    try {
      _buffer.addAll(data);
      return _processBuffer();
    } catch (e) {
      AppLogger().debug('固定帧协议解析异常: $e', category: 'PARSER');
      return const [];
    }
  }

  List<ParseResult> _processBuffer() {
    final results = <ParseResult>[];
    var readOffset = 0;
    while (_buffer.length - readOffset >= config.totalFrameLength) {
      // 查找帧头
      final headerIndex = _findFrameHeader(readOffset);
      if (headerIndex == -1) {
        // 未找到帧头，清空缓冲区（保留最后 frameHeaderLength - 1 字节，可能包含部分帧头）
        final keep = _frameHeaderLength - 1;
        readOffset = (_buffer.length - keep).clamp(0, _buffer.length);
        break;
      }

      readOffset = headerIndex;

      // 检查是否有完整帧
      if (_buffer.length - readOffset < config.totalFrameLength) {
        break;
      }

      final frame = Uint8List(config.totalFrameLength);
      for (var i = 0; i < frame.length; i++) {
        frame[i] = _buffer[readOffset + i];
      }
      results.add(_parseFrame(frame));
      readOffset += config.totalFrameLength;
    }
    if (readOffset > 0) {
      _buffer.removeRange(0, readOffset);
    }

    // 防止缓冲区无限增长
    if (_buffer.length > config.totalFrameLength * 100) {
      _buffer.clear();
      AppLogger().warning('固定帧协议解析缓冲区溢出，已清空', category: 'PARSER');
    }
    return results;
  }

  /// 查找帧头位置
  int _findFrameHeader(int start) {
    if (!config.hasFrameHeader) return start;
    if (_buffer.length < _frameHeaderLength) return -1;

    for (int i = start; i <= _buffer.length - _frameHeaderLength; i++) {
      bool match = true;
      for (int j = 0; j < _frameHeaderLength; j++) {
        if (_buffer[i + j] != config.frameHeader[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  ParseResult _parseFrame(Uint8List frame) {
    // 校验帧尾
    if (config.hasFrameTail && config.frameTail != null) {
      final tailStart = _frameTailStart;
      for (int i = 0; i < config.frameTail!.length; i++) {
        if (frame[tailStart + i] != config.frameTail![i]) {
          return ParseResult.fail('帧尾不匹配');
        }
      }
    }

    // 校验校验和（如有）
    if (config.hasChecksum) {
      final valid = _verifyChecksum(frame);
      if (!valid) {
        return ParseResult.fail('校验失败');
      }
    }

    // 提取数据区
    final dataStart = _frameHeaderLength;
    final dataEnd = dataStart + config.dataBytesPerFrame;

    if (dataEnd <= dataStart) {
      return ParseResult.fail('数据区长度无效');
    }

    final dataBytes = Uint8List.sublistView(frame, dataStart, dataEnd);
    final expectedBytes = config.dataBytesPerFrame;

    if (dataBytes.length < expectedBytes) {
      return ParseResult.fail('数据区长度不足');
    }

    // 解析各通道数据
    final values = <double>[];
    int offset = 0;
    for (int ch = 0; ch < config.channelCount; ch++) {
      final type = config.fixedFrameChannelTypeAt(ch);
      final value = _bytesToValue(dataBytes, offset, type);
      values.add(value);
      offset += type.byteSize;
    }

    return ParseResult.ok(
      values,
      bytesConsumed: config.totalFrameLength,
      rawBytes: frame,
    );
  }

  /// 字节转数值
  static List<double> decodeFrameValues(Uint8List frame, ParserConfig config) {
    final dataStart = config.hasFrameHeader ? config.frameHeaderLength : 0;
    final dataEnd = dataStart + config.dataBytesPerFrame;
    final dataBytes = Uint8List.sublistView(frame, dataStart, dataEnd);
    final values = <double>[];
    int offset = 0;
    for (int ch = 0; ch < config.channelCount; ch++) {
      final type = config.fixedFrameChannelTypeAt(ch);
      if (offset + type.byteSize > dataBytes.length) break;
      values.add(_bytesToValue(dataBytes, offset, type));
      offset += type.byteSize;
    }
    return values;
  }

  static double _bytesToValue(Uint8List bytes, int offset, DataType type) {
    final data = ByteData.sublistView(bytes);
    switch (type) {
      case DataType.uint8:
        return bytes[offset].toDouble();
      case DataType.uint16:
        return data.getUint16(offset, Endian.little).toDouble();
      case DataType.uint32:
        return data.getUint32(offset, Endian.little).toDouble();
      case DataType.int8:
        return data.getInt8(offset).toDouble();
      case DataType.int16:
        return data.getInt16(offset, Endian.little).toDouble();
      case DataType.int32:
        return data.getInt32(offset, Endian.little).toDouble();
      case DataType.float:
        return data.getFloat32(offset, Endian.little).toDouble();
      case DataType.double:
        return data.getFloat64(offset, Endian.little);
    }
  }

  int get _frameTailLength =>
      config.hasFrameTail && config.frameTail != null
          ? config.frameTail!.length
          : 0;

  int get _frameTailStart =>
      _frameHeaderLength +
      config.dataBytesPerFrame +
      (config.hasChecksum &&
              config.checksumPosition == ChecksumPosition.beforeFrameTail
          ? config.effectiveChecksumBytes
          : 0);

  int get _checksumStart =>
      _frameHeaderLength +
      config.dataBytesPerFrame +
      (config.checksumPosition == ChecksumPosition.afterFrameTail
          ? _frameTailLength
          : 0);

  /// 校验和验证
  bool _verifyChecksum(Uint8List frame) {
    final checksumStart = _checksumStart;
    final checksumBytes = config.effectiveChecksumBytes;
    final dataStart = _frameHeaderLength;
    final dataEnd = dataStart + config.dataBytesPerFrame;
    final dataBytes = Uint8List.sublistView(frame, dataStart, dataEnd);

    if (config.checksumType == ChecksumType.sum8) {
      final expected = dataBytes.fold<int>(0, (sum, byte) => sum + byte) & 0xFF;
      return expected == (frame[checksumStart] & 0xFF);
    }
    if (config.checksumType == ChecksumType.sum16) {
      final expected =
          dataBytes.fold<int>(0, (sum, byte) => sum + byte) & 0xFFFF;
      return _readChecksum(frame, checksumStart, checksumBytes) == expected;
    }
    final poly = _selectedCrcPoly;
    if (poly == null) return false;
    final expected = calculateCrc(dataBytes, poly);
    return _readChecksum(frame, checksumStart, checksumBytes) == expected;
  }

  CrcPoly? get _selectedCrcPoly {
    return switch (config.checksumType) {
      ChecksumType.crc8 => crc8Polys[config.crcPolynomialName],
      ChecksumType.crc16 => crc16Polys[config.crcPolynomialName],
      ChecksumType.crc32 => crc32Polys[config.crcPolynomialName],
      _ => null,
    };
  }

  int _readChecksum(Uint8List frame, int start, int length) {
    int value = 0;
    for (int i = 0; i < length; i++) {
      final index =
          config.checksumEndian == ChecksumEndian.big
              ? start + i
              : start + length - 1 - i;
      value = (value << 8) | (frame[index] & 0xFF);
    }
    return value;
  }

  int get _frameHeaderLength =>
      config.hasFrameHeader ? config.frameHeaderLength : 0;

  @override
  void reset() {
    _buffer.clear();
  }

  @override
  void dispose() {
    _controller.close();
  }
}
