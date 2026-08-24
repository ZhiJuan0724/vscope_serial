import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';

void main() {
  test('分块 CRC 与一次性计算结果一致', () {
    final data = Uint8List.fromList(
      List<int>.generate(10000, (index) => (index * 37) & 0xFF),
    );

    for (final poly in [
      crc8Polys['CRC-8/MAXIM']!,
      crc16Polys['CRC-16/MODBUS']!,
      crc32Polys['CRC-32']!,
    ]) {
      final calculator =
          CrcCalculator(poly)
            ..add(data.sublist(0, 17))
            ..add(data.sublist(17, 4097))
            ..add(data.sublist(4097));

      expect(calculator.digest, calculateCrc(data, poly));
    }
  });
}
