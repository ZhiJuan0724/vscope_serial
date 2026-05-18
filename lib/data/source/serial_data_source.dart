import 'dart:async';
import 'dart:typed_data';

import '../../services/serial_service.dart';
import 'data_source.dart';

/// 串口数据源
class SerialDataSource implements IDataSource {
  final SerialService _serialService;
  StreamSubscription? _subscription;
  final _controller = StreamController<Uint8List>.broadcast();

  SerialDataSource(this._serialService);

  @override
  Stream<Uint8List> get byteStream => _controller.stream;

  @override
  bool get isActive => _subscription != null;

  @override
  String get name => '串口';

  @override
  void start() {
    if (_subscription != null) return;
    _subscription = _serialService.dataStream.listen(
      (packet) {
        if (!_controller.isClosed) {
          _controller.add(packet.data);
        }
      },
      onError: (error) {
        // 串口错误静默处理，由 SerialService 负责日志
      },
    );
  }

  @override
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
