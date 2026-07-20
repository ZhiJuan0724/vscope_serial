import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/services/serial_transport.dart';

void main() {
  group('SerialService lifecycle queue', () {
    test(
      'disconnect while opening invalidates and closes only stale transport',
      () async {
        final open = Completer<bool>();
        final first = _FakeTransport(openResult: open.future);
        final service = SerialService.forTesting(transportFactory: () => first)
          ..config = SerialConfig(port: 'COM7');

        final connecting = service.connect();
        expect(service.isConnecting, isTrue);
        final disconnecting = service.disconnect();
        open.complete(true);

        await Future.wait([connecting, disconnecting]);
        expect(service.isConnected, isFalse);
        expect(first.closeCount, 1);
        service.dispose();
      },
    );

    test('stale open completion never closes the next generation', () async {
      final firstOpen = Completer<bool>();
      final first = _FakeTransport(openResult: firstOpen.future);
      final second = _FakeTransport();
      final transports = <_FakeTransport>[first, second];
      final service = SerialService.forTesting(
        transportFactory: () => transports.removeAt(0),
      )..config = SerialConfig(port: 'COM7');

      final oldConnect = service.connect();
      final disconnect = service.disconnect();
      final newConnect = service.connect();
      firstOpen.complete(true);
      await Future.wait([oldConnect, disconnect, newConnect]);

      expect(first.closeCount, 1);
      expect(second.closeCount, 0);
      expect(service.isConnected, isTrue);
      await service.shutdown();
      expect(second.closeCount, 1);
      service.dispose();
    });

    test(
      'health failure fully closes old transport before reconnect open',
      () async {
        final events = <String>[];
        final first = _FakeTransport(name: 'old', events: events);
        final second = _FakeTransport(name: 'new', events: events);
        final transports = <_FakeTransport>[first, second];
        final service =
            SerialService.forTesting(
                transportFactory: () => transports.removeAt(0),
              )
              ..config = SerialConfig(port: 'COM7')
              ..debugConnectionHealthChecker = (() async => false)
              ..debugPortEnumerator = (() async => ['COM7']);

        await service.connect();
        expect(await service.refreshConnectionStatus(), isTrue);

        expect(
          events.indexOf('old:close'),
          lessThan(events.indexOf('new:open')),
        );
        expect(first.closeCount, 1);
        expect(second.closeCount, 0);
        await service.shutdown();
        service.dispose();
      },
    );

    test(
      'callbacks from an old generation cannot enter the new raw session',
      () async {
        final first = _FakeTransport();
        final second = _FakeTransport();
        final transports = <_FakeTransport>[first, second];
        final service = SerialService.forTesting(
          transportFactory: () => transports.removeAt(0),
        )..config = SerialConfig(port: 'COM7');

        await service.connect();
        await service.disconnect();
        await service.connect();
        expect(service.startRawReceiving(), isTrue);

        first.emit([1, 2, 3]);
        second.emit([4, 5]);
        await Future<void>.delayed(Duration.zero);

        expect(service.rawRetentionUsage.usedBytes, 2);
        await service.shutdown();
        service.dispose();
      },
    );

    test(
      'repeated write disconnect signals close the active transport once',
      () async {
        final transport = _FakeTransport(writeResult: 0);
        final service = SerialService.forTesting(
          transportFactory: () => transport,
        )..config = SerialConfig(port: 'COM7');
        await service.connect();

        final writes = await Future.wait([
          service.sendRawBytes(Uint8List.fromList([1])).catchError((_) {}),
          service.sendRawBytes(Uint8List.fromList([2])).catchError((_) {}),
        ]);
        expect(writes, hasLength(2));
        await Future<void>.delayed(Duration.zero);
        await service.disconnect();

        expect(transport.closeCount, 1);
        service.dispose();
      },
    );

    test('queued activity notifications are ignored after disposal', () async {
      final service = SerialService()..isConnected = true;

      expect(service.startRawReceiving(), isTrue);
      service.stopRawReceiving();
      service.dispose();

      // 刷新 start/stop 安排的通知；销毁后的回调必须静默退出。
      await Future<void>.delayed(Duration.zero);
    });
  });
}

class _FakeTransport implements SerialTransport {
  final String name;
  final List<String>? events;
  final Future<bool>? openResult;
  final int? writeResult;
  final StreamController<NativeSerialData> _controller =
      StreamController<NativeSerialData>.broadcast();

  bool _isOpen = false;
  int closeCount = 0;

  _FakeTransport({
    this.name = 'transport',
    this.events,
    this.openResult,
    this.writeResult,
  });

  @override
  Stream<NativeSerialData> get dataStream => _controller.stream;

  @override
  bool get isOpen => _isOpen;

  @override
  Future<bool> open(String port, int baudRate) async {
    events?.add('$name:open');
    final result = await (openResult ?? Future<bool>.value(true));
    _isOpen = result;
    return result;
  }

  @override
  Future<void> close() async {
    if (!_isOpen) return;
    events?.add('$name:close');
    closeCount++;
    _isOpen = false;
  }

  void emit(List<int> bytes) {
    _controller.add(
      NativeSerialData(
        data: Uint8List.fromList(bytes),
        monotonicUs: DateTime.now().microsecondsSinceEpoch,
        wallClockUs: DateTime.now().microsecondsSinceEpoch,
      ),
    );
  }

  @override
  bool setConfig(int dataBits, int stopBits, int parity) => true;

  @override
  void setDtr(bool value) {}

  @override
  void setRts(bool value) {}

  @override
  bool startReading({required int timeoutMs}) => true;

  @override
  Future<int> write(Uint8List data) async => writeResult ?? data.length;
}
