import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';

void _neverReadyWriteIsolate(SendPort _) {
  ReceivePort();
}

Future<void> _noResponseWriteIsolate(SendPort readyPort) async {
  final commands = ReceivePort();
  readyPort.send(commands.sendPort);
  await for (final _ in commands) {
    // Intentionally keep every request pending.
  }
}

void _exitAfterReadyWriteIsolate(SendPort readyPort) {
  final commands = ReceivePort();
  readyPort.send(commands.sendPort);
  commands.close();
}

void main() {
  test('NativeSerialData 解析聚合块首末时间和数据', () {
    final packet = Uint8List(35);
    final header = ByteData.sublistView(packet);
    header.setInt64(0, 123456000, Endian.little);
    header.setInt64(8, 123456789, Endian.little);
    header.setInt64(16, 1784499000000000, Endian.little);
    header.setInt64(24, 1784500000000000, Endian.little);
    packet.setRange(32, 35, [1, 2, 3]);

    final parsed = NativeSerialData.tryParse(packet)!;

    expect(parsed.firstMonotonicUs, 123456000);
    expect(parsed.lastMonotonicUs, 123456789);
    expect(parsed.firstWallClockUs, 1784499000000000);
    expect(parsed.lastWallClockUs, 1784500000000000);
    expect(parsed.monotonicUs, 123456789);
    expect(parsed.wallClockUs, 1784499000000000);
    expect(parsed.data, [1, 2, 3]);
    expect(NativeSerialData.tryParse(Uint8List(31)), isNull);
  });

  group('NativeSerialWriteQueue', () {
    test('启动超时后队列永久失败且关闭不阻塞', () async {
      final queue = NativeSerialWriteQueue(
        entryPoint: _neverReadyWriteIsolate,
        startupTimeout: const Duration(milliseconds: 30),
        shutdownTimeout: const Duration(milliseconds: 30),
      );

      await expectLater(
        queue.write(Uint8List.fromList([1])),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        queue.write(Uint8List.fromList([2])),
        throwsA(anything),
      );
      await queue.close().timeout(const Duration(milliseconds: 200));
    });

    test('请求超时会一次性结束全部 pending Future', () async {
      final queue = NativeSerialWriteQueue(
        entryPoint: _noResponseWriteIsolate,
        startupTimeout: const Duration(milliseconds: 100),
        requestTimeout: const Duration(milliseconds: 30),
        shutdownTimeout: const Duration(milliseconds: 30),
      );

      final first = queue.write(Uint8List.fromList([1]));
      final second = queue.write(Uint8List.fromList([2]));

      await expectLater(first, throwsA(isA<TimeoutException>()));
      await expectLater(second, throwsA(anything));
      await queue.close().timeout(const Duration(milliseconds: 200));
    });

    test('isolate 意外退出后拒绝后续请求', () async {
      final queue = NativeSerialWriteQueue(
        entryPoint: _exitAfterReadyWriteIsolate,
        startupTimeout: const Duration(milliseconds: 100),
        requestTimeout: const Duration(milliseconds: 100),
        shutdownTimeout: const Duration(milliseconds: 30),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      await expectLater(
        queue.write(Uint8List.fromList([1])),
        throwsA(anything),
      );
      await queue.close().timeout(const Duration(milliseconds: 200));
    });

    test('关闭请求无响应时在超时后强制结束', () async {
      final queue = NativeSerialWriteQueue(
        entryPoint: _noResponseWriteIsolate,
        startupTimeout: const Duration(milliseconds: 100),
        requestTimeout: const Duration(seconds: 1),
        shutdownTimeout: const Duration(milliseconds: 30),
      );

      final pendingWrite = queue.write(Uint8List.fromList([1]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await queue.close().timeout(const Duration(milliseconds: 200));
      await expectLater(pendingWrite, throwsA(anything));
    });
  });
}
