import 'dart:async';
import 'dart:typed_data';

import '../../services/data_connection_service.dart';
import 'data_source.dart';

/// 当前活动数据连接的数据源。
class ConnectionDataSource implements IDataSource {
  final DataConnectionService _connectionService;
  StreamSubscription? _subscription;
  final _controller = StreamController<Uint8List>.broadcast();

  ConnectionDataSource(this._connectionService);

  @override
  Stream<Uint8List> get byteStream => _controller.stream;

  @override
  bool get isActive => _subscription != null;

  @override
  String get name => '数据连接';

  @override
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _connectionService.dataStream.listen(
      (packet) {
        if (!_controller.isClosed) {
          _controller.add(packet.data);
        }
      },
      onError: (error) {
        // 连接错误由DataConnectionService统一记录和更新状态。
      },
    );
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
