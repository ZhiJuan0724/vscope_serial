import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/serial_connection_coordinator.dart';

void main() {
  group('SerialConnectionCoordinator', () {
    test(
      'serializes lifecycle operations and propagates their results',
      () async {
        final coordinator = SerialConnectionCoordinator();
        final firstGate = Completer<void>();
        final events = <String>[];

        final first = coordinator.enqueue(() async {
          events.add('first:start');
          await firstGate.future;
          events.add('first:end');
          return 1;
        });
        final second = coordinator.enqueue(() async {
          events.add('second');
          return 2;
        });

        await Future<void>.delayed(Duration.zero);
        expect(events, ['first:start']);
        firstGate.complete();
        expect(await first, 1);
        expect(await second, 2);
        expect(events, ['first:start', 'first:end', 'second']);
      },
    );

    test('disconnect invalidates an in-flight connection generation', () async {
      final coordinator = SerialConnectionCoordinator();
      final openGate = Completer<void>();

      final connect = coordinator.connect(
        onStart: () {},
        operation: (_) => openGate.future,
      );
      final openingGeneration = coordinator.generation;
      final disconnect = coordinator.disconnect(() async {});

      expect(coordinator.isCurrent(openingGeneration), isFalse);
      openGate.complete();
      await Future.wait([connect, disconnect]);
    });

    test(
      'connect, IO disconnect and shutdown are independently single-flight',
      () async {
        final coordinator = SerialConnectionCoordinator();
        final connectGate = Completer<void>();
        var connectCalls = 0;

        final firstConnect = coordinator.connect(
          onStart: () {},
          operation: (_) async {
            connectCalls++;
            await connectGate.future;
          },
        );
        final secondConnect = coordinator.connect(
          onStart: () {},
          operation: (_) async => connectCalls++,
        );
        expect(identical(firstConnect, secondConnect), isTrue);

        connectGate.complete();
        await firstConnect;
        expect(connectCalls, 1);

        final ioGate = Completer<void>();
        var ioCalls = 0;
        final firstIo = coordinator.disconnectFromIo(() async {
          ioCalls++;
          await ioGate.future;
        });
        final secondIo = coordinator.disconnectFromIo(() async => ioCalls++);
        expect(identical(firstIo, secondIo), isTrue);
        ioGate.complete();
        await firstIo;
        expect(ioCalls, 1);

        var shutdownCalls = 0;
        final firstShutdown = coordinator.shutdown(() async => shutdownCalls++);
        final secondShutdown = coordinator.shutdown(
          () async => shutdownCalls++,
        );
        expect(identical(firstShutdown, secondShutdown), isTrue);
        await firstShutdown;
        expect(shutdownCalls, 1);

        var startedAfterShutdown = false;
        await coordinator.connect(
          onStart: () => startedAfterShutdown = true,
          operation: (_) async {},
        );
        expect(startedAfterShutdown, isFalse);
      },
    );
  });
}
