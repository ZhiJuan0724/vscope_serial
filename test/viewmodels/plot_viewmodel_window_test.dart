import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
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

    test('keeps total point count while visible window is capped', () {
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
      expect(vm.dataPoints.length, vm.maxVisiblePoints);
      expect(vm.visibleStartIndex, total - vm.maxVisiblePoints);
      expect(vm.dataPoints.first.index, total - vm.maxVisiblePoints);
      expect(vm.dataPoints.last.index, total - 1);
    });

    test('loads arbitrary historical window from raw frames', () {
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

      expect(vm.visibleStartIndex, 1000);
      expect(vm.dataPoints.length, 100);
      expect(vm.dataPoints.first.index, 1000);
      expect(vm.dataPoints.first.values, [1000, 1001, 1002, 1003]);
      expect(vm.dataPoints.last.index, 1099);
    });

    test('applies configurable visible window cap', () {
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

      expect(vm.maxVisiblePoints, 10000);
      expect(vm.pointCount, total);
      expect(vm.dataPoints.length, 10000);
      expect(vm.visibleStartIndex, 15000);
    });
  });
}
