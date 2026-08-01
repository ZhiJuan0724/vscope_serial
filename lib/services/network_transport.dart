import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../data/models/data_connection_config.dart';

/// TCP/UDP连接的最小双向传输接口。
abstract class NetworkTransport {
  Stream<Uint8List> get dataStream;
  Stream<Object> get errorStream;
  bool get canSend;
  String get description;
  Future<void> open(NetworkConnectionConfig config);
  Future<int> write(Uint8List data);
  Future<void> close();
}

class TcpClientNetworkTransport implements NetworkTransport {
  final _data = StreamController<Uint8List>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;

  @override
  Stream<Uint8List> get dataStream => _data.stream;
  @override
  Stream<Object> get errorStream => _errors.stream;
  @override
  bool get canSend => _socket != null;
  @override
  String get description => _socket?.remoteAddress.address ?? 'TCP';

  @override
  Future<void> open(NetworkConnectionConfig config) async {
    // 句柄转交给实例字段，并由 close() 统一关闭。
    // ignore: close_sinks
    final socket = await Socket.connect(
      config.host,
      config.port,
      timeout: const Duration(seconds: 8),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _subscription = socket.listen(
      (bytes) => _data.add(Uint8List.fromList(bytes)),
      onError: _errors.add,
      onDone: () => _errors.add(StateError('TCP远端已断开')),
      cancelOnError: true,
    );
  }

  @override
  Future<int> write(Uint8List data) async {
    final socket = _socket;
    if (socket == null) return 0;
    socket.add(data);
    await socket.flush();
    return data.length;
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close();
    await _data.close();
    await _errors.close();
  }
}

class TcpServerNetworkTransport implements NetworkTransport {
  final _data = StreamController<Uint8List>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  ServerSocket? _server;
  Socket? _client;
  StreamSubscription<Socket>? _serverSubscription;
  StreamSubscription<Uint8List>? _clientSubscription;

  @override
  Stream<Uint8List> get dataStream => _data.stream;
  @override
  Stream<Object> get errorStream => _errors.stream;
  @override
  bool get canSend => _client != null;
  @override
  String get description => _client == null ? 'TCP监听中' : 'TCP客户端已连接';

  @override
  Future<void> open(NetworkConnectionConfig config) async {
    final server = await ServerSocket.bind(config.host, config.port);
    _server = server;
    _serverSubscription = server.listen(_acceptClient, onError: _errors.add);
  }

  void _acceptClient(Socket socket) {
    if (_client != null) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _client = socket;
    _clientSubscription = socket.listen(
      (bytes) => _data.add(Uint8List.fromList(bytes)),
      onError: (Object _) {
        if (identical(_client, socket)) _client = null;
        socket.destroy();
      },
      onDone: () {
        if (identical(_client, socket)) _client = null;
      },
      cancelOnError: true,
    );
  }

  @override
  Future<int> write(Uint8List data) async {
    final client = _client;
    if (client == null) return 0;
    client.add(data);
    await client.flush();
    return data.length;
  }

  @override
  Future<void> close() async {
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    final client = _client;
    _client = null;
    await _clientSubscription?.cancel();
    _clientSubscription = null;
    client?.destroy();
    await _server?.close();
    _server = null;
    await _data.close();
    await _errors.close();
  }
}

class UdpNetworkTransport implements NetworkTransport {
  final _data = StreamController<Uint8List>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  RawDatagramSocket? _socket;
  InternetAddress? _remoteAddress;
  int? _remotePort;

  @override
  Stream<Uint8List> get dataStream => _data.stream;
  @override
  Stream<Object> get errorStream => _errors.stream;
  @override
  bool get canSend => _socket != null;
  @override
  String get description => 'UDP';

  @override
  Future<void> open(NetworkConnectionConfig config) async {
    final addresses = await InternetAddress.lookup(config.host);
    if (addresses.isEmpty) throw StateError('无法解析UDP远端地址');
    _remoteAddress = addresses.first;
    _remotePort = config.port;
    final bindAddress =
        _remoteAddress!.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4;
    final socket = await RawDatagramSocket.bind(
      bindAddress,
      config.localPort ?? 0,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        final datagram = packet!;
        if (datagram.address.address == _remoteAddress!.address &&
            datagram.port == _remotePort) {
          _data.add(Uint8List.fromList(datagram.data));
        }
      }
    }, onError: _errors.add);
  }

  @override
  Future<int> write(Uint8List data) async {
    final socket = _socket;
    final address = _remoteAddress;
    final port = _remotePort;
    if (socket == null || address == null || port == null) return 0;
    return socket.send(data, address, port);
  }

  @override
  Future<void> close() async {
    _socket?.close();
    _socket = null;
    await _data.close();
    await _errors.close();
  }
}

NetworkTransport createNetworkTransport(DataConnectionType type) =>
    switch (type) {
      DataConnectionType.tcpClient => TcpClientNetworkTransport(),
      DataConnectionType.tcpServer => TcpServerNetworkTransport(),
      DataConnectionType.udp => UdpNetworkTransport(),
      DataConnectionType.serial => throw ArgumentError('串口不属于网络传输'),
    };
