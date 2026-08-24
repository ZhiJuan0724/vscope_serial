import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_connection_config.dart';
import 'package:vscope_serial/data/models/serial_config.dart';
import 'package:vscope_serial/services/app_settings.dart';

void main() {
  setUp(() async => AppSettings().debugDetach());
  tearDown(() async => AppSettings().debugDetach());

  test('串口默认使用原全局配置', () {
    final settings =
        AppSettings()..loadFromSerialConfig(SerialConfig(port: 'COM7'));
    expect(settings.separateSerialProfiles, isFalse);
    expect(settings.serialConfigForPage('rawData').port, 'COM7');
    settings.saveSerialConfigForPage('plot', SerialConfig(port: 'COM8'));
    expect(settings.serialConfigForPage('shell').port, 'COM8');
  });

  test('独立模式复制全局参数并保留各页面参数', () {
    final settings =
        AppSettings()..loadFromSerialConfig(SerialConfig(port: 'COM7'));
    settings.setSeparateSerialProfiles(true);
    settings.saveSerialConfigForPage('plot', SerialConfig(port: 'COM8'));
    expect(settings.serialConfigForPage('rawData').port, 'COM7');
    expect(settings.serialConfigForPage('plot').port, 'COM8');

    settings.setSeparateSerialProfiles(false);
    expect(settings.serialConfigForPage('plot').port, 'COM7');
    settings.setSeparateSerialProfiles(true);
    expect(settings.serialConfigForPage('plot').port, 'COM8');
  });

  test('网络关闭时页面强制使用串口但保留原选择', () {
    final settings =
        AppSettings()
          ..networkConnectionsEnabled = true
          ..saveConnectionTypeForPage('plot', DataConnectionType.udp);
    expect(settings.connectionTypeForPage('plot'), DataConnectionType.udp);
    settings.networkConnectionsEnabled = false;
    expect(settings.connectionTypeForPage('plot'), DataConnectionType.serial);
    settings.networkConnectionsEnabled = true;
    expect(settings.connectionTypeForPage('plot'), DataConnectionType.udp);
  });

  test('绘图不接受TCP服务端配置', () {
    final settings =
        AppSettings()
          ..networkConnectionsEnabled = true
          ..saveConnectionTypeForPage('plot', DataConnectionType.tcpServer);
    expect(settings.connectionTypeForPage('plot'), DataConnectionType.serial);
  });

  test('页面可见性、串口页面参数和网络参数可持久化', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vscope-connection-profiles-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/settings.json';
    final settings = AppSettings();
    await settings.debugInitializeAt(path);
    settings
      ..visibleMainPages = const ['plot', 'shell']
      ..networkConnectionsEnabled = true
      ..setSeparateSerialProfiles(true)
      ..saveSerialConfigForPage('plot', SerialConfig(port: 'COM12'))
      ..saveConnectionTypeForPage('plot', DataConnectionType.udp)
      ..saveNetworkConfigForPage(
        'plot',
        const NetworkConnectionConfig(
          type: DataConnectionType.udp,
          host: '192.0.2.1',
          port: 9000,
          localPort: 9001,
        ),
      );
    await settings.save();
    await settings.flushPendingSave();
    await settings.debugDetach();
    await settings.debugInitializeAt(path);

    expect(settings.visibleMainPages, ['plot', 'shell']);
    expect(settings.separateSerialProfiles, isTrue);
    expect(settings.serialConfigForPage('plot').port, 'COM12');
    expect(settings.connectionTypeForPage('plot'), DataConnectionType.udp);
    expect(settings.networkConfigForPage('plot').host, '192.0.2.1');
    expect(settings.networkConfigForPage('plot').localPort, 9001);
  });
}
