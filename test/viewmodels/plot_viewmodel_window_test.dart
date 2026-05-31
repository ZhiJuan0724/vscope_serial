import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/parser/zobow_parser.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

Uint8List _zobowFrame(int value) {
  final bytes = Uint8List(10);
  final data = ByteData.sublistView(bytes);
  for (int i = 0; i < 4; i++) {
    data.setUint16(i * 2, (value + i) & 0xFFFF, Endian.little);
  }
  final crc = calculateCrc(
    Uint8List.sublistView(bytes, 0, 8),
    crc16Polys['CRC-16/MODBUS']!,
  );
  bytes[8] = crc & 0xFF;
  bytes[9] = (crc >> 8) & 0xFF;
  return bytes;
}

Uint8List _zobowFrameWithValues(List<int> values) {
  final bytes = Uint8List(10);
  final data = ByteData.sublistView(bytes);
  for (int i = 0; i < 4; i++) {
    data.setUint16(i * 2, values[i] & 0xFFFF, Endian.little);
  }
  final crc = calculateCrc(
    Uint8List.sublistView(bytes, 0, 8),
    crc16Polys['CRC-16/MODBUS']!,
  );
  bytes[8] = crc & 0xFF;
  bytes[9] = (crc >> 8) & 0xFF;
  return bytes;
}

void main() {
  group('PlotViewModel windowed Zobow data', () {
    late PlotViewModel vm;

    setUp(() {
      vm = PlotViewModel(SerialService());
      vm.setParserType(ParserType.zobow);
    });

    tearDown(() {
      vm.dispose();
    });

    test('keeps total point count while visible window is below cap', () {
      const total = 70000;
      for (int i = 0; i < total; i++) {
        final frame = _zobowFrame(i);
        vm.ingestParsedResultForTest(
          ParseResult.ok(
            ZobowParser.decodeFrameValues(frame, vm.parserConfig),
            bytesConsumed: 10,
            rawBytes: frame,
          ),
        );
      }

      expect(vm.pointCount, total);
      expect(vm.dataPoints.length, total);
      expect(vm.visibleStartIndex, 0);
      expect(vm.dataPoints.first.index, 0);
      expect(vm.dataPoints.last.index, total - 1);
    });

    test(
      'historical viewport stays inside loaded exact window when below cap',
      () {
        const total = 70000;
        for (int i = 0; i < total; i++) {
          final frame = _zobowFrame(i);
          vm.ingestParsedResultForTest(
            ParseResult.ok(
              ZobowParser.decodeFrameValues(frame, vm.parserConfig),
              bytesConsumed: 10,
              rawBytes: frame,
            ),
          );
        }

        vm.updateViewport(vm.viewport.copyWith(xMin: 1000, xMax: 1100));

        expect(vm.visibleStartIndex, 0);
        expect(vm.dataPoints.length, total);
        expect(vm.dataPoints[1000].index, 1000);
        expect(vm.dataPoints[1000].values, [1000, 1001, 1002, 1003]);
      },
    );

    test('drag viewport keeps current exact window until drag ends', () {
      const total = 70000;
      for (int i = 0; i < total; i++) {
        final frame = _zobowFrame(i);
        vm.ingestParsedResultForTest(
          ParseResult.ok(
            ZobowParser.decodeFrameValues(frame, vm.parserConfig),
            bytesConsumed: 10,
            rawBytes: frame,
          ),
        );
      }

      final tailStart = vm.visibleStartIndex;
      vm.updateViewport(
        vm.viewport.copyWith(xMin: 1000, xMax: 1100),
        fromDrag: true,
      );

      expect(vm.visibleStartIndex, tailStart);

      vm.saveDragViewport();

      expect(vm.visibleStartIndex, tailStart);
      expect(vm.dataPoints.length, total);
    });

    test('clearData clears LOD index', () {
      for (int i = 0; i < 512; i++) {
        final frame = _zobowFrame(i);
        vm.ingestParsedResultForTest(
          ParseResult.ok(
            ZobowParser.decodeFrameValues(frame, vm.parserConfig),
            bytesConsumed: 10,
            rawBytes: frame,
          ),
        );
      }

      expect(vm.lodIndex.isNotEmpty, isTrue);

      vm.clearData();

      expect(vm.lodIndex.isEmpty, isTrue);
    });

    test('clamps configurable visible window cap', () {
      vm.setMaxVisiblePoints(10000);

      const total = 25000;
      for (int i = 0; i < total; i++) {
        final frame = _zobowFrame(i);
        vm.ingestParsedResultForTest(
          ParseResult.ok(
            ZobowParser.decodeFrameValues(frame, vm.parserConfig),
            bytesConsumed: 10,
            rawBytes: frame,
          ),
        );
      }

      expect(vm.maxVisiblePoints, PlotViewModel.minVisiblePoints);
      expect(vm.pointCount, total);
      expect(vm.dataPoints.length, total);
      expect(vm.visibleStartIndex, 0);
    });

    test(
      'changing channel type rebuilds exact window and LOD values',
      () async {
        for (int i = 0; i < 128; i++) {
          final frame = _zobowFrameWithValues([0xFFFF, 2, 3, 4]);
          vm.ingestParsedResultForTest(
            ParseResult.ok(
              ZobowParser.decodeFrameValues(frame, vm.parserConfig),
              bytesConsumed: 10,
              rawBytes: frame,
            ),
          );
        }

        expect(vm.dataPoints.first.values.first, 65535);

        final updated = await vm.setZobowChannelType(0, DataType.int16);

        expect(updated, isTrue);
        expect(vm.dataPoints.first.values.first, -1);
        final lod = vm.lodIndex.query(
          channelIndex: 0,
          xMin: 0,
          xMax: 128,
          plotWidth: 1,
        );
        expect(lod, isNotNull);
        expect(lod!.values, everyElement(-1));
      },
    );

    test('changing Zobow channel count clears incompatible history', () {
      final frame = _zobowFrame(10);
      vm.ingestParsedResultForTest(
        ParseResult.ok(
          ZobowParser.decodeFrameValues(frame, vm.parserConfig),
          bytesConsumed: 10,
          rawBytes: frame,
        ),
      );

      vm.updateParserConfig(vm.parserConfig.copyWith(channelCount: 8));

      expect(vm.pointCount, 0);
      expect(vm.dataPoints, isEmpty);
      expect(vm.lodIndex.isEmpty, isTrue);
      expect(vm.zobowRawFrameCount, 0);
    });
  });
}
