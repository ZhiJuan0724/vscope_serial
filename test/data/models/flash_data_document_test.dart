import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/flash_data_document.dart';

void main() {
  test('BIN按指定32位基地址打开并保留数据', () async {
    final directory = await Directory.systemTemp.createTemp('flash_document_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}demo.bin');
    await file.writeAsBytes([1, 2, 3, 4]);

    final document = await FlashDataDocument.open(
      file.path,
      binAddress: 0xFFFF_FFFC,
    );

    expect(document.firstAddress, 0xFFFF_FFFC);
    expect(document.segments.single.data, [1, 2, 3, 4]);
  });

  test('超出32位地址空间的BIN被拒绝', () async {
    final directory = await Directory.systemTemp.createTemp('flash_document_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}demo.bin');
    await file.writeAsBytes([1, 2]);

    await expectLater(
      FlashDataDocument.open(file.path, binAddress: 0xFFFF_FFFF),
      throwsFormatException,
    );
  });

  test('稀疏数据导出Intel HEX后可按原地址重新打开', () async {
    final original = FlashDataDocument(
      id: 'source',
      name: 'source',
      segments: [
        FlashDataSegment(0x0800_0000, Uint8List.fromList([0x12, 0x34])),
        FlashDataSegment(0x0800_0020, Uint8List.fromList([0xAB, 0xCD])),
      ],
    );
    final directory = await Directory.systemTemp.createTemp('flash_document_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}demo.hex');
    await file.writeAsBytes(original.toIntelHex());

    final restored = await FlashDataDocument.open(file.path);

    expect(restored.segments, hasLength(2));
    expect(restored.segments[0].address, 0x0800_0000);
    expect(restored.segments[0].data, [0x12, 0x34]);
    expect(restored.segments[1].address, 0x0800_0020);
    expect(restored.segments[1].data, [0xAB, 0xCD]);
  });

  test('导出BIN使用0xFF填充稀疏空洞', () {
    final document = FlashDataDocument(
      id: 'source',
      name: 'source',
      segments: [
        FlashDataSegment(0x1000, Uint8List.fromList([1])),
        FlashDataSegment(0x1003, Uint8List.fromList([2])),
      ],
    );

    expect(document.toBinary(), [1, 0xFF, 0xFF, 2]);
  });
}
