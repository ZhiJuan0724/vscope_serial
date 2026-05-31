import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// FireWater 解析器
/// 格式：以 ',' 分割数据，所有数据均默认 double，以 '\n' 结尾
/// 示例："1.23,4.56,7.89\n"
class FireWaterParser extends IDataParser {
  final _buffer = StringBuffer();
  final _controller = StreamController<ParseResult>.broadcast();

  FireWaterParser([ParserConfig? config])
    : super(config ?? ParserConfig.fireWaterDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  void feed(Uint8List data) {
    try {
      final text = String.fromCharCodes(data);
      _buffer.write(text);
      _processBuffer();
    } catch (e) {
      AppLogger().debug('FireWater 解析异常: $e', category: 'PARSER');
    }
  }

  void _processBuffer() {
    final bufferStr = _buffer.toString();
    final lines = bufferStr.split('\n');

    // 保留最后一行（可能不完整）
    _buffer.clear();
    if (lines.isNotEmpty && !bufferStr.endsWith('\n')) {
      _buffer.write(lines.last);
    }

    // 处理完整行
    final completeLines =
        bufferStr.endsWith('\n') ? lines : lines.sublist(0, lines.length - 1);

    for (final line in completeLines) {
      if (line.trim().isEmpty) continue;
      final result = _parseLine(line);
      if (!_controller.isClosed) {
        _controller.add(result);
      }
    }
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
    _buffer.clear();
  }

  @override
  void dispose() {
    _controller.close();
  }
}
