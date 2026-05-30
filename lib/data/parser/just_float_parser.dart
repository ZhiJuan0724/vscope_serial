import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/app_logger.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// VOFA JustFloat parser.
///
/// Frames are little-endian float32 values followed by the VOFA tail:
/// 00 00 80 7F.
class JustFloatParser extends IDataParser {
  static const List<int> tail = [0x00, 0x00, 0x80, 0x7F];

  final _buffer = <int>[];
  final _controller = StreamController<ParseResult>.broadcast();

  JustFloatParser([ParserConfig? config])
    : super(config ?? ParserConfig.justFloatDefault());

  @override
  Stream<ParseResult> get outputStream => _controller.stream;

  @override
  void feed(Uint8List data) {
    try {
      _buffer.addAll(data);
      _processBuffer();
    } catch (e) {
      AppLogger().debug('JustFloat 解析异常: $e', category: 'PARSER');
    }
  }

  void _processBuffer() {
    while (_buffer.length >= tail.length) {
      final tailIndex = _indexOfTail();
      if (tailIndex < 0) {
        return;
      }

      final payload = Uint8List.fromList(_buffer.sublist(0, tailIndex));
      _buffer.removeRange(0, tailIndex + tail.length);
      final result = _parsePayload(payload);
      if (!_controller.isClosed) {
        _controller.add(result);
      }
    }
  }

  int _indexOfTail() {
    for (int i = 0; i <= _buffer.length - tail.length; i++) {
      var matched = true;
      for (int j = 0; j < tail.length; j++) {
        if (_buffer[i + j] != tail[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  ParseResult _parsePayload(Uint8List payload) {
    if (payload.isEmpty || payload.length % 4 != 0) {
      return ParseResult.fail('JustFloat帧长度异常，实际 ${payload.length} 字节');
    }

    final configuredChannelCount = config.channelCount;
    final channelCount =
        configuredChannelCount == 0
            ? payload.length ~/ 4
            : configuredChannelCount;

    if (channelCount < 1 || channelCount > 16) {
      return ParseResult.fail('JustFloat通道数异常: $channelCount');
    }

    final expectedLength = channelCount * 4;
    if (configuredChannelCount > 0 && payload.length != expectedLength) {
      return ParseResult.fail(
        'JustFloat帧长度错误，需要 $expectedLength 字节，实际 ${payload.length} 字节',
      );
    }

    final data = ByteData.sublistView(payload);
    final values = List<double>.generate(
      channelCount,
      (i) => data.getFloat32(i * 4, Endian.little),
      growable: false,
    );
    return ParseResult.ok(values, rawBytes: payload);
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
