import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// FireWater 解析器
/// 格式：以 ',' 分割数据，所有数据均默认 double，以 '\n' 结尾
/// 示例："1.23,4.56,7.89\n"
/// FireWater ASCII 数值文本接收解析器。
///
/// 逐行增量扫描并限制单行残留长度，避免缺少换行的异常输入无限增长。
class FireWaterParser extends IDataParser {
  /// FireWater 正常数据行通常只有数百字节；64 KiB 足以容纳极端数值文本，
  /// 同时确保错误协议或长期缺少换行时残留内存保持有界。
  static const int maxLineBytes = 64 * 1024;

  final List<int> _lineBytes = <int>[];
  final _controller = StreamController<ParseResult>.broadcast();
  bool _discardingOversizedLine = false;
  int _droppedBytes = 0;
  int _resyncCount = 0;
  DateTime? _lastLimitLogAt;

  FireWaterParser([ParserConfig? config])
    : super(config ?? ParserConfig.fireWaterDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  ParserDiagnostics get diagnostics =>
      ParserDiagnostics(droppedBytes: _droppedBytes, resyncCount: _resyncCount);

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
      final results = <ParseResult>[];
      for (final byte in data) {
        if (_discardingOversizedLine) {
          _droppedBytes++;
          if (byte == 0x0A) {
            _discardingOversizedLine = false;
          }
          continue;
        }

        if (byte == 0x0A) {
          if (_lineBytes.isNotEmpty) {
            results.add(_parseLine(String.fromCharCodes(_lineBytes)));
            _lineBytes.clear();
          }
          continue;
        }

        if (_lineBytes.length >= maxLineBytes) {
          _droppedBytes += _lineBytes.length + 1;
          _lineBytes.clear();
          _discardingOversizedLine = true;
          _resyncCount++;
          _logLimitReached();
          continue;
        }
        _lineBytes.add(byte);
      }
      return results;
    } catch (e) {
      AppLogger().debug('FireWater 解析异常: $e', category: 'PARSER');
      return const [];
    }
  }

  void _logLimitReached() {
    final now = DateTime.now();
    if (_lastLimitLogAt != null &&
        now.difference(_lastLimitLogAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastLimitLogAt = now;
    AppLogger().warning(
      'FireWater 单行超过 $maxLineBytes 字节，已丢弃并等待下一处换行重新同步；'
      '累计丢弃 $_droppedBytes 字节',
      category: 'PARSER',
    );
  }

  ParseResult _parseLine(String line) {
    final parts = line.split(',');
    if (parts.isEmpty) {
      return ParseResult.fail('空数据行');
    }

    final values = <double>[];
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;

      final value = double.tryParse(trimmed);
      if (value == null) {
        return ParseResult.fail('无法解析数值: "$trimmed"');
      }
      values.add(value);
    }

    if (values.isEmpty) {
      return ParseResult.fail('无有效数值');
    }

    // FireWater 通道数设置
    final fwChannels = config.fireWaterChannelCount;
    if (fwChannels > 0) {
      // 固定通道数模式
      if (values.length < fwChannels) {
        return ParseResult.fail('通道数不足，需要 $fwChannels，实际 ${values.length}');
      }
      values.length = fwChannels;
    }

    // 最大 16 通道，超出截断
    if (values.length > 16) {
      values.length = 16;
    }

    return ParseResult.ok(values);
  }

  @override
  void reset() {
    _lineBytes.clear();
    _discardingOversizedLine = false;
  }

  @override
  void dispose() {
    _controller.close();
  }
}
