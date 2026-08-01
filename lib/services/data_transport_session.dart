import 'dart:typed_data';

import '../data/models/data_packet.dart';

/// 已打开的数据连接会话。
///
/// 串口、TCP和UDP在完成各自的打开与配置后，都通过该接口向上层提供统一的
/// 接收、错误、发送和关闭生命周期。
abstract interface class DataTransportSession {
  Stream<DataPacket> get dataStream;
  Stream<Object> get errorStream;
  bool get isOpen;
  bool get canSend;
  String get description;

  Future<int> write(Uint8List data);
  Future<void> close();
}
