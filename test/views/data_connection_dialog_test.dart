import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/data_packet.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/services/native_serial_reader.dart';
import 'package:vscope_serial/services/serial_transport.dart';
import 'package:vscope_serial/views/dialogs/data_connection_dialog.dart';

void main() {
  late DataConnectionService service;

  setUp(() {
    service = DataConnectionService.forTesting(
      transportFactory: _DataConnectionDialogTransport.new,
    );
  });

  tearDown(() {
    service.debugPortEnumerator = null;
    service.debugPortDetailsEnumerator = null;
    service.config = SerialConfig();
    service.dispose();
  });

  testWidgets('串口详细信息默认关闭且只在勾选后刷新', (tester) async {
    var detailCalls = 0;
    service
      ..config = SerialConfig(port: 'COM7')
      ..debugPortEnumerator = () async {
        return ['COM7'];
      }
      ..debugPortDetailsEnumerator = () async {
        detailCalls++;
        return const [
          NativeSerialPortDetail(port: 'COM7', name: 'USB Serial Port (COM7)'),
        ];
      };

    // 先准备端口目录；弹窗自身仍会在首帧后触发一次连接状态刷新。
    // 测试只需泵送首帧，不等待可能持续调度通知的整个 Widget 树空闲。
    await service.refreshPorts(reason: '测试准备');

    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<DataConnectionService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: DataConnectionDialog())),
      ),
    );
    await tester.pump();

    final checkboxFinder = find.byKey(
      const ValueKey('show-port-details-checkbox'),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('serial-dialog-content'))).width,
      400,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('baud-rate-field-container')))
          .width,
      220,
    );
    expect(
      tester.getCenter(checkboxFinder).dy,
      greaterThan(
        tester
            .getCenter(
              find.widgetWithText(ElevatedButton, AppStrings.common.refresh),
            )
            .dy,
      ),
    );
    expect(tester.widget<Checkbox>(checkboxFinder).value, isFalse);
    expect(find.text('COM7'), findsOneWidget);
    expect(detailCalls, 0);

    await tester.tap(checkboxFinder);
    await tester.pump();
    expect(tester.widget<Checkbox>(checkboxFinder).value, isTrue);
    expect(detailCalls, 0);

    await tester.tap(
      find.widgetWithText(ElevatedButton, AppStrings.common.refresh),
    );
    await tester.pumpAndSettle();

    expect(detailCalls, 1);
    expect(find.text('COM7: USB Serial Port'), findsOneWidget);
  });

  testWidgets('历史串口刷新后不存在时明确标注并禁用连接', (tester) async {
    service
      ..config = SerialConfig(port: 'COM9')
      ..debugPortEnumerator = () async => const [];

    await service.refreshPorts(reason: '测试准备');

    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<DataConnectionService>.value(
        value: service,
        child: const MaterialApp(home: Scaffold(body: DataConnectionDialog())),
      ),
    );
    await tester.pump();

    expect(find.text('COM9（当前不存在）'), findsOneWidget);
    final connectButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, AppStrings.serial.connect),
    );
    expect(connectButton.onPressed, isNull);
  });

  testWidgets('网络开关开启后按页面限制可选连接类型', (tester) async {
    final settings = AppSettings()..networkConnectionsEnabled = true;
    addTearDown(() {
      settings
        ..networkConnectionsEnabled = false
        ..dataPageConnectionTypes = {}
        ..networkPageProfiles = {};
    });
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<DataConnectionService>.value(
        value: service,
        child: const MaterialApp(
          home: Scaffold(body: DataConnectionDialog(pageId: 'rawData')),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('串口').first);
    await tester.pumpAndSettle();
    expect(find.text('TCP 服务端'), findsOneWidget);
    expect(find.text('UDP'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ChangeNotifierProvider<DataConnectionService>.value(
        value: service,
        child: const MaterialApp(
          home: Scaffold(body: DataConnectionDialog(pageId: 'plot')),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('串口').first);
    await tester.pumpAndSettle();
    expect(find.text('TCP 服务端'), findsNothing);
    expect(find.text('TCP 客户端'), findsOneWidget);
    expect(find.text('UDP'), findsOneWidget);
  });
}

class _DataConnectionDialogTransport implements SerialTransport {
  @override
  Stream<DataPacket> get dataStream => const Stream.empty();

  @override
  Stream<Object> get errorStream => const Stream.empty();

  @override
  bool get canSend => false;

  @override
  String get description => '测试串口';

  @override
  bool get isOpen => false;

  @override
  Future<bool> open(String port, int baudRate) async => false;

  @override
  bool setConfig(int dataBits, int stopBits, int parity) => true;

  @override
  void setDtr(bool value) {}

  @override
  void setRts(bool value) {}

  @override
  bool startReading({required int timeoutMs}) => true;

  @override
  Future<int> write(Uint8List data) async => data.length;

  @override
  Future<void> close() async {}
}
