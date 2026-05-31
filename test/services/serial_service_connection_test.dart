import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/app_notifications.dart';
import 'package:vscope_serial/services/serial_service.dart';

void main() {
  group('SerialService connection', () {
    final service = SerialService();

    tearDown(() {
      service.debugPortOpener = null;
      service.disconnect();
      service.config = SerialConfig();
      AppNotifications.lastMessage = null;
    });

    test(
      'COM7 slow open failure keeps UI loop responsive and shows message',
      () async {
        final openResult = Completer<bool>();
        var eventLoopAdvanced = false;
        service.config = SerialConfig(port: 'COM7');
        service.debugPortOpener = (port, baudRate) async {
          expect(port, 'COM7');
          return openResult.future;
        };

        final connectFuture = service.connect();
        expect(service.isConnecting, isTrue);

        Timer.run(() {
          eventLoopAdvanced = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(eventLoopAdvanced, isTrue);
        expect(service.isConnecting, isTrue);
        expect(service.isConnected, isFalse);

        openResult.complete(false);
        await connectFuture;

        expect(service.isConnecting, isFalse);
        expect(service.isConnected, isFalse);
        expect(AppNotifications.lastMessage, '串口打开失败，请检查端口占用或设备状态');
      },
    );
  });
}
