import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/protocol_viewmodel.dart';

void main() {
  test('同一事件循环内的服务通知只转发一次', () async {
    final service = SerialService();
    final viewModel = ProtocolViewModel(service);
    addTearDown(viewModel.dispose);
    var notificationCount = 0;
    viewModel.addListener(() => notificationCount++);

    service.notifyListeners();
    service.notifyListeners();
    service.notifyListeners();
    await Future<void>.delayed(Duration.zero);

    expect(notificationCount, 1);
  });
}
