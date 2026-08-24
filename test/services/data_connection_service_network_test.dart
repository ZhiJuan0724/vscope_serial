import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_connection_config.dart';
import 'package:vscope_serial/data/models/data_packet.dart';
import 'package:vscope_serial/services/connection_owner_service.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/services/serial_transport.dart';

void main() {
  tearDown(() => ConnectionOwnerService().reset());

  test('TCP数据复用数据收发的接收、发送和活动所有权', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peerFuture = server.first;
    final service = DataConnectionService.forTesting(
      transportFactory: _UnusedSerialTransport.new,
    );

    await service.connectNetwork(
      NetworkConnectionConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      ),
      pageId: 'rawData',
    );
    final peer = await peerFuture;
    expect(service.isConnected, isTrue);
    expect(service.startRawReceiving(), isTrue);

    peer.add([1, 2, 3]);
    await _waitUntil(() => service.rawRetentionUsage.usedBytes == 3);
    final exportDirectory = await Directory.systemTemp.createTemp(
      'serial-network-raw-',
    );
    addTearDown(() async {
      if (await exportDirectory.exists()) {
        await exportDirectory.delete(recursive: true);
      }
    });
    final exportPath = await service.exportAsRawBytes(
      outputDirectory: exportDirectory,
    );
    expect(exportPath, isNotNull);
    final exportedBytes = await File(exportPath!).readAsBytes();
    // BIN 导出格式会在原始数据后追加 4 字节 CRC32。
    expect(exportedBytes.sublist(0, 3), [1, 2, 3]);
    expect(exportedBytes.length, 7);

    final outbound = peer.first;
    await service.sendRawBytes(Uint8List.fromList([4, 5]));
    expect(await outbound, [4, 5]);

    await peer.close();
    await _waitUntil(() => !service.isConnected);
    expect(service.activityOwner, DataActivityOwner.none);
    await service.shutdown();
    service.dispose();
    await server.close();
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待异步状态变化超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _UnusedSerialTransport implements SerialTransport {
  @override
  Stream<DataPacket> get dataStream => const Stream.empty();
  @override
  Stream<Object> get errorStream => const Stream.empty();
  @override
  bool get canSend => false;
  @override
  String get description => '未使用';
  @override
  bool get isOpen => false;
  @override
  Future<bool> open(String port, int baudRate) async => false;
  @override
  bool setConfig(int dataBits, int stopBits, int parity) => false;
  @override
  void setDtr(bool value) {}
  @override
  void setRts(bool value) {}
  @override
  bool startReading({required int timeoutMs}) => false;
  @override
  Future<int> write(Uint8List data) async => 0;
  @override
  Future<void> close() async {}
}
