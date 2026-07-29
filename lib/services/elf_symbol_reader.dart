import 'dart:io';
import 'dart:typed_data';

import '../data/models/probe_plot_config.dart';

/// 只读解析 ELF32/ELF64 符号表，不启动调试后端，也不会访问目标芯片。
Future<List<ProbeSymbolInfo>> readElfDataSymbols(String path) async {
  final bytes = await File(path).readAsBytes();
  if (bytes.length < 64 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    throw const FormatException('所选文件不是 ELF；非 ELF 格式的 .out 不受支持');
  }
  final is64 = switch (bytes[4]) {
    1 => false,
    2 => true,
    _ => throw const FormatException('不支持的 ELF 位数'),
  };
  final endian = switch (bytes[5]) {
    1 => Endian.little,
    2 => Endian.big,
    _ => throw const FormatException('不支持的 ELF 字节序'),
  };
  final data = ByteData.sublistView(bytes);
  int u16(int offset) => data.getUint16(offset, endian);
  int u32(int offset) => data.getUint32(offset, endian);
  int word(int offset) =>
      is64 ? data.getUint64(offset, endian) : data.getUint32(offset, endian);

  final sectionOffset = word(is64 ? 0x28 : 0x20);
  final sectionEntrySize = u16(is64 ? 0x3a : 0x2e);
  final sectionCount = u16(is64 ? 0x3c : 0x30);
  if (sectionEntrySize == 0 || sectionCount == 0) return const [];
  if (sectionOffset < 0 ||
      sectionOffset + sectionEntrySize * sectionCount > bytes.length) {
    throw const FormatException('ELF 节表超出文件范围');
  }

  final sections = <_ElfSection>[];
  for (var index = 0; index < sectionCount; index++) {
    final base = sectionOffset + index * sectionEntrySize;
    final section = _ElfSection(
      type: u32(base + 4),
      offset: word(base + (is64 ? 24 : 16)),
      size: word(base + (is64 ? 32 : 20)),
      link: u32(base + (is64 ? 40 : 24)),
      entrySize: word(base + (is64 ? 56 : 36)),
    );
    if (section.offset < 0 ||
        section.size < 0 ||
        section.offset + section.size > bytes.length) {
      throw const FormatException('ELF 节内容超出文件范围');
    }
    sections.add(section);
  }

  final symbols = <ProbeSymbolInfo>[];
  for (final section in sections.where(
    (item) => item.type == 2 || item.type == 11,
  )) {
    if (section.link >= sections.length) continue;
    final strings = sections[section.link];
    final entrySize =
        section.entrySize == 0 ? (is64 ? 24 : 16) : section.entrySize;
    if (entrySize < (is64 ? 24 : 16)) continue;
    final count = section.size ~/ entrySize;
    for (var index = 0; index < count; index++) {
      final base = section.offset + index * entrySize;
      final nameOffset = u32(base);
      final info = bytes[base + (is64 ? 4 : 12)];
      final type = info & 0x0f;
      if (type != 1) continue; // STT_OBJECT
      final address = word(base + (is64 ? 8 : 4));
      final size = word(base + (is64 ? 16 : 8));
      if (address == 0 || nameOffset >= strings.size) continue;
      final name = _readCString(bytes, strings.offset + nameOffset, strings);
      if (name.isEmpty) continue;
      symbols.add(
        ProbeSymbolInfo(
          name: name,
          address: address,
          size: size,
          source: section.type == 2 ? 'symbol' : 'dynamic-symbol',
        ),
      );
    }
  }
  symbols.sort((left, right) => left.name.compareTo(right.name));
  return symbols;
}

String _readCString(Uint8List bytes, int start, _ElfSection strings) {
  final endLimit = strings.offset + strings.size;
  if (start < strings.offset || start >= endLimit) return '';
  var end = start;
  while (end < endLimit && bytes[end] != 0) {
    end++;
  }
  return String.fromCharCodes(bytes.sublist(start, end));
}

class _ElfSection {
  const _ElfSection({
    required this.type,
    required this.offset,
    required this.size,
    required this.link,
    required this.entrySize,
  });

  final int type;
  final int offset;
  final int size;
  final int link;
  final int entrySize;
}
