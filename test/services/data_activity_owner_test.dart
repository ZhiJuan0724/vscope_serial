import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/data_connection_service.dart';

void main() {
  final service = DataConnectionService();

  tearDown(() async {
    service.releaseActivity(service.activityOwner);
    service.isConnected = false;
  });

  test('raw data, shell and plot are mutually exclusive', () {
    service.isConnected = true;
    expect(service.startRawReceiving(), isTrue);
    expect(service.activityOwner, DataActivityOwner.rawData);
    expect(service.startShellReceiving(), isFalse);
    expect(service.tryAcquireActivity(DataActivityOwner.plot), isFalse);

    service.stopRawReceiving();
    expect(service.startShellReceiving(), isTrue);
    expect(service.activityOwner, DataActivityOwner.shell);
    expect(service.tryAcquireActivity(DataActivityOwner.plot), isFalse);
  });

  test('start failure does not retain page lock', () {
    service.isConnected = false;
    expect(service.startRawReceiving(), isFalse);
    expect(service.startShellReceiving(), isFalse);
    expect(service.activityOwner, DataActivityOwner.none);
  });

  test('disconnect releases current activity owner', () async {
    service.isConnected = true;
    expect(service.startShellReceiving(), isTrue);
    await service.disconnect();
    expect(service.activityOwner, DataActivityOwner.none);
    expect(service.isShellReceiving, isFalse);
  });
}
