import 'dart:io';
import 'dart:typed_data';

/// HEX查看器中的一段带32位地址的数据。
class FlashDataSegment {
  const FlashDataSegment(this.address, this.data);

  final int address;
  final Uint8List data;
  int get endAddress => address + data.length;
}

/// 文件或芯片读取结果在HEX查看器中的统一文档。
class FlashDataDocument {
  FlashDataDocument({
    required this.id,
    required this.name,
    required List<FlashDataSegment> segments,
    this.sourcePath,
    this.sourceBinAddress,
  }) : segments = _mergeSegments(segments);

  final String id;
  final String name;
  final List<FlashDataSegment> segments;
  final String? sourcePath;
  final int? sourceBinAddress;

  bool get isEmpty => segments.isEmpty;
  int get firstAddress => segments.isEmpty ? 0 : segments.first.address;

  static Future<FlashDataDocument> open(String path, {int? binAddress}) async {
    final bytes = await File(path).readAsBytes();
    final lower = path.toLowerCase();
    final name = path.split(RegExp(r'[\\/]')).last;
    final segments = switch (lower) {
      final String value when value.endsWith('.bin') => [
        FlashDataSegment(
          _validateRange(binAddress ?? 0, bytes.length),
          Uint8List.fromList(bytes),
        ),
      ],
      final String value when value.endsWith('.hex') => _parseIntelHex(bytes),
      final String value when value.endsWith('.elf') => _parseElf(bytes),
      _ => throw const FormatException('仅支持 ELF、HEX 和 BIN 文件'),
    };
    if (segments.isEmpty) throw const FormatException('文件中没有可显示的数据');
    return FlashDataDocument(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      segments: segments,
      sourcePath: path,
      sourceBinAddress: lower.endsWith('.bin') ? binAddress ?? 0 : null,
    );
  }

  static FlashDataDocument fromRead({
    required String name,
    required int address,
    required Uint8List data,
  }) => FlashDataDocument(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    name: name,
    segments: [
      FlashDataSegment(
        _validateRange(address, data.length),
        Uint8List.fromList(data),
      ),
    ],
    sourceBinAddress: address,
  );

  /// BIN无法表达稀疏地址，空洞以Flash擦除值0xFF填充。
  Uint8List toBinary() {
    if (segments.isEmpty) return Uint8List(0);
    final start = segments.first.address;
    final end = segments.last.endAddress;
    final length = end - start;
    if (length > 0x10000000) {
      throw const FormatException('数据地址跨度超过256 MiB，不能导出为单个BIN文件');
    }
    final result = Uint8List(length)..fillRange(0, length, 0xFF);
    for (final segment in segments) {
      result.setRange(
        segment.address - start,
        segment.endAddress - start,
        segment.data,
      );
    }
    return result;
  }

  Uint8List toIntelHex() {
    final lines = <String>[];
    var currentUpper = -1;
    for (final segment in segments) {
      var offset = 0;
      while (offset < segment.data.length) {
        final address = segment.address + offset;
        final upper = address >>> 16;
        if (upper != currentUpper) {
          lines.add(_hexRecord(0, 4, [(upper >>> 8) & 0xFF, upper & 0xFF]));
          currentUpper = upper;
        }
        final boundary = 0x10000 - (address & 0xFFFF);
        final count = [
          16,
          boundary,
          segment.data.length - offset,
        ].reduce((left, right) => left < right ? left : right);
        lines.add(
          _hexRecord(
            address & 0xFFFF,
            0,
            segment.data.sublist(offset, offset + count),
          ),
        );
        offset += count;
      }
    }
    lines.add(':00000001FF');
    return Uint8List.fromList('${lines.join('\r\n')}\r\n'.codeUnits);
  }
}

int _validateRange(int address, int length) {
  if (address < 0 ||
      address > 0xFFFFFFFF ||
      length < 0 ||
      address + length > 0x100000000) {
    throw const FormatException('数据范围超出32位地址空间');
  }
  return address;
}

List<FlashDataSegment> _mergeSegments(List<FlashDataSegment> values) {
  if (values.isEmpty) return const [];
  final sorted = [...values]
    ..sort((left, right) => left.address.compareTo(right.address));
  final result = <FlashDataSegment>[];
  for (final item in sorted) {
    _validateRange(item.address, item.data.length);
    if (item.data.isEmpty) continue;
    if (result.isEmpty || item.address > result.last.endAddress) {
      result.add(FlashDataSegment(item.address, Uint8List.fromList(item.data)));
      continue;
    }
    final previous = result.removeLast();
    final end =
        item.endAddress > previous.endAddress
            ? item.endAddress
            : previous.endAddress;
    final merged = Uint8List(end - previous.address);
    merged.setRange(0, previous.data.length, previous.data);
    merged.setRange(
      item.address - previous.address,
      item.endAddress - previous.address,
      item.data,
    );
    result.add(FlashDataSegment(previous.address, merged));
  }
  return List.unmodifiable(result);
}

List<FlashDataSegment> _parseIntelHex(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final segments = <FlashDataSegment>[];
  var base = 0;
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (!line.startsWith(':') || line.length < 11 || line.length.isEven) {
      throw const FormatException('Intel HEX记录格式无效');
    }
    final record = <int>[];
    for (var index = 1; index < line.length; index += 2) {
      final value = int.tryParse(line.substring(index, index + 2), radix: 16);
      if (value == null) throw const FormatException('Intel HEX包含非十六进制字符');
      record.add(value);
    }
    if ((record.fold<int>(0, (sum, value) => sum + value) & 0xFF) != 0) {
      throw const FormatException('Intel HEX校验和错误');
    }
    final count = record[0];
    if (record.length != count + 5) {
      throw const FormatException('Intel HEX记录长度错误');
    }
    final offset = (record[1] << 8) | record[2];
    final type = record[3];
    final data = record.sublist(4, 4 + count);
    switch (type) {
      case 0:
        final address = base + offset;
        _validateRange(address, data.length);
        segments.add(FlashDataSegment(address, Uint8List.fromList(data)));
        break;
      case 1:
        return _mergeSegments(segments);
      case 2:
        if (data.length != 2) throw const FormatException('HEX段地址记录无效');
        base = ((data[0] << 8) | data[1]) << 4;
        break;
      case 4:
        if (data.length != 2) throw const FormatException('HEX线性地址记录无效');
        base = ((data[0] << 8) | data[1]) << 16;
        break;
      case 3 || 5:
        break;
      default:
        throw FormatException('不支持的Intel HEX记录类型：$type');
    }
  }
  return _mergeSegments(segments);
}

List<FlashDataSegment> _parseElf(Uint8List bytes) {
  if (bytes.length < 64 ||
      bytes[0] != 0x7F ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4C ||
      bytes[3] != 0x46) {
    throw const FormatException('所选文件不是有效ELF文件');
  }
  final is64 = switch (bytes[4]) {
    1 => false,
    2 => true,
    _ => throw const FormatException('不支持的ELF位数'),
  };
  final endian = switch (bytes[5]) {
    1 => Endian.little,
    2 => Endian.big,
    _ => throw const FormatException('不支持的ELF字节序'),
  };
  final view = ByteData.sublistView(bytes);
  int u16(int offset) => view.getUint16(offset, endian);
  int u32(int offset) => view.getUint32(offset, endian);
  int word(int offset) =>
      is64 ? view.getUint64(offset, endian) : view.getUint32(offset, endian);
  final headerSize = is64 ? 64 : 52;
  if (bytes.length < headerSize) throw const FormatException('ELF文件头不完整');
  final tableOffset = word(is64 ? 0x20 : 0x1C);
  final entrySize = u16(is64 ? 0x36 : 0x2A);
  final entryCount = u16(is64 ? 0x38 : 0x2C);
  if (entrySize == 0 || tableOffset + entrySize * entryCount > bytes.length) {
    throw const FormatException('ELF程序头表超出文件范围');
  }
  final result = <FlashDataSegment>[];
  for (var index = 0; index < entryCount; index++) {
    final offset = tableOffset + index * entrySize;
    if (u32(offset) != 1) continue; // PT_LOAD
    final fileOffset = word(offset + (is64 ? 8 : 4));
    final virtualAddress = word(offset + (is64 ? 16 : 8));
    final physicalAddress = word(offset + (is64 ? 24 : 12));
    final fileSize = word(offset + (is64 ? 32 : 16));
    final address = physicalAddress == 0 ? virtualAddress : physicalAddress;
    if (fileSize == 0) continue;
    if (fileOffset + fileSize > bytes.length) {
      throw const FormatException('ELF装载段超出文件范围');
    }
    _validateRange(address, fileSize);
    result.add(
      FlashDataSegment(
        address,
        Uint8List.fromList(bytes.sublist(fileOffset, fileOffset + fileSize)),
      ),
    );
  }
  return _mergeSegments(result);
}

String _hexRecord(int address, int type, List<int> data) {
  final values = [
    data.length,
    (address >>> 8) & 0xFF,
    address & 0xFF,
    type,
    ...data,
  ];
  final checksum = (-values.fold<int>(0, (sum, value) => sum + value)) & 0xFF;
  String byte(int value) =>
      value.toRadixString(16).toUpperCase().padLeft(2, '0');
  return ':${[...values, checksum].map(byte).join()}';
}
