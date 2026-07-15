import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/serial_service.dart';

void main() {
  final service = SerialService();

  tearDown(() async {
    service.releaseActivity(service.activityOwner);
    service.isConnected = false;
  });

  test('raw data, shell and plot are mutually exclusive', () {
    service.isConnected = true;
    expect(service.startRawReceiving(), isTrue);
    expect(service.activityOwner, SerialActivityOwner.rawData);
    expect(service.startShellReceiving(), isFalse);
    expect(service.tryAcquireActivity(SerialActivityOwner.plot), isFalse);

    service.stopRawReceiving();
    expect(service.startShellReceiving(), isTrue);
    expect(service.activityOwner, SerialActivityOwner.shell);
    expect(service.tryAcquireActivity(SerialActivityOwner.plot), isFalse);
  });

  test('start failure does not retain page lock', () {
    service.isConnected = false;
    expect(service.startRawReceiving(), isFalse);
    expect(service.startShellReceiving(), isFalse);
    expect(service.activityOwner, SerialActivityOwner.none);
  });

  test('disconnect releases current activity owner', () async {
    service.isConnected = true;
    expect(service.startShellReceiving(), isTrue);
    await service.disconnect();
    expect(service.activityOwner, SerialActivityOwner.none);
    expect(service.isShellReceiving, isFalse);
  });
}
