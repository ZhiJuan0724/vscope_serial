import 'dart:typed_data';

/// 数据连接接收包，保留数据到达应用时的时间戳。
class DataPacket {
  final Uint8List data;
  final DateTime timestamp;
  final int monotonicUs;

  DataPacket({required this.data, DateTime? timestamp, int? monotonicUs})
    : timestamp = timestamp ?? DateTime.now(),
      monotonicUs = monotonicUs ?? _monotonicClock.elapsedMicroseconds;

  static final Stopwatch _monotonicClock = Stopwatch()..start();

  String get text => String.fromCharCodes(data);

  String get hex => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
