import 'dart:typed_data';

import '../data/models/probe_plot_config.dart';

class JScopeFormat {
  JScopeFormat._(this.fields, this.hasTimestamp);

  final List<ProbeScalarType> fields;
  final bool hasTimestamp;

  int get packetLength =>
      (hasTimestamp ? 4 : 0) +
      fields.fold(0, (total, field) => total + field.byteSize);

  static JScopeFormat parse(String name) {
    if (!name.startsWith('JScope_')) {
      throw const FormatException('RTT 通道名称必须以 JScope_ 开头');
    }
    final body = name.substring(7).toLowerCase();
    final matches = RegExp(r't4|b1|f4|i[124]|u[124]').allMatches(body);
    final tokens = matches.map((match) => match.group(0)!).toList();
    final remainder = body.replaceAll(RegExp(r't4|b1|f4|i[124]|u[124]'), '');
    if (remainder.replaceAll(RegExp(r'[_ ,;]+'), '').isNotEmpty) {
      throw FormatException('不支持的 J-Scope 格式: $name');
    }
    var hasTimestamp = false;
    final fields = <ProbeScalarType>[];
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index].trim().toLowerCase();
      if (token.isEmpty) continue;
      if (token == 't4' && index == 0) {
        hasTimestamp = true;
        continue;
      }
      final type = switch (token) {
        'b1' => ProbeScalarType.boolean,
        'f4' => ProbeScalarType.float32,
        'i1' => ProbeScalarType.int8,
        'i2' => ProbeScalarType.int16,
        'i4' => ProbeScalarType.int32,
        'u1' => ProbeScalarType.uint8,
        'u2' => ProbeScalarType.uint16,
        'u4' => ProbeScalarType.uint32,
        _ => throw FormatException('不支持的 J-Scope 字段: $token'),
      };
      fields.add(type);
    }
    if (fields.isEmpty || fields.length > 12) {
      throw const FormatException('J-Scope 必须包含 1～12 个数值字段');
    }
    return JScopeFormat._(fields, hasTimestamp);
  }

  static JScopeFormat? tryParse(String name) {
    try {
      return parse(name);
    } on FormatException {
      return null;
    }
  }

  @Deprecated('Use parse')
  static JScopeFormat parseChannelName(String name) => parse(name);
}

class JScopeSample {
  const JScopeSample(this.x, this.values);
  final double x;
  final List<double> values;
}

/// 固定包长 J-Scope RTT 增量解析器，支持任意分包和粘包。
class JScopeRttParser {
  JScopeRttParser(this.format);

  final JScopeFormat format;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _sampleIndex = 0;
  int? _lastTimestamp;
  int _timestampWrapBase = 0;

  List<JScopeSample> add(Uint8List data) {
    _pending.add(data);
    final bytes = _pending.takeBytes();
    final result = <JScopeSample>[];
    var offset = 0;
    while (bytes.length - offset >= format.packetLength) {
      final packet = ByteData.sublistView(
        bytes,
        offset,
        offset + format.packetLength,
      );
      var cursor = 0;
      double x;
      if (format.hasTimestamp) {
        final timestamp = packet.getUint32(cursor, Endian.little);
        cursor += 4;
        if (_lastTimestamp != null && timestamp < _lastTimestamp!) {
          _timestampWrapBase += 0x100000000;
        }
        _lastTimestamp = timestamp;
        x = (_timestampWrapBase + timestamp) / 1000000.0;
      } else {
        x = _sampleIndex.toDouble();
      }
      final values = <double>[];
      for (final field in format.fields) {
        values.add(_readValue(packet, cursor, field));
        cursor += field.byteSize;
      }
      result.add(JScopeSample(x, values));
      _sampleIndex++;
      offset += format.packetLength;
    }
    if (offset < bytes.length) _pending.add(bytes.sublist(offset));
    return result;
  }

  void reset() {
    _pending.takeBytes();
    _sampleIndex = 0;
    _lastTimestamp = null;
    _timestampWrapBase = 0;
  }

  double _readValue(
    ByteData data,
    int offset,
    ProbeScalarType type,
  ) => switch (type) {
    ProbeScalarType.boolean => data.getUint8(offset) == 0 ? 0.0 : 1.0,
    ProbeScalarType.int8 => data.getInt8(offset).toDouble(),
    ProbeScalarType.int16 => data.getInt16(offset, Endian.little).toDouble(),
    ProbeScalarType.int32 => data.getInt32(offset, Endian.little).toDouble(),
    ProbeScalarType.uint8 => data.getUint8(offset).toDouble(),
    ProbeScalarType.uint16 => data.getUint16(offset, Endian.little).toDouble(),
    ProbeScalarType.uint32 => data.getUint32(offset, Endian.little).toDouble(),
    ProbeScalarType.float32 =>
      data.getFloat32(offset, Endian.little).toDouble(),
    _ => throw FormatException('J-Scope 不支持 ${type.label}'),
  };
}
