import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/data/models/retention_usage.dart';
import 'package:vscope_serial/services/data_connection_service.dart';

void main() {
  group('DataConnectionService raw data display', () {
    late DataConnectionService service;

    setUp(() {
      service = DataConnectionService();
      service.clearReceivedData();
      service.setReceiveHex(false);
      service.setShowTimestamp(false);
      service.setAutoLineBreak(true);
      service.setAutoLineBreakIntervalMs(
        DataConnectionService.defaultAutoLineBreakIntervalMs,
      );
      service.setTextEncoding('UTF-8');
      service.sendHex = false;
      service.setDisplayLineLimit(DataConnectionService.defaultDisplayLineLimit);
    });

    tearDown(() {
      service.debugFlushSendLogForTest();
      service.clearReceivedData();
      service.setReceiveHex(false);
      service.setShowTimestamp(false);
      service.setAutoLineBreak(true);
      service.setAutoLineBreakIntervalMs(
        DataConnectionService.defaultAutoLineBreakIntervalMs,
      );
      service.setTextEncoding('UTF-8');
      service.sendHex = false;
      service.setDisplayLineLimit(DataConnectionService.defaultDisplayLineLimit);
      service.stopRawReceiving();
      service.isConnected = false;
      service.debugRawRetentionLimitBytes = null;
    });

    test(
      'raw retention accepts only the final prefix and resets after clear',
      () {
        service
          ..debugRawRetentionLimitBytes = 10
          ..isConnected = true;
        expect(service.startRawReceiving(), isTrue);

        service.debugFeedRawReceiveData(Uint8List.fromList(List.filled(8, 1)));
        expect(service.rawRetentionUsage.state, RetentionState.warning);
        expect(service.isRawReceiving, isTrue);

        service.debugFeedRawReceiveData(Uint8List.fromList(List.filled(5, 2)));
        expect(service.rawRetentionUsage.usedBytes, 10);
        expect(service.rawRetentionUsage.state, RetentionState.limitReached);
        expect(service.isRawReceiving, isFalse);

        service.clearReceivedData();
        expect(service.rawRetentionUsage.usedBytes, 0);
        expect(service.rawRetentionUsage.state, RetentionState.normal);
        expect(service.startRawReceiving(), isTrue);
      },
    );

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

    test('text mode preserves UTF-8 characters split across packets', () {
      final bytes = utf8.encode('中文\n');

      service.debugAddRawReceiveData(
        Uint8List.fromList(bytes.take(1).toList()),
      );
      service.debugAddRawReceiveData(
        Uint8List.fromList(bytes.skip(1).take(2).toList()),
      );
      service.debugAddRawReceiveData(
        Uint8List.fromList(bytes.skip(3).toList()),
      );

      expect(service.receivedLines, ['中文']);
    });

    test('text mode preserves GBK characters split across packets', () {
      service.setTextEncoding('GBK');
      final bytes = gbk.encode('中文\n');

      for (final byte in bytes) {
        service.debugAddRawReceiveData(Uint8List.fromList([byte]));
      }

      expect(service.receivedLines, ['中文']);
    });

    test('text mode shows receive marker only when timestamp is enabled', () {
      service.setShowTimestamp(true);
      service.debugAddRawReceiveData(
        _utf8('line\n'),
        timestamp: DateTime(2026, 5, 28, 9, 8, 7, 123),
      );

      expect(service.receivedLines.single, startsWith('← [09:08:07.123] line'));
      expect(service.receivedLines.single, isNot(contains('bytes')));
    });

    test('带时间戳的无行尾分包持续更新同一显示行', () {
      service.setShowTimestamp(true);
      service.debugAddRawReceiveData(
        _utf8('1222'),
        timestamp: DateTime(2026, 5, 28, 20, 26, 34, 859),
      );
      service.debugAddRawReceiveData(
        _utf8('11111'),
        timestamp: DateTime(2026, 5, 28, 20, 26, 35, 861),
      );
      service.debugAddRawReceiveData(
        _utf8('1222\n'),
        timestamp: DateTime(2026, 5, 28, 20, 26, 36, 862),
      );

      expect(service.receivedLines, ['← [20:26:34.859] 1222111111222']);
    });

    test('自动换行默认开启且默认时间为100ms', () {
      expect(service.autoLineBreak, isTrue);
      expect(
        service.autoLineBreakIntervalMs,
        DataConnectionService.defaultAutoLineBreakIntervalMs,
      );
    });

    test('自动换行按时间结束文本行且保留文本换行符', () {
      service.setAutoLineBreak(true);
      service.setAutoLineBreakIntervalMs(1);

      service.debugFeedRawReceiveData(_utf8('first\nsecond'));
      service.debugFlushAutoLineBreakForTest();
      service.debugFeedRawReceiveData(_utf8('third'));
      service.debugFlushAutoLineBreakForTest();

      expect(service.receivedLines, ['first', 'second', 'third']);
    });

    test('自动换行与HEX显示和时间戳独立生效', () {
      service.setReceiveHex(true);
      service.setShowTimestamp(false);
      service.setAutoLineBreak(true);
      service.setAutoLineBreakIntervalMs(1);

      // 两包属于同一个接收窗口；固定时刻避免测试结果依赖 CI 机器执行速度。
      final receivedAt = DateTime.utc(2026, 7, 20);
      service.debugFeedRawReceiveData(
        Uint8List.fromList([0x01]),
        timestamp: receivedAt,
      );
      service.debugFeedRawReceiveData(
        Uint8List.fromList([0x02]),
        timestamp: receivedAt,
      );
      service.debugFlushAutoLineBreakForTest();

      expect(service.receivedLines, ['01 02 (2 bytes)']);
    });

    test('hex mode keeps byte counts but hides markers without timestamp', () {
      service.setReceiveHex(true);
      service.debugAddRawReceiveData(Uint8List.fromList([0x01, 0xAB]));

      expect(service.receivedLines.single, '01 AB (2 bytes)');
      expect(service.dataStats.containsKey('完整原始数据'), isTrue);
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

    test('shell line send always appends configured line ending', () {
      service.appendLineEnding = false;
      service.shellLineEnding = '\n';

      expect(utf8.decode(service.prepareShellTextData('help')), 'help\n');
    });

    test('普通文本和Shell文本发送使用设置中的编码', () {
      service.setTextEncoding('GBK');
      service.setShellEncoding('GBK');
      service.appendLineEnding = false;
      service.lineEnding = '\r\n';
      service.shellLineEnding = '\r\n';

      expect(service.prepareTextSendData('中文'), gbk.encode('中文'));
      expect(service.prepareShellTextData('中文'), gbk.encode('中文\r\n'));
      expect(service.encodeText('中文'), gbk.encode('中文'));
    });

    test('Shell文本解码使用当前设置中的编码', () {
      service.setShellEncoding('GBK');

      expect(
        service.decodeShellText(Uint8List.fromList(gbk.encode('中文'))),
        '中文',
      );
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

    test('多条发送不继承普通发送区的行尾或 CRC', () {
      service.setTextEncoding('UTF-8');
      service.appendLineEnding = true;
      service.lineEnding = '\r\n';
      service.sendHex = true;
      service.enableCrc = true;

      expect(
        service.prepareMultiSendDataForTest('AT', isHex: false),
        utf8.encode('AT'),
      );
      expect(service.prepareMultiSendDataForTest('01 02', isHex: true), [1, 2]);
      expect(service.prepareMultiSendDataForTest('0', isHex: true), isNull);
      expect(service.prepareMultiSendDataForTest('0G', isHex: true), isNull);
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

    test('high frequency send logs are batched', () {
      for (var i = 0; i < 10; i++) {
        service.debugRecordSendLogForTest(1029);
      }

      final state = service.debugSendLogState;
      expect(state.highFrequency, isTrue);
      expect(state.packetCount, 10);
      expect(state.bytes, 10290);

      service.debugFlushSendLogForTest();
      expect(service.debugSendLogState.packetCount, 0);
    });

    test('display line limit defaults to 100000 and removes oldest lines', () {
      expect(DataConnectionService.defaultDisplayLineLimit, 100000);
      service.setDisplayLineLimit(100);

      for (var i = 0; i < 105; i++) {
        service.debugAddRawReceiveData(_utf8('line$i\n'));
      }

      expect(service.receivedLines, hasLength(100));
      expect(service.receivedLines.first, 'line5');
      expect(service.receivedLines.last, 'line104');
    });

    test('display line limit keeps FIFO order after continuous eviction', () {
      service.setDisplayLineLimit(100);

      for (var i = 0; i < 10000; i++) {
        service.debugAddRawReceiveData(_utf8('line$i\n'));
      }

      expect(service.receivedLines, hasLength(100));
      expect(service.receivedLines.first, 'line9900');
      expect(service.receivedLines.last, 'line9999');
    });

    test(
      'text export decodes all raw bytes beyond the display line limit',
      () async {
        service.setDisplayLineLimit(100);
        for (var i = 0; i < 105; i++) {
          service.debugAddRawReceiveData(_utf8('line$i\n'));
        }
        expect(service.receivedLines.first, 'line5');

        final outputDirectory = await Directory.systemTemp.createTemp(
          'vscope_text_export_',
        );
        addTearDown(() => outputDirectory.delete(recursive: true));
        final progress = <double>[];
        final path = await service.exportAsText(
          outputDirectory: outputDirectory,
          onProgress: progress.add,
        );
        final content = await File(path!).readAsString();

        expect(content, startsWith('line0\n'));
        expect(content, endsWith('line104\n'));
        expect(const LineSplitter().convert(content), hasLength(105));
        expect(progress.first, 0.05);
        expect(progress.last, 1.0);
        expect(progress.any((value) => (value - 0.95).abs() < 1e-9), isTrue);
      },
    );

    test('没有原始数据时文本和BIN导出均不创建文件', () async {
      final outputDirectory = await Directory.systemTemp.createTemp(
        'vscope_empty_export_',
      );
      addTearDown(() => outputDirectory.delete(recursive: true));

      expect(service.hasRawData, isFalse);
      expect(
        await service.exportAsText(outputDirectory: outputDirectory),
        isNull,
      );
      expect(
        await service.exportAsRawBytes(outputDirectory: outputDirectory),
        isNull,
      );
      expect(await outputDirectory.list().toList(), isEmpty);
    });

    test('raw export reports progress while building CRC payload', () async {
      service.debugAddRawReceiveData(Uint8List.fromList([1, 2, 3, 4]));
      final outputDirectory = await Directory.systemTemp.createTemp(
        'vscope_raw_export_',
      );
      addTearDown(() => outputDirectory.delete(recursive: true));
      final progress = <double>[];

      final path = await service.exportAsRawBytes(
        outputDirectory: outputDirectory,
        onProgress: progress.add,
      );
      final output = await File(path!).readAsBytes();

      expect(output.sublist(0, 4), [1, 2, 3, 4]);
      expect(output, hasLength(8));
      expect(progress.first, 0.05);
      expect(progress.last, 1.0);
      expect(progress.any((value) => (value - 0.95).abs() < 1e-9), isTrue);
    });
  });
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));
