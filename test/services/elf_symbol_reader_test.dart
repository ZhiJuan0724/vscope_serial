import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/elf_symbol_reader.dart';

void main() {
  test('本地 ELF32 解析器读取数据符号且不依赖探针后端', () async {
    final directory = await Directory.systemTemp.createTemp('vscope-elf-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}sample.elf');
    await file.writeAsBytes(_minimalElf32(), flush: true);

    final symbols = await readElfDataSymbols(file.path);

    expect(symbols.single.name, 'counter');
    expect(symbols.single.address, 0x20000000);
    expect(symbols.single.size, 4);
  });
}

Uint8List _minimalElf32() {
  final bytes = Uint8List(0x178);
  final data = ByteData.sublistView(bytes);
  bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 1, 1, 1]);
  data
    ..setUint32(0x20, 0x100, Endian.little)
    ..setUint16(0x2e, 40, Endian.little)
    ..setUint16(0x30, 3, Endian.little)
    ..setUint16(0x32, 0, Endian.little);

  // 符号表：第一个为空，第二个为全局 STT_OBJECT。
  data
    ..setUint32(0x100 + 40 + 4, 2, Endian.little)
    ..setUint32(0x100 + 40 + 16, 0x40, Endian.little)
    ..setUint32(0x100 + 40 + 20, 32, Endian.little)
    ..setUint32(0x100 + 40 + 24, 2, Endian.little)
    ..setUint32(0x100 + 40 + 36, 16, Endian.little)
    ..setUint32(0x100 + 80 + 4, 3, Endian.little)
    ..setUint32(0x100 + 80 + 16, 0x80, Endian.little)
    ..setUint32(0x100 + 80 + 20, 9, Endian.little);
  bytes.setAll(0x80, [0, ...'counter'.codeUnits, 0]);
  data
    ..setUint32(0x40 + 16, 1, Endian.little)
    ..setUint32(0x40 + 20, 0x20000000, Endian.little)
    ..setUint32(0x40 + 24, 4, Endian.little);
  bytes[0x40 + 28] = 0x11;
  return bytes;
}
