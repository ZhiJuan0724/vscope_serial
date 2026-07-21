import '../data/models/rtt_config.dart';

/// RTT 后端统一接口。
///
/// 当前页面只展示 Up 0，但事件保留通道号，后续增加多通道和绘图时无需改变
/// 进程协议或连接生命周期。
abstract interface class RttBackend {
  String get id;
  String get displayName;
  Stream<RttDataChunk> get dataStream;
  Stream<String> get diagnosticStream;
  bool get isConnected;

  Future<bool> isAvailable(RttProbeKind kind);
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind);
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind);
  Future<void> connect(RttConnectionConfig config);
  Future<void> disconnect();
  Future<void> dispose();
}

/// 可额外报告工具版本的 RTT 后端。
abstract interface class RttBackendVersionProvider {
  Future<String?> detectVersion(RttProbeKind kind);
}

/// 可报告后台进程或 RTT 传输意外中断原因的后端。
abstract interface class RttBackendFailureProvider {
  String? get lastFailure;
}

/// 设置页展示的后端检测结果。
class RttBackendAvailability {
  const RttBackendAvailability({required this.available, this.version});

  final bool available;
  final String? version;
}

class RttBackendUnavailableException implements Exception {
  const RttBackendUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}
