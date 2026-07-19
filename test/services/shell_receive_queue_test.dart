import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/shell_receive_queue.dart';

void main() {
  group('ShellReceiveQueue', () {
    test('drops oldest complete pending chunks at the byte limit', () {
      final queue = ShellReceiveQueue(maxBytes: 8);

      expect(queue.add(Uint8List.fromList([1, 2, 3, 4])), 0);
      expect(queue.add(Uint8List.fromList([5, 6, 7, 8, 9])), 4);

      expect(queue.queuedBytes, 5);
      expect(queue.droppedBytes, 4);
      expect(queue.removeUpTo(8).expand((chunk) => chunk), [5, 6, 7, 8, 9]);
    });

    test(
      'keeps only the newest suffix when one callback exceeds the limit',
      () {
        final queue = ShellReceiveQueue(maxBytes: 4);

        expect(queue.add(Uint8List.fromList([1, 2, 3, 4, 5, 6])), 2);

        expect(queue.removeUpTo(4).expand((chunk) => chunk), [3, 4, 5, 6]);
        expect(queue.queuedBytes, 0);
        expect(queue.droppedBytes, 2);
      },
    );

    test('partial frame consumption keeps accounting exact', () {
      final queue = ShellReceiveQueue(maxBytes: 8);
      queue.add(Uint8List.fromList([1, 2, 3, 4, 5]));

      expect(queue.removeUpTo(2).expand((chunk) => chunk), [1, 2]);
      expect(queue.queuedBytes, 3);
      expect(queue.add(Uint8List.fromList([6, 7, 8, 9, 10, 11])), 3);
      expect(queue.removeUpTo(8).expand((chunk) => chunk), [
        6,
        7,
        8,
        9,
        10,
        11,
      ]);
    });
  });
}
