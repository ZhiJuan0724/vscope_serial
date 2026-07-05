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
/// - 缓冲区最大4096字节，超时500ms未成功则清空重试
class ZobowParser extends IDataParser {
  /// 内部字节缓冲区，用于缓存未解析的字节
  final _buffer = <int>[];

  /// 解析结果输出控制器
  final _controller = StreamController<ParseResult>.broadcast();

  /// 当前未完成残留数据开始等待的时间。
  DateTime? _residualSince;

  final DateTime Function() _now;

  /// 连续解析失败次数
  int _consecutiveFailures = 0;

  /// 上次打印连续失败日志的时间戳。CRC长期错误时必须限频，避免日志拖垮UI。
  DateTime? _lastFailureLogTime;

  /// 上次打印缓冲区溢出日志的时间戳。
  DateTime? _lastOverflowLogTime;

  /// 上次打印残留超时日志的时间戳。
  DateTime? _lastTimeoutLogTime;

  int _suppressedFailureWarnings = 0;
  int _suppressedOverflowWarnings = 0;
  int _suppressedTimeoutWarnings = 0;

  /// 最大缓冲区大小
  static const int _maxBufferSize = 4096;

  /// 单次 feed 最多滑窗尝试次数。协议无帧头，错误数据不能无限扫描阻塞 UI。
  static const int _maxScanAttemptsPerFeed = 2048;

  /// 超时时间（未成功解析则清空缓冲区）
  static const int _timeoutMs = 500;

  /// 最大连续失败次数
  static const int _maxConsecutiveFailures = 10;

  /// 解析异常日志限频间隔。
  static const int _warningLogIntervalMs = 1000;

  /// CRC-16/MODBUS 多项式（缓存避免重复查找）
  static final CrcPoly _crcPoly = crc16Polys['CRC-16/MODBUS']!;

  ZobowParser([ParserConfig? config, DateTime Function()? now])
    : _now = now ?? DateTime.now,
      super(config ?? ParserConfig.zobowDefault());

  int get _channelCount => config.zobowChannelCount;
  int get _dataLength => _channelCount * 2;
  int get _frameLength => _dataLength + 2;

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
      if (data.isEmpty) return const [];
      final now = _now();
      if (_buffer.isEmpty) {
        _residualSince = now;
      }
      _buffer.addAll(data);
      return _processBuffer(now);
    } catch (e, stack) {
      AppLogger().debug('众邦电控解析异常: $e\n$stack', category: 'PARSER');
      return const [];
    }
  }

  /// 处理缓冲区中的数据
  ///
  /// 使用滑动窗口策略：从索引0开始尝试解析，CRC失败则移动到索引1重试，
  /// 直到找到有效帧或遍历完所有可能位置。
  List<ParseResult> _processBuffer(DateTime now) {
    final results = <ParseResult>[];
    var scanOffset = 0;
    var scanAttempts = 0;
    var parsedFrame = false;

    // 滑动窗口解析。CRC失败时只推进游标，最后批量删除，避免 removeAt(0)
    // 在大缓冲区下反复搬移数据。
    while (scanOffset + _frameLength <= _buffer.length &&
        scanAttempts < _maxScanAttemptsPerFeed) {
      final result = _tryParseAt(scanOffset);
      scanAttempts++;

      if (result != null) {
        // 解析成功
        _consecutiveFailures = 0;
        parsedFrame = true;

        results.add(result);
        scanOffset += _frameLength;

        // 高频场景下禁用逐帧trace日志，避免性能瓶颈
        // AppLogger().trace(...)
      } else {
        // CRC失败，尝试下一个位置（滑动窗口）
        scanOffset++;
      }
    }

    if (scanOffset > 0) {
      _buffer.removeRange(0, scanOffset);
    }

    if (_buffer.isEmpty) {
      _residualSince = null;
    } else if (parsedFrame) {
      // 成功帧之后剩余的字节属于新的残留，重新开始计算等待时间。
      _residualSince = now;
    }

    // 防止协议不匹配或通道数配置错误时持续积压。这里在扫描后处理，
    // 合法的大块连续帧会优先被解析，不会因为刚进缓冲就超过上限而被丢掉。
    if (_buffer.length > _maxBufferSize) {
      _logOverflow();
      _buffer.removeRange(0, _buffer.length - _frameLength + 1);
    }

    // 必须在解析之后检查超时。即使调度曾暂停很久，新到达的完整有效帧也应
    // 优先恢复解析，而不是因为上次残留过旧而整批丢弃。
    final residualSince = _residualSince;
    if (_buffer.isNotEmpty && residualSince != null) {
      final elapsed = now.difference(residualSince).inMilliseconds;
      if (elapsed > _timeoutMs) {
        _logTimeout(elapsed);
        _buffer.clear();
        _residualSince = null;
        _consecutiveFailures = 0;
      }
    }
    return results;
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
        _logConsecutiveFailures();
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
    final channelCount = config.zobowChannelCount;
    final dataLength = channelCount * 2;
    final frameLength = dataLength + 2;

    if (frame.length != frameLength) {
      throw ArgumentError.value(
        frame.length,
        'frame.length',
        'must be $frameLength',
      );
    }

    final values = <double>[];
    final byteData = ByteData.sublistView(frame, 0, dataLength);

    for (int ch = 0; ch < channelCount; ch++) {
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

  static int frameLengthForConfig(ParserConfig config) =>
      config.zobowChannelCount * 2 + 2;

  bool _shouldLogWarning(DateTime? lastTime) {
    if (lastTime == null) return true;
    return _now().difference(lastTime).inMilliseconds >= _warningLogIntervalMs;
  }

  void _logConsecutiveFailures() {
    if (!_shouldLogWarning(_lastFailureLogTime)) {
      _suppressedFailureWarnings++;
      return;
    }
    final suppressed = _takeSuppressedFailureWarnings();
    _lastFailureLogTime = _now();
    AppLogger().warning(
      '众邦电控连续CRC失败，缓冲区=${_buffer.length}字节，'
      '帧长=$_frameLength，样本=${_bufferPreviewHex()}$suppressed',
      category: 'PARSER',
    );
  }

  void _logOverflow() {
    if (!_shouldLogWarning(_lastOverflowLogTime)) {
      _suppressedOverflowWarnings++;
      return;
    }
    final suppressed = _takeSuppressedOverflowWarnings();
    _lastOverflowLogTime = _now();
    AppLogger().warning(
      '众邦电控缓冲区溢出(${_buffer.length}>$_maxBufferSize)，'
      '保留最后${_frameLength - 1}字节$suppressed',
      category: 'PARSER',
    );
  }

  void _logTimeout(int elapsedMs) {
    if (!_shouldLogWarning(_lastTimeoutLogTime)) {
      _suppressedTimeoutWarnings++;
      return;
    }
    final suppressed =
        _suppressedTimeoutWarnings == 0
            ? ''
            : '，期间另抑制$_suppressedTimeoutWarnings次';
    _suppressedTimeoutWarnings = 0;
    _lastTimeoutLogTime = _now();
    AppLogger().warning(
      '众邦电控残留数据超时(${elapsedMs}ms)，'
      '清空缓冲区(${_buffer.length}字节)$suppressed',
      category: 'PARSER',
    );
  }

  String _takeSuppressedFailureWarnings() {
    final count = _suppressedFailureWarnings;
    _suppressedFailureWarnings = 0;
    return count == 0 ? '' : '，期间另抑制$count次';
  }

  String _takeSuppressedOverflowWarnings() {
    final count = _suppressedOverflowWarnings;
    _suppressedOverflowWarnings = 0;
    return count == 0 ? '' : '，期间另抑制$count次';
  }

  /// 只打印首尾少量字节，避免CRC持续错误时构造超长日志字符串。
  String _bufferPreviewHex() {
    if (_buffer.isEmpty) return '<empty>';
    const previewBytes = 16;
    String toHex(Iterable<int> bytes) {
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    }

    if (_buffer.length <= previewBytes * 2) {
      return toHex(_buffer);
    }
    final head = toHex(_buffer.take(previewBytes));
    final tail = toHex(_buffer.skip(_buffer.length - previewBytes));
    return '$head ... $tail';
  }

  @override
  void reset() {
    _buffer.clear();
    _residualSince = null;
    _consecutiveFailures = 0;
    _lastFailureLogTime = null;
    _lastOverflowLogTime = null;
    _lastTimeoutLogTime = null;
    _suppressedFailureWarnings = 0;
    _suppressedOverflowWarnings = 0;
    _suppressedTimeoutWarnings = 0;
    AppLogger().trace('众邦电控解析器已重置', category: 'PARSER');
  }

  @override
  void dispose() {
    _controller.close();
  }
}
