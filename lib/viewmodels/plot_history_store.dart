import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/constants/plot_configuration.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/parse_result.dart';
import '../data/models/parser_config.dart';
import '../data/models/plot_lod_index.dart';
import '../data/parser/fixed_frame_parser.dart';
import '../data/parser/zobow_parser.dart';

/// 绘图全量历史的唯一资源所有者。
///
/// 文本协议保存紧凑解析值，固定帧协议保存原始帧；所有协议共用同一个
/// 增量 LOD。调用方只能通过有语义的追加、读取和重建接口访问这些资源。
class PlotHistoryStore {
  final _ParsedValueHistory _parsed = _ParsedValueHistory();
  final PlotLodIndex _lod = PlotLodIndex();
  ParserType? _historyParserType;
  bool _containsImportedData = false;
  FixedPacketByteBuffer _zobowFrames = FixedPacketByteBuffer(
    packetSize: ZobowParser.frameLengthForConfig(ParserConfig.zobowDefault()),
  );
  FixedPacketByteBuffer _fixedFrames = FixedPacketByteBuffer(
    packetSize: ParserConfig.fixedFrameDefault().totalFrameLength,
  );

  PlotLodSource get lodSource => _lod;
  int get lodEstimatedAllocatedBytes => _lod.estimatedAllocatedBytes;
  int get parsedAllocatedValueSlots => _parsed.allocatedValueSlots;
  int get parsedMaxChannelCount => _parsed.maxChannelCount;
  int get parsedLength => _parsed.length;
  int get zobowFrameCount => _zobowFrames.packetCount;
  int get fixedFrameCount => _fixedFrames.packetCount;
  bool get hasParsedValues => _parsed.isNotEmpty;
  bool get hasZobowFrames => _zobowFrames.isNotEmpty;
  bool get hasFixedFrames => _fixedFrames.isNotEmpty;

  int get estimatedAllocatedBytes =>
      _parsed.allocatedBytes +
      _zobowFrames.allocatedCapacity +
      _fixedFrames.allocatedCapacity +
      _lod.estimatedAllocatedBytes;

  int pointCount(ParserType parserType) {
    if (parserType == ParserType.zobow && hasZobowFrames) {
      return zobowFrameCount;
    }
    if (parserType == ParserType.fixedFrame && hasFixedFrames) {
      return fixedFrameCount;
    }
    return parsedLength;
  }

  bool isCompatible(ParserType parserType, int expectedPointCount) {
    // “保持绘图”只续接实时数据流；导入历史用于查看和导出，不与后续接收拼接。
    if (_containsImportedData) return false;
    if (_historyParserType != parserType) return false;
    return switch (parserType) {
      ParserType.fireWater || ParserType.justFloat =>
        parsedLength == expectedPointCount &&
            !hasZobowFrames &&
            !hasFixedFrames,
      ParserType.zobow =>
        zobowFrameCount == expectedPointCount &&
            !hasParsedValues &&
            !hasFixedFrames,
      ParserType.fixedFrame =>
        fixedFrameCount == expectedPointCount &&
            !hasParsedValues &&
            !hasZobowFrames,
    };
  }

  void clear() {
    _historyParserType = null;
    _containsImportedData = false;
    _parsed.clear();
    _lod.clear();
    _zobowFrames.clear();
    _fixedFrames.clear();
  }

  /// 追加协议结果，并返回当前点可直接用于精确窗口的只读值视图。
  List<double> appendResult(ParseResult result, ParserType parserType) {
    _historyParserType ??= parserType;
    final values = result.values!;
    if (parserType == ParserType.zobow && result.rawBytes != null) {
      _zobowFrames.appendPacket(result.rawBytes!);
      return values;
    }
    if (parserType == ParserType.fixedFrame && result.rawBytes != null) {
      _fixedFrames.appendPacket(result.rawBytes!);
      return values;
    }
    final historyIndex = _parsed.length;
    _parsed.add(values);
    return _ParsedHistoryValues(_parsed, historyIndex);
  }

  int projectedAdditionalBytes({
    required ParseResult result,
    required ParserType parserType,
    required int pointIndex,
    required int lodChannelCount,
  }) {
    final values = result.values!;
    var additional = _lod.estimatedAdditionalBytesFor(
      pointIndex,
      lodChannelCount,
    );
    if (parserType == ParserType.zobow && result.rawBytes != null) {
      additional += _zobowFrames.additionalAllocatedCapacityForAppend(
        result.rawBytes!.length,
      );
    } else if (parserType == ParserType.fixedFrame && result.rawBytes != null) {
      additional += _fixedFrames.additionalAllocatedCapacityForAppend(
        result.rawBytes!.length,
      );
    } else {
      additional += _parsed.additionalAllocatedBytesForAppend(values.length);
    }
    return additional;
  }

  List<double> valuesAt(
    int pointIndex,
    ParserType parserType,
    ParserConfig parserConfig,
  ) {
    if (pointIndex < 0 || pointIndex >= pointCount(parserType)) {
      return const [];
    }
    if (parserType == ParserType.zobow && hasZobowFrames) {
      return ZobowParser.decodeFrameValues(
        _zobowFrames.readPacket(pointIndex),
        parserConfig,
      );
    }
    if (parserType == ParserType.fixedFrame && hasFixedFrames) {
      return FixedFrameParser.decodeFrameValues(
        _fixedFrames.readPacket(pointIndex),
        parserConfig,
      );
    }
    return _parsed.valuesAt(pointIndex);
  }

  List<double> parsedValuesViewAt(int pointIndex) =>
      _ParsedHistoryValues(_parsed, pointIndex);

  double valueAt(
    int pointIndex,
    int channelIndex,
    ParserType parserType,
    ParserConfig parserConfig,
  ) {
    if (pointIndex < 0 ||
        pointIndex >= pointCount(parserType) ||
        channelIndex < 0) {
      return double.nan;
    }
    if (parserType != ParserType.zobow &&
        !(parserType == ParserType.fixedFrame && hasFixedFrames)) {
      final count = _parsed.valueCountAt(pointIndex);
      return channelIndex < count
          ? _parsed.valueAt(pointIndex, channelIndex)
          : double.nan;
    }
    final values = valuesAt(pointIndex, parserType, parserConfig);
    return channelIndex < values.length ? values[channelIndex] : double.nan;
  }

  int parsedValueCountAt(int pointIndex) => _parsed.valueCountAt(pointIndex);

  double parsedValueAt(int pointIndex, int channelIndex) =>
      _parsed.valueAt(pointIndex, channelIndex);

  Uint8List readZobowFrame(int pointIndex) =>
      _zobowFrames.readPacket(pointIndex);

  Uint8List readFixedFrame(int pointIndex) =>
      _fixedFrames.readPacket(pointIndex);

  void addLod(int pointIndex, List<double> values) {
    _lod.add(pointIndex, values);
  }

  void addSampledLod(int pointIndex, List<double> values, int sampleStep) {
    _lod.addSampled(pointIndex, values, sampleStep);
  }

  void clearLod() => _lod.clear();

  PlotLodSeries? queryLod({
    required int channelIndex,
    required double xMin,
    required double xMax,
    required double plotWidth,
    PlotLodQuality quality = PlotLodQuality.performance,
  }) {
    return _lod.query(
      channelIndex: channelIndex,
      xMin: xMin,
      xMax: xMax,
      plotWidth: plotWidth,
      quality: quality,
    );
  }

  void resetZobowFrames(int packetSize) {
    _zobowFrames = FixedPacketByteBuffer(packetSize: packetSize);
  }

  void resetFixedFrames(int packetSize) {
    _fixedFrames = FixedPacketByteBuffer(packetSize: packetSize);
  }

  /// 导入事务通过此入口提交已验证的普通解析点。
  void appendImportedParsedPoint(
    int pointIndex,
    List<double> values,
    ParserType parserType,
  ) {
    if (pointIndex != _parsed.length) {
      throw StateError('导入点序号不连续: expected=${_parsed.length}, got=$pointIndex');
    }
    _historyParserType ??= parserType;
    _containsImportedData = true;
    _parsed.add(values);
    _lod.add(pointIndex, values);
  }

  void debugSetParsedLength(
    int length, {
    int maxChannelCount = PlotConfiguration.rawChannelCount,
  }) {
    _historyParserType = ParserType.fireWater;
    _parsed.debugSetLengthForTest(length, maxChannelCount: maxChannelCount);
  }
}

class _ParsedValueHistory {
  static const int _chunkPointCount = 4096;
  static const int _maxChannels = PlotConfiguration.rawChannelCount;

  final List<_ParsedValueChunk> _chunks = [];
  int _length = 0;
  int _maxChannelCount = 0;
  int _allocatedBytes = 0;

  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length > 0;
  int get length => _length;
  int get maxChannelCount => _maxChannelCount;
  int get allocatedValueSlots =>
      _chunks.fold(0, (total, chunk) => total + chunk.allocatedValueSlots);
  int get allocatedBytes => _allocatedBytes;

  int additionalAllocatedBytesForAppend(int channelCount) {
    if (_length % _chunkPointCount != 0) {
      final chunk = _chunks.isEmpty ? null : _chunks.last;
      return chunk?.additionalAllocatedBytesForChannels(channelCount) ?? 0;
    }
    final capacity = channelCount.clamp(1, _maxChannels);
    return _chunkPointCount *
        (capacity * Float64List.bytesPerElement + Uint8List.bytesPerElement);
  }

  void debugSetLengthForTest(
    int length, {
    int maxChannelCount = PlotConfiguration.rawChannelCount,
  }) {
    _chunks.clear();
    _length = length;
    _maxChannelCount = maxChannelCount.clamp(0, _maxChannels).toInt();
    _allocatedBytes = 0;
  }

  void clear() {
    _chunks.clear();
    _length = 0;
    _maxChannelCount = 0;
    _allocatedBytes = 0;
  }

  void add(List<double> values) {
    final chunkIndex = _length ~/ _chunkPointCount;
    if (chunkIndex == _chunks.length) {
      final chunk = _ParsedValueChunk(
        pointCapacity: _chunkPointCount,
        channelCapacity: values.length.clamp(1, _maxChannels),
      );
      _chunks.add(chunk);
      _allocatedBytes += chunk.allocatedBytes;
    }

    final count = values.length.clamp(0, _maxChannels).toInt();
    final chunk = _chunks[chunkIndex];
    final previousBytes = chunk.allocatedBytes;
    chunk.add(values, count);
    _allocatedBytes += chunk.allocatedBytes - previousBytes;
    if (count > _maxChannelCount) _maxChannelCount = count;
    _length++;
  }

  List<double> valuesAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    return _chunks[index ~/ _chunkPointCount].valuesAt(
      index % _chunkPointCount,
    );
  }

  int valueCountAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    return _chunks[index ~/ _chunkPointCount].valueCountAt(
      index % _chunkPointCount,
    );
  }

  double valueAt(int pointIndex, int channelIndex) {
    RangeError.checkValueInInterval(pointIndex, 0, _length - 1, 'pointIndex');
    return _chunks[pointIndex ~/ _chunkPointCount].valueAt(
      pointIndex % _chunkPointCount,
      channelIndex,
    );
  }
}

class _ParsedValueChunk {
  final int pointCapacity;
  int channelCapacity;
  late Float64List _values;
  final Uint8List _counts;
  int _length = 0;

  _ParsedValueChunk({
    required this.pointCapacity,
    required this.channelCapacity,
  }) : _counts = Uint8List(pointCapacity) {
    _values = Float64List(pointCapacity * channelCapacity);
  }

  int get allocatedValueSlots => _values.length;
  int get allocatedBytes =>
      _values.length * Float64List.bytesPerElement + _counts.length;

  int additionalAllocatedBytesForChannels(int nextChannelCapacity) {
    if (nextChannelCapacity <= channelCapacity) return 0;
    final next = nextChannelCapacity.clamp(
      1,
      PlotConfiguration.rawChannelCount,
    );
    return pointCapacity *
        (next - channelCapacity) *
        Float64List.bytesPerElement;
  }

  void add(List<double> values, int count) {
    if (_length >= pointCapacity) {
      throw StateError('parsed value chunk is full');
    }
    if (count > channelCapacity) _growChannels(count);
    _counts[_length] = count;
    final base = _length * channelCapacity;
    for (var index = 0; index < count; index++) {
      _values[base + index] = values[index];
    }
    _length++;
  }

  List<double> valuesAt(int pointOffset) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    final count = _counts[pointOffset];
    final base = pointOffset * channelCapacity;
    return List<double>.generate(
      count,
      (index) => _values[base + index],
      growable: false,
    );
  }

  int valueCountAt(int pointOffset) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    return _counts[pointOffset];
  }

  double valueAt(int pointOffset, int channelIndex) {
    RangeError.checkValueInInterval(pointOffset, 0, _length - 1, 'pointOffset');
    RangeError.checkValueInInterval(
      channelIndex,
      0,
      _counts[pointOffset] - 1,
      'channelIndex',
    );
    return _values[pointOffset * channelCapacity + channelIndex];
  }

  void _growChannels(int nextCapacity) {
    final expanded = Float64List(pointCapacity * nextCapacity);
    for (var point = 0; point < _length; point++) {
      final oldBase = point * channelCapacity;
      final newBase = point * nextCapacity;
      final count = _counts[point];
      expanded.setRange(newBase, newBase + count, _values, oldBase);
    }
    channelCapacity = nextCapacity;
    _values = expanded;
  }
}

class _ParsedHistoryValues extends ListBase<double> {
  final _ParsedValueHistory history;
  final int pointIndex;

  _ParsedHistoryValues(this.history, this.pointIndex);

  @override
  int get length => history.valueCountAt(pointIndex);

  @override
  set length(int value) => throw UnsupportedError('只读视图');

  @override
  double operator [](int index) => history.valueAt(pointIndex, index);

  @override
  void operator []=(int index, double value) {
    throw UnsupportedError('只读视图');
  }
}
