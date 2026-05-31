import 'dart:typed_data';

/// 串口数据包模型
class DataPacket {
  final Uint8List data;
  final DateTime timestamp;

  DataPacket({required this.data, DateTime? timestamp})
    : timestamp = timestamp ?? DateTime.now();

  String get text => String.fromCharCodes(data);

  String get hex => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
