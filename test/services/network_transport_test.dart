import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_connection_config.dart';
import 'package:vscope_serial/services/network_transport.dart';

void main() {
  test('TCP客户端能够双向传输且远端关闭会报告错误', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final transport = TcpClientNetworkTransport();
    await transport.open(
      NetworkConnectionConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      ),
    );
    final peer = await accepted;
    final received = transport.dataStream.first;
    peer.add([1, 2, 3]);
    expect((await received).data, Uint8List.fromList([1, 2, 3]));

    final peerReceived = peer.first;
    expect(await transport.write(Uint8List.fromList([4, 5])), 2);
    expect(await peerReceived, [4, 5]);

    final disconnected = transport.errorStream.first;
    await peer.close();
    expect(await disconnected, isA<StateError>());
    await transport.close();
    await server.close();
  });

  test('TCP服务端只接收一个客户端并在客户端离开后继续监听', () async {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final transport = TcpServerNetworkTransport();
    await transport.open(
      NetworkConnectionConfig(
        type: DataConnectionType.tcpServer,
        host: '127.0.0.1',
        port: port,
      ),
    );
    final first = await Socket.connect('127.0.0.1', port);
    await Future<void>.delayed(Duration.zero);
    expect(transport.canSend, isTrue);
    final second = await Socket.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(transport.canSend, isTrue);
    second.destroy();

    await first.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final replacement = await Socket.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(transport.canSend, isTrue);
    replacement.destroy();
    await transport.close();
  });

  test('UDP只接收配置远端地址和端口的数据', () async {
    final expected = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final other = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final reservation = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final localPort = reservation.port;
    reservation.close();
    final transport = UdpNetworkTransport();
    await transport.open(
      NetworkConnectionConfig(
        type: DataConnectionType.udp,
        host: '127.0.0.1',
        port: expected.port,
        localPort: localPort,
      ),
    );

    final received = transport.dataStream.first.timeout(
      const Duration(seconds: 1),
    );
    final outboundPacket = Completer<Datagram>();
    late final StreamSubscription<RawSocketEvent> expectedSubscription;
    expectedSubscription = expected.listen((event) {
      if (event != RawSocketEvent.read || outboundPacket.isCompleted) return;
      final packet = expected.receive();
      if (packet != null) outboundPacket.complete(packet);
    });
    // 先发送错误来源，再由正确来源发送；错误来源不能完成流。
    other.send([9], InternetAddress.loopbackIPv4, localPort);
    expect(await transport.write(Uint8List.fromList([7])), 1);
    final packet = await outboundPacket.future;
    expect(packet.data, [7]);
    expected.send([8], InternetAddress.loopbackIPv4, localPort);
    expect((await received).data, [8]);

    await expectedSubscription.cancel();
    await transport.close();
    expected.close();
    other.close();
  });
}
