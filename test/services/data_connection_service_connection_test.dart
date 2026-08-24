import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/app_notifications.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

void main() {
  group('DataConnectionService connection', () {
    final service = DataConnectionService();

    tearDown(() {
      service.debugPortOpener = null;
      service.debugPortEnumerator = null;
      service.debugPortDetailsEnumerator = null;
      service.debugConnectionHealthChecker = null;
      service.debugNativePortOpen = null;
      service.disconnect();
      service.config = SerialConfig();
      AppNotifications.lastMessage = null;
      AppSettings()
        ..lastPort = null
        ..baudRate = 115200
        ..disableNotifications = false;
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

    test('disabled notifications suppress transient messages', () {
      AppSettings().disableNotifications = true;

      AppNotifications.show('不会显示');

      expect(AppNotifications.lastMessage, isNull);
    });

    test('loadSettings restores saved baud rate before auto connect', () async {
      AppSettings()
        ..lastPort = 'COM7'
        ..baudRate = 1152000;
      service.loadSettings();

      String? openedPort;
      int? openedBaudRate;
      service.debugPortOpener = (port, baudRate) async {
        openedPort = port;
        openedBaudRate = baudRate;
        return false;
      };

      expect(service.config.port, 'COM7');
      expect(service.config.baudRate, 1152000);

      await service.connect();

      expect(openedPort, 'COM7');
      expect(openedBaudRate, 1152000);
    });

    test('healthy connected port does not enumerate', () async {
      var enumerationCalls = 0;
      service
        ..config = SerialConfig(port: 'COM7')
        ..isConnected = true
        ..debugNativePortOpen = true
        ..debugConnectionHealthChecker = (() async => true)
        ..debugPortEnumerator = () async {
          enumerationCalls++;
          return ['COM7'];
        };

      expect(await service.refreshConnectionStatus(), isTrue);
      expect(enumerationCalls, 0);
    });

    test('普通刷新不读取名称，详细刷新才读取并格式化名称', () async {
      var portCalls = 0;
      var detailCalls = 0;
      service
        ..debugPortEnumerator = () async {
          portCalls++;
          return ['COM7'];
        }
        ..debugPortDetailsEnumerator = () async {
          detailCalls++;
          return const [
            NativeSerialPortDetail(
              port: 'COM7',
              name: 'USB Serial Port (COM7)',
            ),
          ];
        };

      expect(await service.refreshPorts(reason: '普通刷新'), isTrue);
      expect(portCalls, 1);
      expect(detailCalls, 0);
      expect(service.portDisplayLabel('COM7', showDetails: true), 'COM7');

      expect(await service.refreshPortsWithDetails(), isTrue);
      expect(portCalls, 2);
      expect(detailCalls, 1);
      expect(
        service.portDisplayLabel('COM7', showDetails: true),
        'COM7: USB Serial Port',
      );
      expect(service.portDisplayLabel('COM7', showDetails: false), 'COM7');
    });

    test('详细名称读取超时后恢复按钮且不重复启动枚举', () async {
      final details = Completer<List<NativeSerialPortDetail>>();
      var detailCalls = 0;
      service
        ..debugPortEnumerator = () async {
          return ['COM7'];
        }
        ..debugPortDetailsEnumerator = () {
          detailCalls++;
          return details.future;
        };

      expect(
        await service.refreshPortsWithDetails(
          waitTimeout: const Duration(milliseconds: 20),
        ),
        isFalse,
      );
      expect(service.isRefreshingPorts, isFalse);
      expect(detailCalls, 1);

      expect(
        await service.refreshPortsWithDetails(
          waitTimeout: const Duration(milliseconds: 20),
        ),
        isFalse,
      );
      expect(detailCalls, 1);

      details.complete(const []);
      await Future<void>.delayed(Duration.zero);
    });

    test('auto connect tries saved port before a single enumeration', () async {
      AppSettings().lastPort = 'COM9';
      final openedPorts = <String>[];
      var enumerationCalls = 0;
      service
        ..config = SerialConfig()
        ..debugPortOpener = (port, baudRate) async {
          openedPorts.add(port);
          return false;
        }
        ..debugPortEnumerator = () async {
          enumerationCalls++;
          return ['COM8'];
        };
      final viewModel = PlotViewModel(service);

      await viewModel.autoConnectSerialForTest();

      expect(openedPorts, ['COM9', 'COM8']);
      expect(enumerationCalls, 1);
      viewModel.dispose();
    });
  });
}
