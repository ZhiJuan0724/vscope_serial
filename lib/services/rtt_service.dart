import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/utils/app_logger.dart';
import '../data/models/probe_plot_config.dart';
import '../data/models/rtt_config.dart';
import 'app_notifications.dart';
import 'app_settings.dart';
import 'connection_owner_service.dart';
import 'elf_symbol_reader.dart';
import 'rtt_backend.dart';
import 'rtt_process_backends.dart';
import 'rtt_receive_queue.dart';

bool _hasUsableAutomaticOpenOcdConfig(RttConnectionConfig config) {
  return config.openOcdInterfaceConfig.trim().isNotEmpty &&
      config.openOcdTargetConfig.trim().isNotEmpty;
}

class _RttConnectCancelled implements Exception {
  const _RttConnectCancelled();
}

/// 从最近一次成功连接保存的设置创建快捷连接参数。
///
/// 显式后端会约束探针类型，防止旧设置中的类型与后端不匹配。
RttConnectionConfig savedRttConnectionConfig([AppSettings? source]) {
  final settings = source ?? AppSettings();
  final backend = RttBackendSelection.fromString(settings.rttBackendSelection);
  final savedKind = RttProbeKind.fromString(settings.rttProbeKind);
  final kind = switch (backend) {
    RttBackendSelection.externalJlink => RttProbeKind.jlink,
    RttBackendSelection.bundledOpenocd ||
    RttBackendSelection.externalOpenocd ||
    RttBackendSelection.externalPyocd => RttProbeKind.cmsisDap,
    RttBackendSelection.automatic => savedKind,
  };
  return RttConnectionConfig(
    backend: backend,
    probeKind: kind,
    probeId: settings.rttLastProbeId,
    target: settings.rttTarget,
    autoDetectTarget: settings.rttAutoDetectTarget,
    wireProtocol: RttWireProtocol.fromString(settings.rttWireProtocol),
    clockKhz: settings.rttClockKhz,
    controlBlockMode: RttControlBlockMode.fromString(
      settings.rttControlBlockMode,
    ),
    controlBlockAddress: settings.rttControlBlockAddress,
    controlBlockRangeStart: settings.rttControlBlockRangeStart,
    controlBlockRangeEnd: settings.rttControlBlockRangeEnd,
    openOcdInterfaceConfig: settings.rttOpenocdInterfaceConfig,
    openOcdTargetConfig: settings.rttOpenocdTargetConfig,
    pyOcdCmsisDapVersion: PyOcdCmsisDapVersion.fromString(
      settings.rttPyocdCmsisDapVersion,
    ),
  );
}

/// RTT 连接、后端选择和接收队列的唯一所有者。
class RttService extends ChangeNotifier {
  RttService({
    ConnectionOwnerService? connectionOwners,
    RttReceiveQueue? receiveQueue,
    List<RttBackend>? backends,
  }) : _connectionOwners = connectionOwners ?? ConnectionOwnerService(),
       _receiveQueue = receiveQueue ?? RttReceiveQueue() {
    final settings = AppSettings();
    _backends =
        backends ??
        [
          ExternalJLinkBackend(
            configuredPath: () => settings.rttJlinkExecutablePath,
          ),
          ExternalOpenOcdBackend(
            configuredPath: () => settings.rttOpenocdExecutablePath,
          ),
          ExternalOpenOcdBackend(
            configuredPath: () => '',
            bundledRuntime: true,
          ),
          ExternalPyOcdBackend(
            configuredPythonPath: () => settings.rttPyocdPythonPath,
          ),
        ];
  }

  final ConnectionOwnerService _connectionOwners;
  final RttReceiveQueue _receiveQueue;
  late final List<RttBackend> _backends;
  // 由可等待的 shutdown() 统一关闭；dispose() 会启动同一收敛流程。
  // ignore: close_sinks
  final StreamController<void> _dataAvailableController =
      StreamController<void>.broadcast(sync: true);
  // ignore: close_sinks
  final StreamController<RttDataChunk> _probePlotDataController =
      StreamController<RttDataChunk>.broadcast(sync: true);
  // ignore: close_sinks
  final StreamController<ProbeSampleChunk> _probeSamplesController =
      StreamController<ProbeSampleChunk>.broadcast(sync: true);
  StreamSubscription<RttDataChunk>? _dataSubscription;
  StreamSubscription<String>? _diagnosticSubscription;
  StreamSubscription<ProbeSampleChunk>? _sampleSubscription;
  Timer? _connectionMonitor;
  RttBackend? _activeBackend;
  RttProbeKind? _activeProbeKind;
  ProbeActivityOwner _activityOwner = ProbeActivityOwner.none;
  RttConnectionState _state = RttConnectionState.disconnected;
  String? _lastError;
  String _diagnostic = '';
  int _receivedBytes = 0;
  bool _handlingUnexpectedDisconnect = false;
  bool _disposed = false;
  int _connectionGeneration = 0;
  Future<void>? _shutdownFuture;

  RttConnectionState get state => _state;
  bool get isConnected => _state == RttConnectionState.connected;
  bool get isConnecting =>
      _state == RttConnectionState.connecting ||
      _state == RttConnectionState.reconnecting;
  bool get isReconnecting => _state == RttConnectionState.reconnecting;
  String? get lastError => _lastError;
  String get diagnostic => _diagnostic;
  String get activeBackendName => _activeBackend?.displayName ?? '';
  String get activeBackendId => _activeBackend?.id ?? '';
  bool get supportsAutomaticControlBlock => switch (_activeBackend) {
    final RttControlBlockConfigurable backend =>
      backend.supportsAutomaticControlBlock,
    _ => _savedBackendSupportsAutomaticControlBlock(),
  };
  RttProbeKind? get activeProbeKind => _activeProbeKind;
  ProbeActivityOwner get activityOwner => _activityOwner;
  bool get isActivityRunning => _activityOwner != ProbeActivityOwner.none;
  bool get canWriteDownChannel0 =>
      _activeBackend is RttActivityBackend &&
      (_activeBackend as RttActivityBackend).capabilities.contains(
        RttBackendCapability.downChannel0,
      );
  bool get supportsProbePlot =>
      _activeBackend is RttActivityBackend &&
      (_activeBackend as RttActivityBackend).capabilities.contains(
        RttBackendCapability.memorySampling,
      );
  int get receivedBytes => _receivedBytes;
  int get queuedBytes => _receiveQueue.queuedBytes;
  int get droppedBytes => _receiveQueue.droppedBytes;
  Stream<void> get dataAvailable => _dataAvailableController.stream;
  Stream<RttDataChunk> get probePlotData => _probePlotDataController.stream;
  Stream<ProbeSampleChunk> get probeSamples => _probeSamplesController.stream;

  bool _savedBackendSupportsAutomaticControlBlock() {
    final settings = AppSettings();
    final selection = RttBackendSelection.fromString(
      settings.rttBackendSelection,
    );
    if (selection == RttBackendSelection.externalOpenocd ||
        selection == RttBackendSelection.bundledOpenocd) {
      return false;
    }
    if (selection != RttBackendSelection.automatic) return true;
    final kind = RttProbeKind.fromString(settings.rttProbeKind);
    if (kind != RttProbeKind.cmsisDap) return true;
    return settings.rttOpenocdInterfaceConfig.trim().isEmpty ||
        settings.rttOpenocdTargetConfig.trim().isEmpty;
  }

  Future<List<RttProbeInfo>> listProbes(
    RttProbeKind kind, {
    RttBackendSelection backend = RttBackendSelection.automatic,
    RttConnectionConfig? connectionConfig,
  }) async {
    // 连接窗口在活动会话中可能被再次打开。此时刷新辅助信息不能覆盖连接
    // 状态，否则界面会显示已断开，但实际后端进程仍在运行。
    final reportsDiscovery = _state == RttConnectionState.disconnected;
    if (reportsDiscovery) _setState(RttConnectionState.discovering);
    try {
      final resolved = await _resolveBackend(
        kind,
        backend,
        connectionConfig: connectionConfig,
      );
      AppLogger().info(
        '开始枚举探针：类型=${kind.label}，后端=${resolved.displayName}',
        category: 'RTT',
      );
      final probes =
          resolved is ConfiguredRttProbeDiscovery && connectionConfig != null
              ? await (resolved as ConfiguredRttProbeDiscovery)
                  .listProbesForConfig(connectionConfig)
              : await resolved.listProbes(kind);
      AppLogger().info(
        '探针枚举完成：后端=${resolved.displayName}，数量=${probes.length}',
        category: 'RTT',
      );
      return probes;
    } catch (error, stackTrace) {
      AppLogger().error(
        '探针枚举失败：类型=${kind.label}，选择=${backend.label}，$error',
        category: 'RTT',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      if (reportsDiscovery && _state == RttConnectionState.discovering) {
        _setState(RttConnectionState.disconnected);
      }
    }
  }

  Future<List<RttTargetInfo>> listTargets(
    RttProbeKind kind, {
    RttBackendSelection backend = RttBackendSelection.automatic,
    RttConnectionConfig? connectionConfig,
  }) async {
    try {
      final resolved = await _resolveBackend(
        kind,
        backend,
        connectionConfig: connectionConfig,
      );
      AppLogger().info(
        '开始读取目标芯片列表：类型=${kind.label}，后端=${resolved.displayName}',
        category: 'RTT',
      );
      final targets = await resolved.listTargets(kind);
      AppLogger().info(
        '目标芯片列表读取完成：后端=${resolved.displayName}，数量=${targets.length}',
        category: 'RTT',
      );
      return targets;
    } catch (error, stackTrace) {
      AppLogger().error(
        '目标芯片列表读取失败：类型=${kind.label}，选择=${backend.label}，$error',
        category: 'RTT',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 按当前设置解析连接时将实际使用的后端，但不枚举或连接探针。
  ///
  /// 连接窗口与正式连接共用此选择逻辑，避免自动回退状态与实际行为不一致。
  Future<String> expectedBackendName(
    RttProbeKind kind, {
    RttBackendSelection backend = RttBackendSelection.automatic,
    RttConnectionConfig? connectionConfig,
  }) async {
    final resolved = await _resolveBackend(
      kind,
      backend,
      requireNonIntrusiveTargetAccess: true,
      connectionConfig: connectionConfig,
    );
    return resolved.displayName;
  }

  /// 检测设置页展示的三个后端，不触发探针连接。
  Future<Map<String, RttBackendAvailability>> checkBackendAvailability() async {
    final result = <String, RttBackendAvailability>{};
    for (final backend in _backends) {
      final kind = switch (backend.id) {
        'external-jlink' => RttProbeKind.jlink,
        'bundled-openocd' => RttProbeKind.cmsisDap,
        'external-openocd' => RttProbeKind.cmsisDap,
        'external-pyocd' => RttProbeKind.cmsisDap,
        _ => RttProbeKind.jlink,
      };
      try {
        AppLogger().info('检测探针后端：${backend.displayName}', category: 'RTT');
        final available = await backend.isAvailable(kind);
        String? version;
        if (available && backend is RttBackendVersionProvider) {
          try {
            version = await (backend as RttBackendVersionProvider)
                .detectVersion(kind);
          } catch (error) {
            // 工具已找到但版本命令失败时仍应报告可用，避免误导为未安装。
            AppLogger().warning(
              '探针后端版本检测失败：${backend.displayName}，$error',
              category: 'RTT',
            );
          }
        }
        result[backend.id] = RttBackendAvailability(
          available: available,
          version: version,
        );
        AppLogger().info(
          '探针后端检测完成：${backend.displayName}，'
          '可用=$available${version == null ? '' : '，版本=$version'}',
          category: 'RTT',
        );
      } catch (error, stackTrace) {
        result[backend.id] = const RttBackendAvailability(available: false);
        AppLogger().error(
          '探针后端检测失败：${backend.displayName}，$error',
          category: 'RTT',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return result;
  }

  Future<void> connect(RttConnectionConfig config) async {
    if (isConnected || isConnecting) return;
    if (!_connectionOwners.tryAcquire(ConnectionOwner.rtt)) {
      throw StateError('数据连接已占用连接入口，请先手动断开数据连接');
    }
    _lastError = null;
    _handlingUnexpectedDisconnect = false;
    _receivedBytes = 0;
    _receiveQueue.clear(resetDropped: true);
    _setState(RttConnectionState.connecting);
    final generation = ++_connectionGeneration;
    try {
      final backend = await _resolveBackend(
        config.probeKind,
        config.backend,
        requireNonIntrusiveTargetAccess: true,
        connectionConfig: config,
      );
      if (generation != _connectionGeneration) {
        throw const _RttConnectCancelled();
      }
      AppLogger().info(
        '开始连接探针：类型=${config.probeKind.label}，后端=${backend.displayName}，'
        '接口=${config.wireProtocol.label}，时钟=${config.clockKhz}kHz',
        category: 'RTT',
      );
      // 绑定数据流前先登记活动后端，保证连接阶段的任何输出都按“尚未开始”
      // 处理；同时连接中途失败时 _unbindBackend 能可靠清理该后端。
      _activeBackend = backend;
      _activeProbeKind = config.probeKind;
      _activityOwner = ProbeActivityOwner.none;
      await _bindBackend(backend);
      await backend.connect(config);
      if (generation != _connectionGeneration ||
          !identical(_activeBackend, backend)) {
        await backend.disconnect();
        throw const _RttConnectCancelled();
      }
      _persistConnection(config);
      _setState(RttConnectionState.connected);
      AppLogger().info(
        '探针连接成功：类型=${config.probeKind.label}，后端=${backend.displayName}',
        category: 'RTT',
      );
      _startConnectionMonitor();
    } on _RttConnectCancelled {
      await _unbindBackend(disconnect: true);
      _connectionOwners.release(ConnectionOwner.rtt);
      _setState(RttConnectionState.disconnected);
      rethrow;
    } catch (error, stackTrace) {
      // disconnect() 可能在 backend.connect() 尚未返回时终止底层进程，
      // 此时后端通常抛出进程退出或 Socket 异常。连接代次已经失效就应按
      // 用户取消处理，不能把预期的取消显示成连接失败。
      if (generation != _connectionGeneration) {
        await _unbindBackend(disconnect: true);
        _connectionOwners.release(ConnectionOwner.rtt);
        _setState(RttConnectionState.disconnected);
        throw const _RttConnectCancelled();
      }
      _lastError = '$error';
      AppLogger().error(
        'RTT 连接失败: $error',
        category: 'RTT',
        error: error,
        stackTrace: stackTrace,
      );
      await _unbindBackend(disconnect: true);
      _connectionOwners.release(ConnectionOwner.rtt);
      _setState(RttConnectionState.disconnected);
      rethrow;
    }
  }

  Future<RttBackend> _resolveBackend(
    RttProbeKind kind,
    RttBackendSelection selection, {
    bool requireNonIntrusiveTargetAccess = false,
    RttConnectionConfig? connectionConfig,
  }) async {
    if (selection != RttBackendSelection.automatic) {
      final backend = _backends.firstWhere(
        (item) => item.id == selection.value,
        orElse:
            () =>
                throw RttBackendUnavailableException(
                  '后端不存在：${selection.label}',
                ),
      );
      if (requireNonIntrusiveTargetAccess &&
          !backend.guaranteesNonIntrusiveTargetAccess) {
        throw RttBackendUnavailableException(
          backend.nonIntrusiveSafetyBlockReason ??
              '${backend.displayName} 无法保证非侵入式目标访问',
        );
      }
      if (!await backend.isAvailable(kind)) {
        throw RttBackendUnavailableException(
          '${selection.label} 不支持 ${kind.label}，或工具路径无效',
        );
      }
      return backend;
    }

    // CMSIS-DAP 优先外置、再内置 OpenOCD，最后使用外置 pyOCD；
    // 连接阶段只要求 OpenOCD 接口和目标脚本完整，
    // RTT 控制块由具体数据活动开始前单独配置。
    final candidateIds =
        kind == RttProbeKind.jlink
            ? const ['external-jlink']
            : const ['external-openocd', 'bundled-openocd', 'external-pyocd'];
    for (final id in candidateIds) {
      final matches = _backends.where((item) => item.id == id);
      if (matches.isEmpty) continue;
      final backend = matches.first;
      if ((id == 'external-openocd' || id == 'bundled-openocd') &&
          connectionConfig != null &&
          !_hasUsableAutomaticOpenOcdConfig(connectionConfig)) {
        AppLogger().info('自动选择跳过 OpenOCD：接口或目标配置不完整', category: 'RTT');
        continue;
      }
      if (requireNonIntrusiveTargetAccess &&
          !backend.guaranteesNonIntrusiveTargetAccess) {
        AppLogger().warning(
          '自动选择跳过非安全探针后端：${backend.displayName}，'
          '${backend.nonIntrusiveSafetyBlockReason ?? '无法保证目标持续运行'}',
          category: 'RTT',
        );
        continue;
      }
      final available = await backend.isAvailable(kind);
      AppLogger().info(
        '自动选择探针后端：类型=${kind.label}，'
        '候选=${backend.displayName}，可用=$available',
        category: 'RTT',
      );
      if (available) return backend;
    }
    throw const RttBackendUnavailableException('没有可用的探针后端');
  }

  Future<void> _bindBackend(RttBackend backend) async {
    await _dataSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    _dataSubscription = backend.dataStream.listen(_handleData);
    _diagnosticSubscription = backend.diagnosticStream.listen((message) {
      _diagnostic = message;
      _notify();
      if (_state == RttConnectionState.connected &&
          identical(_activeBackend, backend) &&
          !backend.isConnected) {
        unawaited(_handleUnexpectedDisconnect());
      }
    });
    await _sampleSubscription?.cancel();
    _sampleSubscription =
        backend is ProbePlotBackend
            ? (backend as ProbePlotBackend).sampleStream.listen(
              _probeSamplesController.add,
            )
            : null;
  }

  void _handleData(RttDataChunk chunk) {
    if (_activityOwner == ProbeActivityOwner.probePlot) {
      if (!_probePlotDataController.isClosed && chunk.data.isNotEmpty) {
        _probePlotDataController.add(chunk);
      }
      return;
    }
    // 连接探针不等于开始 RTT Viewer。无论后端是否具备活动控制接口，
    // 都必须等用户明确点击“开始”后，数据才能进入接收队列和历史。
    if (_activityOwner != ProbeActivityOwner.rttViewer ||
        chunk.channel != 0 ||
        chunk.data.isEmpty) {
      return;
    }
    final wasEmpty = !_receiveQueue.isNotEmpty;
    _receivedBytes += chunk.data.length;
    _receiveQueue.add(chunk);
    if (wasEmpty && !_dataAvailableController.isClosed) {
      _dataAvailableController.add(null);
    }
  }

  List<RttDataChunk> drainUpTo(int byteLimit) =>
      _receiveQueue.removeUpTo(byteLimit);

  /// 清除当前 RTT 显示会话的服务层数据和统计。
  ///
  /// 已经交给 ViewModel 的重建历史由 ViewModel 自行清理；这里专门处理
  /// 服务层队列、过载计数和接收字节数，使状态栏与已清空的内容一致。
  void clearBufferedData() {
    _receiveQueue.clear(resetDropped: true);
    _receivedBytes = 0;
    _notify();
  }

  /// 启动 RTT Viewer 数据活动，但保持探针连接由独立生命周期管理。
  Future<void> startRttViewer() async {
    if (!isConnected) throw StateError('请先连接探针');
    if (_activityOwner == ProbeActivityOwner.rttViewer) return;
    if (_activityOwner != ProbeActivityOwner.none) {
      throw StateError('探针绘图正在运行，请先停止');
    }
    final backend = _activeBackend;
    await _configureRttControlBlock(
      backend,
      pollingIntervalMs: AppSettings().rttViewerPollingIntervalMs,
    );
    // 点击开始即建立接收边界，避免后端启动命令同步返回首批数据时被误丢弃。
    _activityOwner = ProbeActivityOwner.rttViewer;
    try {
      if (backend is RttActivityBackend) {
        await (backend as RttActivityBackend).startRttViewer();
      }
    } catch (_) {
      _activityOwner = ProbeActivityOwner.none;
      _notify();
      rethrow;
    }
    _notify();
  }

  /// 为探针绘图占用当前探针会话。
  ///
  /// 实际采样命令由探针绘图服务发送；这里仅原子管理页面活动所有权。
  Future<void> startProbePlot() async {
    if (!isConnected) throw StateError('请先连接探针');
    if (_activityOwner == ProbeActivityOwner.probePlot) return;
    if (_activityOwner != ProbeActivityOwner.none) {
      throw StateError('RTT Viewer 正在运行，请先停止');
    }
    if (!supportsProbePlot) {
      throw StateError('当前探针后端不支持绘图或运行态内存采样');
    }
    _activityOwner = ProbeActivityOwner.probePlot;
    _notify();
  }

  Future<void> startRttProbePlot(String channelName) async {
    await _configureRttControlBlock(
      _activeBackend,
      pollingIntervalMs: AppSettings().probeRttPollingIntervalMs,
    );
    await startProbePlot();
    final backend = _activeBackend;
    try {
      await (backend as ProbePlotBackend).startRttPlot(channelName);
    } catch (_) {
      _activityOwner = ProbeActivityOwner.none;
      _notify();
      rethrow;
    }
  }

  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) async {
    await startProbePlot();
    final backend = _activeBackend;
    if (backend is! ProbePlotBackend) {
      _activityOwner = ProbeActivityOwner.none;
      _notify();
      throw StateError('HSS 需要使用支持运行态内存读取的探针后端');
    }
    try {
      await (backend as ProbePlotBackend).startHss(
        variables,
        frequencyHz: frequencyHz,
      );
    } catch (_) {
      _activityOwner = ProbeActivityOwner.none;
      _notify();
      rethrow;
    }
  }

  Future<List<ProbeSymbolInfo>> readProbeSymbols(String path) async {
    return readElfDataSymbols(path);
  }

  Future<List<RttChannelInfo>> listRttUpChannels() async {
    final backend = _activeBackend;
    if (backend is! RttChannelMetadataProvider) return const [];
    await _configureRttControlBlock(
      backend,
      pollingIntervalMs: AppSettings().probeRttPollingIntervalMs,
    );
    return (backend as RttChannelMetadataProvider).listRttUpChannels();
  }

  Future<void> _configureRttControlBlock(
    RttBackend? backend, {
    required int pollingIntervalMs,
  }) async {
    if (backend is! RttControlBlockConfigurable) return;
    final settings = AppSettings();
    await (backend as RttControlBlockConfigurable).configureRttControlBlock(
      RttControlBlockConfig(
        mode: RttControlBlockMode.fromString(settings.rttControlBlockMode),
        address: settings.rttControlBlockAddress,
        rangeStart: settings.rttControlBlockRangeStart,
        rangeEnd: settings.rttControlBlockRangeEnd,
        pollingIntervalMs: pollingIntervalMs,
      ),
    );
  }

  /// 停止当前功能但保留探针和目标会话。
  Future<void> stopActivity() async {
    if (_activityOwner == ProbeActivityOwner.none) return;
    final backend = _activeBackend;
    if (backend?.id == RttBackendSelection.externalJlink.value) {
      _connectionMonitor?.cancel();
      _connectionMonitor = null;
      _setState(RttConnectionState.reconnecting);
      AppLogger().info('J-Link 正在停止 RTT：终止当前后端并重新建立空闲目标会话', category: 'RTT');
      try {
        await (backend as RttActivityBackend).stopActivity();
        _activityOwner = ProbeActivityOwner.none;
        _setState(RttConnectionState.connected);
        _startConnectionMonitor();
        AppLogger().info('J-Link RTT 已停止，空闲目标会话已重新连接', category: 'RTT');
      } catch (error, stackTrace) {
        _lastError = 'J-Link 停止后自动重连失败：$error';
        AppLogger().error(
          _lastError!,
          category: 'RTT',
          error: error,
          stackTrace: stackTrace,
        );
        await _unbindBackend(disconnect: true);
        _connectionOwners.release(ConnectionOwner.rtt);
        _setState(RttConnectionState.disconnected);
        AppNotifications.show(_lastError!);
      }
      return;
    }
    if (backend is RttActivityBackend) {
      await (backend as RttActivityBackend).stopActivity();
    }
    _activityOwner = ProbeActivityOwner.none;
    _notify();
  }

  Future<void> writeDownChannel0(Uint8List data) async {
    if (_activityOwner != ProbeActivityOwner.rttViewer) {
      throw StateError('RTT Viewer 尚未开始');
    }
    final backend = _activeBackend;
    if (backend is! RttActivityBackend) {
      throw StateError('当前后端不支持 RTT Down 0');
    }
    final activityBackend = backend as RttActivityBackend;
    if (!activityBackend.capabilities.contains(
      RttBackendCapability.downChannel0,
    )) {
      throw StateError('当前后端不支持 RTT Down 0');
    }
    await activityBackend.writeDownChannel0(data);
  }

  Future<void> disconnect() async {
    // 使正在解析后端或等待探针的 connect 路径立即失效。
    _connectionGeneration++;
    final backendName = _activeBackend?.displayName;
    AppLogger().info(
      '开始断开探针${backendName == null ? '' : '：后端=$backendName'}',
      category: 'RTT',
    );
    _lastError = null;
    if (_activeBackend?.id == RttBackendSelection.externalJlink.value &&
        _activityOwner != ProbeActivityOwner.none) {
      _activityOwner = ProbeActivityOwner.none;
    } else {
      await stopActivity();
    }
    await _unbindBackend(disconnect: true);
    _connectionOwners.release(ConnectionOwner.rtt);
    _setState(RttConnectionState.disconnected);
    AppLogger().info('探针已断开', category: 'RTT');
  }

  Future<void> _handleUnexpectedDisconnect() async {
    if (_state == RttConnectionState.disconnected ||
        _handlingUnexpectedDisconnect) {
      return;
    }
    _handlingUnexpectedDisconnect = true;
    try {
      final backend = _activeBackend;
      final backendFailure =
          backend is RttBackendFailureProvider
              ? (backend as RttBackendFailureProvider).lastFailure
              : null;
      _lastError =
          backendFailure ??
          (_diagnostic.isNotEmpty ? _diagnostic : 'RTT 探针连接已断开');
      AppLogger().warning('探针意外断开：$_lastError', category: 'RTT');
      // 后端虽已报告断线，仍执行一次完整资源清理，关闭 Tcl/RTT 附加
      // socket，并回收可能尚未退出的外部工具进程。
      await _unbindBackend(disconnect: true);
      _connectionOwners.release(ConnectionOwner.rtt);
      _setState(RttConnectionState.disconnected);
      AppNotifications.show(_lastError!);
    } finally {
      _handlingUnexpectedDisconnect = false;
    }
  }

  void _startConnectionMonitor() {
    _connectionMonitor?.cancel();
    _connectionMonitor = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_activeBackend != null && !_activeBackend!.isConnected) {
        unawaited(_handleUnexpectedDisconnect());
      }
    });
  }

  Future<void> _unbindBackend({required bool disconnect}) async {
    _connectionMonitor?.cancel();
    _connectionMonitor = null;
    final backend = _activeBackend;
    _activeBackend = null;
    _activeProbeKind = null;
    _activityOwner = ProbeActivityOwner.none;
    if (disconnect) await backend?.disconnect();
    await _dataSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    await _sampleSubscription?.cancel();
    _dataSubscription = null;
    _diagnosticSubscription = null;
    _sampleSubscription = null;
  }

  void _persistConnection(RttConnectionConfig config) {
    final settings =
        AppSettings()
          ..rttProbeKind = config.probeKind.value
          ..rttBackendSelection = config.backend.value
          ..rttLastProbeId = config.probeId
          ..rttTarget = config.target
          ..rttAutoDetectTarget = config.autoDetectTarget
          ..rttWireProtocol = config.wireProtocol.value
          ..rttClockKhz = config.clockKhz
          ..rttControlBlockMode = config.controlBlockMode.value
          ..rttControlBlockAddress = config.controlBlockAddress
          ..rttControlBlockRangeStart = config.controlBlockRangeStart
          ..rttControlBlockRangeEnd = config.controlBlockRangeEnd
          ..rttOpenocdInterfaceConfig = config.openOcdInterfaceConfig
          ..rttOpenocdTargetConfig = config.openOcdTargetConfig
          ..rttPyocdCmsisDapVersion = config.pyOcdCmsisDapVersion.value;
    unawaited(settings.save());
  }

  void _setState(RttConnectionState value) {
    if (_state == value) return;
    _state = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 完整收敛连接、订阅、后端进程和内部流。
  ///
  /// 窗口关闭路径必须 await 此方法；[dispose] 仅作为 Flutter 同步
  /// 生命周期的兜底入口。
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runBestEffort(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await runBestEffort(disconnect);
    _connectionMonitor?.cancel();
    _connectionMonitor = null;
    await runBestEffort(() async => _dataSubscription?.cancel());
    await runBestEffort(() async => _diagnosticSubscription?.cancel());
    await runBestEffort(() async => _sampleSubscription?.cancel());
    for (final backend in _backends) {
      await runBestEffort(backend.dispose);
    }
    if (!_dataAvailableController.isClosed) {
      await runBestEffort(_dataAvailableController.close);
    }
    if (!_probePlotDataController.isClosed) {
      await runBestEffort(_probePlotDataController.close);
    }
    if (!_probeSamplesController.isClosed) {
      await runBestEffort(_probeSamplesController.close);
    }
    _connectionOwners.release(ConnectionOwner.rtt);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
