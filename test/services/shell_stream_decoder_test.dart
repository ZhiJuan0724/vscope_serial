import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/shell_stream_decoder.dart';

void main() {
  group('ShellStreamDecoder', () {
    final encodedSamples = <String, List<int>>{
      'UTF-8': utf8.encode('A中文B'),
      'GBK': <int>[0x41, 0xD6, 0xD0, 0xCE, 0xC4, 0x42],
      'BIG5': <int>[0x41, 0xA4, 0xA4, 0xA4, 0xE5, 0x42],
      'Shift_JIS': <int>[0x41, 0x93, 0xFA, 0x96, 0x7B, 0x42],
      'EUC-KR': <int>[0x41, 0xC7, 0xD1, 0xB1, 0xB9, 0x42],
      'Latin-1': latin1.encode('AéB'),
      'ASCII': ascii.encode('ABC'),
    };

    for (final entry in encodedSamples.entries) {
      test('${entry.key} keeps characters split across chunks', () {
        final expected = switch (entry.key) {
          'Shift_JIS' => 'A日本B',
          'EUC-KR' => 'A한국B',
          'Latin-1' => 'AéB',
          'ASCII' => 'ABC',
          _ => 'A中文B',
        };
        for (var split = 1; split < entry.value.length; split++) {
          final decoder = ShellStreamDecoder(entry.key);
          final output =
              StringBuffer()
                ..write(
                  decoder.add(
                    Uint8List.fromList(entry.value.sublist(0, split)),
                  ),
                )
                ..write(
                  decoder.add(Uint8List.fromList(entry.value.sublist(split))),
                )
                ..write(decoder.flush());
          expect(output.toString(), expected, reason: 'split=$split');
        }
      });
    }

    test('keeps split ANSI sequence byte order intact', () {
      final decoder = ShellStreamDecoder('UTF-8');
      final output =
          decoder.add(Uint8List.fromList([0x1B, 0x5B])) +
          decoder.add(Uint8List.fromList([0x32, 0x4A]));
      expect(output, '\x1b[2J');
    });
  });
}
