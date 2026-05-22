import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../../core/utils/crc.dart';
import '../models/channel_config.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// 众邦电控解析器
///
/// 协议格式：10字节固定帧
/// [Ch0_Low][Ch0_High][Ch1_Low][Ch1_High][Ch2_Low][Ch2_High][Ch3_Low][Ch3_High][CRC_Low][CRC_High]
///
/// 特点：
/// - 无帧头，通过滑动窗口尝试解析
/// - 前8字节为4个通道的uint16/int16数据（小端序）
/// - 后2字节为前8字节的CRC16（MODBUS）
/// - 每个通道可单独配置uint16或int16
/// - 缓冲区最大128字节，超时500ms未成功则清空重试
class ZobowParser extends IDataParser {
  /// 内部字节缓冲区，用于缓存未解析的字节
  final _buffer = <int>[];

  /// 解析结果输出控制器
  final _controller = StreamController<ParseResult>.broadcast();

  /// 上次成功解析的时间戳
  DateTime? _lastSuccessTime;

  /// 连续解析失败次数
  int _consecutiveFailures = 0;

  /// 最大缓冲区大小
  static const int _maxBufferSize = 128;

  /// 帧长度
  static const int _frameLength = 10;

  /// 数据区长度（不含CRC）
  static const int _dataLength = 8;

  /// 超时时间（未成功解析则清空缓冲区）
  static const int _timeoutMs = 500;

  /// 最大连续失败次数
  static const int _maxConsecutiveFailures = 10;

  /// CRC-16/MODBUS 多项式（缓存避免重复查找）
  static final CrcPoly _crcPoly = crc16Polys['CRC-16/MODBUS']!;

  ZobowParser([ParserConfig? config])
    : super(config ?? ParserConfig.zobowDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  void feed(Uint8List data) {
    try {
      _buffer.addAll(data);
      _processBuffer();
    } catch (e, stack) {
      AppLogger().debug('众邦电控解析异常: $e\n$stack', category: 'PARSER');
    }
  }

  /// 处理缓冲区中的数据
  ///
  /// 使用滑动窗口策略：从索引0开始尝试解析，CRC失败则移动到索引1重试，
  /// 直到找到有效帧或遍历完所有可能位置。
  void _processBuffer() {
    // 检查超时：超过500ms未成功解析，清空缓冲区
    if (_lastSuccessTime != null) {
      final elapsed =
          DateTime.now().difference(_lastSuccessTime!).inMilliseconds;
      if (elapsed > _timeoutMs && _buffer.isNotEmpty) {
        AppLogger().warning(
          '众邦电控解析超时(${elapsed}ms)，清空缓冲区(${_buffer.length}字节)',
          category: 'PARSER',
        );
        _buffer.clear();
        _consecutiveFailures = 0;
        return;
      }
    }

    // 防止缓冲区无限增长
    if (_buffer.length > _maxBufferSize) {
      AppLogger().warning(
        '众邦电控缓冲区溢出(${_buffer.length}>$_maxBufferSize)，保留最后${_frameLength - 1}字节',
        category: 'PARSER',
      );
      _buffer.removeRange(0, _buffer.length - _frameLength + 1);
    }

    // 滑动窗口解析
    while (_buffer.length >= _frameLength) {
      final result = _tryParseAt(0);

      if (result != null) {
        // 解析成功
        _consecutiveFailures = 0;
        _lastSuccessTime = DateTime.now();

        // 移除已消费的帧
        _buffer.removeRange(0, _frameLength);

        if (!_controller.isClosed) {
          _controller.add(result);
        }

        // 高频场景下禁用逐帧trace日志，避免性能瓶颈
        // AppLogger().trace(...)
      } else {
        // CRC失败，尝试下一个位置（滑动窗口）
        // 保留最后 _frameLength - 1 字节，可能包含下一帧的部分数据
        if (_buffer.length > _frameLength - 1) {
          _buffer.removeAt(0);
        } else {
          break;
        }
      }
    }
  }

  /// 尝试从指定索引位置解析一帧
  ///
  /// 返回 [ParseResult] 如果CRC验证通过，否则返回 null。
  ParseResult? _tryParseAt(int index) {
    if (index + _frameLength > _buffer.length) return null;

    // 提取候选帧。这里只在CRC通过后把完整帧挂到ParseResult上，
    // 供绘图会话按原始帧做窗口回放。
    final frame = Uint8List(_frameLength);
    for (int i = 0; i < _frameLength; i++) {
      frame[i] = _buffer[index + i];
    }

    // 提取数据区和CRC
    final dataBytes = Uint8List.sublistView(frame, 0, _dataLength);
    final crcLow = frame[_dataLength];
    final crcHigh = frame[_dataLength + 1];
    final receivedCrc = (crcHigh << 8) | crcLow;

    // 计算CRC（注意：crc.dart的crcToBytes返回大端序，但协议是小端序）
    final calculatedCrc = calculateCrc(dataBytes, _crcPoly);

    if (calculatedCrc != receivedCrc) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        AppLogger().warning(
          '众邦电控连续失败$_consecutiveFailures次，缓冲区=${_bytesToHex(Uint8List.fromList(_buffer))}',
          category: 'PARSER',
        );
        _consecutiveFailures = 0;
      }
      return null;
    }

    return ParseResult.ok(
      decodeFrameValues(frame, config),
      bytesConsumed: _frameLength,
      rawBytes: frame,
    );
  }

  /// 解码一帧众邦电控数据的4通道值。
  ///
  /// [frame] 必须是完整10字节帧。历史窗口回放复用这个方法，避免重新走
  /// 流式解析器的滑动窗口状态机。
  static List<double> decodeFrameValues(Uint8List frame, ParserConfig config) {
    if (frame.length != _frameLength) {
      throw ArgumentError.value(
        frame.length,
        'frame.length',
        'must be $_frameLength',
      );
    }

    final values = <double>[];
    final byteData = ByteData.sublistView(frame, 0, _dataLength);

    for (int ch = 0; ch < 4; ch++) {
      final type = config.zobowChannelTypes[ch];
      final offset = ch * 2;
      double value;

      switch (type) {
        case DataType.uint16:
          value = byteData.getUint16(offset, Endian.little).toDouble();
        case DataType.int16:
          value = byteData.getInt16(offset, Endian.little).toDouble();
        default:
          value = byteData.getUint16(offset, Endian.little).toDouble();
      }

      values.add(value);
    }

    return values;
  }

  /// 将字节列表转为16进制字符串（用于日志）
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  @override
  void reset() {
    _buffer.clear();
    _lastSuccessTime = null;
    _consecutiveFailures = 0;
    AppLogger().trace('众邦电控解析器已重置', category: 'PARSER');
  }

  @override
  void dispose() {
    _controller.close();
  }
}
