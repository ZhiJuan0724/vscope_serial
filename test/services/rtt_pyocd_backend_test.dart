import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/rtt_pyocd_backend.dart';

void main() {
  test('Worker binary protocol handles fragmented and concatenated frames', () {
    Uint8List frame(int type, int requestId, List<int> payload) {
      final result = Uint8List(16 + payload.length);
      result.setRange(0, 4, ascii.encode('VSPY'));
      final header = ByteData.sublistView(result);
      header
        ..setUint8(4, 1)
        ..setUint8(5, type)
        ..setUint32(8, requestId, Endian.little)
        ..setUint32(12, payload.length, Endian.little);
      result.setRange(16, result.length, payload);
      return result;
    }

    final first = frame(2, 7, utf8.encode('{"ok":true}'));
    final second = frame(4, 0, [0, 0, 1, 2, 3]);
    final combined = Uint8List.fromList([...first, ...second]);
    final decoder = PyOcdWorkerFrameDecoder();

    expect(decoder.add(combined.sublist(0, 9)), isEmpty);
    expect(decoder.add(combined.sublist(9, first.length + 3)), hasLength(1));
    final tail = decoder.add(combined.sublist(first.length + 3));

    expect(tail, hasLength(1));
    expect(tail.single.type, 4);
    expect(tail.single.requestId, 0);
    expect(tail.single.payload, [0, 0, 1, 2, 3]);
  });

  test('Worker check accepts only reviewed pyOCD 0.45.x', () {
    final accepted = parsePyOcdWorkerCheck(
      jsonEncode({
        'ok': true,
        'protocolVersion': 1,
        'pythonVersion': '3.12.7',
        'pyocdVersion': '0.45.0',
      }),
    );
    expect(accepted['pythonVersion'], '3.12.7');

    expect(
      () => parsePyOcdWorkerCheck(
        jsonEncode({
          'ok': true,
          'protocolVersion': 1,
          'pythonVersion': '3.12.7',
          'pyocdVersion': '0.46.0',
        }),
      ),
      throwsStateError,
    );
  });

  test('Worker check rejects protocol mismatch and import failure', () {
    expect(
      () => parsePyOcdWorkerCheck(
        jsonEncode({
          'ok': true,
          'protocolVersion': 2,
          'pythonVersion': '3.12.7',
          'pyocdVersion': '0.45.0',
        }),
      ),
      throwsStateError,
    );
    expect(
      () => parsePyOcdWorkerCheck(
        jsonEncode({'ok': false, 'error': 'No module named pyocd'}),
      ),
      throwsStateError,
    );
  });
}
