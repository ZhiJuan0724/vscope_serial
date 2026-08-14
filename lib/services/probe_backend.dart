import '../data/models/probe_connection_config.dart';
import '../data/models/probe_plot_config.dart';
import 'dart:typed_data';

/// RTT 后端统一接口。
///
/// 当前页面只展示 Up 0，但事件保留通道号，后续增加多通道和绘图时无需改变
/// 进程协议或连接生命周期。
abstract interface class ProbeBackend {
  String get id;
  String get displayName;

  /// 只有明确保证连接、读写和断开均不会 halt/reset/resume 目标时才可为 true。
  bool get guaranteesNonIntrusiveTargetAccess;
  String? get nonIntrusiveSafetyBlockReason;
  Stream<RttDataChunk> get dataStream;
  Stream<String> get diagnosticStream;
  bool get isConnected;

  Future<bool> isAvailable(ProbeKind kind);
  Future<List<ProbeInfo>> listProbes(ProbeKind kind);
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind);
  Future<void> connect(ProbeConnectionConfig config);
  Future<void> disconnect();
  Future<void> dispose();
}

/// 可额外报告工具版本的 RTT 后端。
abstract interface class ProbeBackendVersionProvider {
  Future<String?> detectVersion(ProbeKind kind);
}

/// 可在不安装、解压或初始化运行时的前提下报告后端可用性。
///
/// 设置页首次展示等被动检测必须使用该接口，避免用户尚未选择内置工具时
/// 就产生耗时且会写入磁盘的准备操作。
abstract interface class PassiveProbeBackendAvailabilityProvider {
  Future<ProbeBackendAvailability> checkAvailabilityWithoutPreparation(
    ProbeKind kind,
  );
}

/// 枚举行为依赖连接配置的后端扩展。
abstract interface class ConfiguredProbeDiscovery {
  Future<List<ProbeInfo>> listProbesForConfig(ProbeConnectionConfig config);
}

/// 可报告后台进程或 RTT 传输意外中断原因的后端。
abstract interface class ProbeBackendFailureProvider {
  String? get lastFailure;
}

/// 支持连接与 RTT 数据活动分离的后端。
///
/// 旧外部后端可暂时只实现 [ProbeBackend]；服务层会把连接期间已启动的数据流
/// 视为兼容模式。支持双向 socket 的后端应实现此接口。
abstract interface class RttActivityBackend {
  Set<ProbeBackendCapability> get capabilities;

  Future<void> startRttViewer();
  Future<void> stopActivity();
  Future<void> writeDownChannel0(Uint8List data);
}

/// 支持在保持目标会话期间、开始 RTT 活动前更新控制块定位。
abstract interface class RttControlBlockConfigurable {
  bool get supportsAutomaticControlBlock;

  Future<void> configureRttControlBlock(RttControlBlockConfig config);
}

/// 支持 HSS 或 RTT 绘图的后端扩展能力。
abstract interface class ProbePlotBackend {
  Stream<ProbeSampleChunk> get sampleStream;

  Future<List<ProbeSymbolInfo>> readSymbols(String path);
  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  });
  Future<void> startRttPlot(String channelName);
}

/// 能从已连接目标的 SEGGER RTT 控制块读取通道元数据。
abstract interface class RttChannelMetadataProvider {
  Future<List<RttChannelInfo>> listRttUpChannels();
}

/// 设置页展示的后端检测结果。
class ProbeBackendAvailability {
  const ProbeBackendAvailability({required this.available, this.version});

  final bool available;
  final String? version;
}

class ProbeBackendUnavailableException implements Exception {
  const ProbeBackendUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}
