import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/services/serial_service.dart';

void main() {
  group('SerialService raw data display', () {
    late SerialService service;

    setUp(() {
      service = SerialService();
      service.clearReceivedData();
      service.setReceiveHex(false);
      service.setShowTimestamp(false);
      service.sendHex = false;
    });

    tearDown(() {
      service.clearReceivedData();
      service.setReceiveHex(false);
      service.setShowTimestamp(false);
      service.sendHex = false;
    });

    test(
      'text mode wraps only on newline characters and hides byte counts',
      () {
        service.debugAddRawReceiveData(_utf8('abc'));
        service.debugAddRawReceiveData(_utf8('def\r\nnext'));

        expect(service.receivedLines, ['abcdef', 'next']);
        expect(service.receivedLines.join('\n'), isNot(contains('bytes')));
        expect(service.receivedLines.join('\n'), isNot(contains('←')));
        expect(service.dataStats.containsKey('原始字节'), isFalse);
      },
    );

    test('text mode shows receive marker only when timestamp is enabled', () {
      service.setShowTimestamp(true);
      service.debugAddRawReceiveData(
        _utf8('line\n'),
        timestamp: DateTime(2026, 5, 28, 9, 8, 7, 123),
      );

      expect(service.receivedLines.single, startsWith('← [09:08:07.123] line'));
      expect(service.receivedLines.single, isNot(contains('bytes')));
    });

    test('hex mode keeps byte counts but hides markers without timestamp', () {
      service.setReceiveHex(true);
      service.debugAddRawReceiveData(Uint8List.fromList([0x01, 0xAB]));

      expect(service.receivedLines.single, '01 AB (2 bytes)');
      expect(service.dataStats.containsKey('原始字节'), isTrue);
    });

    test('text send data can append configured line ending', () {
      service.appendLineEnding = true;

      service.lineEnding = '\r';
      expect(utf8.decode(service.prepareTextSendData('AT')), 'AT\r');

      service.lineEnding = '\n';
      expect(utf8.decode(service.prepareTextSendData('AT')), 'AT\n');

      service.lineEnding = '\r\n';
      expect(utf8.decode(service.prepareTextSendData('AT')), 'AT\r\n');
    });

    test('hex send appends CRC using selected byte order', () {
      service.sendHex = true;
      service.enableCrc = true;
      service.crcType = CrcType.crc16;
      service.crcPolyName = 'CRC-16/MODBUS';

      service.crcByteOrder = CrcByteOrder.big;
      final bigEndian = service.prepareSendDataForTest('0102')!;

      service.crcByteOrder = CrcByteOrder.little;
      final littleEndian = service.prepareSendDataForTest('0102')!;

      expect(bigEndian.take(2), [0x01, 0x02]);
      expect(littleEndian.take(2), [0x01, 0x02]);
      expect(bigEndian.skip(2), littleEndian.skip(2).toList().reversed);
    });

    test('plot binary send is marked and displayed as hex', () {
      service.sendHex = false;
      service.debugAddPlotSendDataForTest(
        Uint8List.fromList([0x01, 0x02, 0xFF]),
        displayAsHex: true,
      );

      expect(service.receivedLines.single, '[绘图发送] [HEX] 01 02 FF (3 bytes)');
    });

    test('user hex send keeps original display marker', () {
      service.sendHex = true;
      service.debugAddSendData(Uint8List.fromList([0x01, 0x02]));

      expect(service.receivedLines.single, '[HEX] 01 02 (2 bytes)');
    });

    test('plot text send is marked without forcing hex display', () {
      service.sendHex = true;
      service.debugAddPlotSendDataForTest(
        Uint8List.fromList(utf8.encode('r 1 2\n')),
        displayAsHex: false,
      );

      expect(service.receivedLines.single, '[绘图发送] r 1 2');
    });
  });
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));
