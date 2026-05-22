import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/chunked_byte_buffer.dart';

void main() {
  group('ChunkedByteBuffer', () {
    test('reads ranges across chunk boundaries', () {
      final buffer = ChunkedByteBuffer(chunkSize: 8);
      buffer.append(Uint8List.fromList(List.generate(20, (i) => i)));

      expect(buffer.length, 20);
      expect(buffer.readRange(6, 8), [6, 7, 8, 9, 10, 11, 12, 13]);
      expect(buffer.toBytes().length, 20);
    });
  });

  group('FixedPacketByteBuffer', () {
    test(
      'stores 7.2 million 10-byte packets and supports random reads',
      () {
        const packetSize = 10;
        const packetCount = 7200000;
        final buffer = FixedPacketByteBuffer(
          packetSize: packetSize,
          chunkSize: 1024 * 1024,
        );
        final batch = Uint8List(packetSize * 1000);

        for (int start = 0; start < packetCount; start += 1000) {
          for (int i = 0; i < 1000; i++) {
            final packetIndex = start + i;
            final offset = i * packetSize;
            batch[offset] = packetIndex & 0xFF;
            batch[offset + 1] = (packetIndex >> 8) & 0xFF;
            batch[offset + 2] = (packetIndex >> 16) & 0xFF;
            batch[offset + 3] = (packetIndex >> 24) & 0xFF;
          }
          buffer.appendPackets(batch);
        }

        expect(buffer.byteLength, packetCount * packetSize);
        expect(buffer.packetCount, packetCount);

        for (final index in [0, 1, 59999, 500000, packetCount - 1]) {
          final packet = buffer.readPacket(index);
          final decoded =
              packet[0] |
              (packet[1] << 8) |
              (packet[2] << 16) |
              (packet[3] << 24);
          expect(decoded, index);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
