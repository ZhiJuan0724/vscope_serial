import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/parser/just_float_parser.dart';

void main() {
  group('JustFloatParser', () {
    Uint8List buildFrame(List<double> values) {
      final bytes = BytesBuilder();
      final data = ByteData(values.length * 4);
      for (int i = 0; i < values.length; i++) {
        data.setFloat32(i * 4, values[i], Endian.little);
      }
      bytes.add(data.buffer.asUint8List());
      bytes.add(JustFloatParser.tail);
      return bytes.takeBytes();
    }

    test('parses little-endian float32 frame with VOFA tail', () async {
      final parser = JustFloatParser(
        ParserConfig.justFloatDefault()..channelCount = 3,
      );
      addTearDown(parser.dispose);

      final future = parser.outputStream.first;
      parser.feed(buildFrame([1.25, -2.5, 3.75]));
      final result = await future;

      expect(result.success, isTrue);
      expect(result.values, [1.25, -2.5, 3.75]);
    });

    test('waits for tail across chunks', () async {
      final parser = JustFloatParser(
        ParserConfig.justFloatDefault()..channelCount = 2,
      );
      addTearDown(parser.dispose);

      final frame = buildFrame([10.5, 20.25]);
      final future = parser.outputStream.first;
      parser.feed(Uint8List.sublistView(frame, 0, 5));
      parser.feed(Uint8List.sublistView(frame, 5));
      final result = await future;

      expect(result.success, isTrue);
      expect(result.values, [10.5, 20.25]);
    });
  });
}
