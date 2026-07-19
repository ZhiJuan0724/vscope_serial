import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/constants/plot_configuration.dart';
import '../../core/utils/app_logger.dart';
import '../models/parse_result.dart';
import '../models/parser_config.dart';
import 'data_parser.dart';

/// VOFA JustFloat 解析器。
///
/// 帧内容为小端 float32 数组，末尾跟随 VOFA 帧尾：00 00 80 7F。
class JustFloatParser extends IDataParser {
  static const List<int> tail = [0x00, 0x00, 0x80, 0x7F];
  static const int maxPayloadBytes =
      PlotConfiguration.rawChannelCount * Float32List.bytesPerElement;

  final _buffer = <int>[];
  final _controller = StreamController<ParseResult>.broadcast();
  bool _discardingUntilTail = false;
  int _droppedBytes = 0;
  int _resyncCount = 0;
  DateTime? _lastLimitLogAt;

  JustFloatParser([ParserConfig? config])
    : super(config ?? ParserConfig.justFloatDefault());

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
        _buffer.add(byte);
        if (_discardingUntilTail) {
          _droppedBytes++;
          if (_endsWithTail()) {
            results.add(
              ParseResult.fail(
                'JustFloat通道数异常或帧长度超过最大值 $maxPayloadBytes 字节，已重新同步',
              ),
            );
            _buffer.clear();
            _discardingUntilTail = false;
          } else if (_buffer.length > tail.length) {
            _buffer.removeAt(0);
          }
          continue;
        }
        _processAvailableBuffer(results);
      }
      return results;
    } catch (e) {
      AppLogger().debug('JustFloat 解析异常: $e', category: 'PARSER');
      return const [];
    }
  }

  void _processAvailableBuffer(List<ParseResult> results) {
    final configuredChannels = config.channelCount;
    final expectedPayloadBytes =
        configuredChannels * Float32List.bytesPerElement;
    final maximumPayload =
        configuredChannels > 0 ? expectedPayloadBytes : maxPayloadBytes;

    if (configuredChannels > 0) {
      final expectedFrameBytes = expectedPayloadBytes + tail.length;
      if (_buffer.length < expectedFrameBytes) return;
      if (_endsWithTail()) {
        results.add(
          _parsePayload(
            Uint8List.fromList(_buffer.take(expectedPayloadBytes).toList()),
          ),
        );
        _buffer.clear();
        return;
      }
      _enterResync();
      return;
    }

    if (_endsWithTail()) {
      final payloadLength = _buffer.length - tail.length;
      results.add(
        _parsePayload(Uint8List.fromList(_buffer.take(payloadLength).toList())),
      );
      _buffer.clear();
      return;
    }
    if (_buffer.length > maximumPayload + tail.length) {
      _enterResync();
    }
  }

  bool _endsWithTail() {
    if (_buffer.length < tail.length) return false;
    final start = _buffer.length - tail.length;
    for (var i = 0; i < tail.length; i++) {
      if (_buffer[start + i] != tail[i]) return false;
    }
    return true;
  }

  void _enterResync() {
    final retainedSuffixLength = _tailPrefixSuffixLength();
    final retained =
        retainedSuffixLength == 0
            ? const <int>[]
            : _buffer.sublist(_buffer.length - retainedSuffixLength);
    _droppedBytes += _buffer.length - retainedSuffixLength;
    _buffer
      ..clear()
      ..addAll(retained);
    _discardingUntilTail = true;
    _resyncCount++;
    final now = DateTime.now();
    if (_lastLimitLogAt != null &&
        now.difference(_lastLimitLogAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastLimitLogAt = now;
    AppLogger().warning(
      'JustFloat 帧超过允许长度，已丢弃并等待下一处帧尾重新同步；'
      '累计丢弃 $_droppedBytes 字节',
      category: 'PARSER',
    );
  }

  int _tailPrefixSuffixLength() {
    final maximum = math.min(tail.length - 1, _buffer.length);
    for (var length = maximum; length > 0; length--) {
      var matches = true;
      final start = _buffer.length - length;
      for (var i = 0; i < length; i++) {
        if (_buffer[start + i] != tail[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return length;
    }
    return 0;
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

    if (channelCount < 1 || channelCount > PlotConfiguration.rawChannelCount) {
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
    _discardingUntilTail = false;
  }

  @override
  void dispose() {
    _controller.close();
  }
}
