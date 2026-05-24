import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../models/channel_config.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// 固定帧头解析器
/// 格式：[帧头 1-4字节] + [数据] + [可选校验] + [可选帧尾]
class FixedFrameParser extends IDataParser {
  final _buffer = <int>[];
  final _controller = StreamController<ParseResult>.broadcast();

  FixedFrameParser([ParserConfig? config])
    : super(config ?? ParserConfig.fixedFrameDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  void feed(Uint8List data) {
    try {
      _buffer.addAll(data);
      _processBuffer();
    } catch (e) {
      AppLogger().debug('固定帧头解析异常: $e', category: 'PARSER');
    }
  }

  void _processBuffer() {
    while (_buffer.length >= config.totalFrameLength) {
      // 查找帧头
      final headerIndex = _findFrameHeader();
      if (headerIndex == -1) {
        // 未找到帧头，清空缓冲区（保留最后 frameHeaderLength - 1 字节，可能包含部分帧头）
        final keep = config.frameHeaderLength - 1;
        if (_buffer.length > keep) {
          _buffer.removeRange(0, _buffer.length - keep);
        }
        break;
      }

      // 丢弃帧头前的数据
      if (headerIndex > 0) {
        _buffer.removeRange(0, headerIndex);
      }

      // 检查是否有完整帧
      if (_buffer.length < config.totalFrameLength) {
        break;
      }

      // 提取一帧
      final frame = _buffer.sublist(0, config.totalFrameLength);
      final result = _parseFrame(frame);

      // 移除已处理的数据
      _buffer.removeRange(0, config.totalFrameLength);

      if (!_controller.isClosed) {
        _controller.add(result);
      }
    }

    // 防止缓冲区无限增长
    if (_buffer.length > config.totalFrameLength * 100) {
      _buffer.clear();
      AppLogger().warning('固定帧头解析缓冲区溢出，已清空', category: 'PARSER');
    }
  }

  /// 查找帧头位置
  int _findFrameHeader() {
    if (_buffer.length < config.frameHeaderLength) return -1;

    for (int i = 0; i <= _buffer.length - config.frameHeaderLength; i++) {
      bool match = true;
      for (int j = 0; j < config.frameHeaderLength; j++) {
        if (_buffer[i + j] != config.frameHeader[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  ParseResult _parseFrame(List<int> frame) {
    // 校验帧尾
    if (config.hasFrameTail && config.frameTail != null) {
      final tailStart = config.totalFrameLength - config.frameTail!.length;
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
    final dataStart = config.frameHeaderLength;
    final dataEnd =
        config.totalFrameLength -
        (config.hasChecksum ? config.checksumBytes : 0) -
        (config.hasFrameTail && config.frameTail != null
            ? config.frameTail!.length
            : 0);

    if (dataEnd <= dataStart) {
      return ParseResult.fail('数据区长度无效');
    }

    final dataBytes = frame.sublist(dataStart, dataEnd);
    final expectedBytes = config.dataType.byteSize * config.channelCount;

    if (dataBytes.length < expectedBytes) {
      return ParseResult.fail('数据区长度不足');
    }

    // 解析各通道数据
    final values = <double>[];
    for (int ch = 0; ch < config.channelCount; ch++) {
      final offset = ch * config.dataType.byteSize;
      final bytes = Uint8List.fromList(
        dataBytes.sublist(offset, offset + config.dataType.byteSize),
      );
      final value = _bytesToValue(bytes, config.dataType);
      values.add(value);
    }

    return ParseResult.ok(
      values,
      bytesConsumed: config.totalFrameLength,
      rawBytes: Uint8List.fromList(frame),
    );
  }

  /// 字节转数值
  static List<double> decodeFrameValues(Uint8List frame, ParserConfig config) {
    final dataStart = config.frameHeaderLength;
    final dataEnd =
        config.totalFrameLength -
        (config.hasChecksum ? config.checksumBytes : 0) -
        (config.hasFrameTail && config.frameTail != null
            ? config.frameTail!.length
            : 0);
    final dataBytes = frame.sublist(dataStart, dataEnd);
    final values = <double>[];
    for (int ch = 0; ch < config.channelCount; ch++) {
      final offset = ch * config.dataType.byteSize;
      if (offset + config.dataType.byteSize > dataBytes.length) break;
      final bytes = Uint8List.fromList(
        dataBytes.sublist(offset, offset + config.dataType.byteSize),
      );
      values.add(_bytesToValue(bytes, config.dataType));
    }
    return values;
  }

  static double _bytesToValue(Uint8List bytes, DataType type) {
    switch (type) {
      case DataType.uint8:
        return bytes[0].toDouble();
      case DataType.uint16:
        return ByteData.sublistView(
          bytes,
        ).getUint16(0, Endian.little).toDouble();
      case DataType.uint32:
        return ByteData.sublistView(
          bytes,
        ).getUint32(0, Endian.little).toDouble();
      case DataType.int8:
        return ByteData.sublistView(bytes).getInt8(0).toDouble();
      case DataType.int16:
        return ByteData.sublistView(
          bytes,
        ).getInt16(0, Endian.little).toDouble();
      case DataType.int32:
        return ByteData.sublistView(
          bytes,
        ).getInt32(0, Endian.little).toDouble();
      case DataType.float:
        return ByteData.sublistView(
          bytes,
        ).getFloat32(0, Endian.little).toDouble();
      case DataType.double:
        return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
    }
  }

  /// 校验和验证
  bool _verifyChecksum(List<int> frame) {
    // 简化实现：仅支持 SUM8
    if (config.checksumType == ChecksumType.sum8) {
      final dataEnd =
          config.totalFrameLength -
          config.checksumBytes -
          (config.hasFrameTail && config.frameTail != null
              ? config.frameTail!.length
              : 0);
      int sum = 0;
      for (int i = config.frameHeaderLength; i < dataEnd; i++) {
        sum += frame[i];
      }
      final checksumPos = dataEnd;
      final expected = sum & 0xFF;
      final actual = frame[checksumPos] & 0xFF;
      return expected == actual;
    }

    // 其他校验类型暂不实现，默认通过
    return true;
  }

  @override
  void reset() {
    _buffer.clear();
  }

  @override
  void dispose() {
    _controller.close();
  }
}
