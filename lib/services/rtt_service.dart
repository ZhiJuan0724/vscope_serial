import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/utils/app_logger.dart';
import '../data/models/rtt_config.dart';
import 'app_notifications.dart';
import 'app_settings.dart';
import 'connection_owner_service.dart';
import 'rtt_backend.dart';
import 'rtt_probe_rs_backend.dart';
import 'rtt_process_backends.dart';
import 'rtt_receive_queue.dart';

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
          ExternalPyOcdBackend(
            configuredPath: () => settings.rttPyocdExecutablePath,
          ),
          ProbeRsBackend(
            configuredPath: () => settings.rttBuiltinHelperPath,
            targetsDirectory: () => targetsDirectory.path,
          ),
        ];
  }

  final ConnectionOwnerService _connectionOwners;
  final RttReceiveQueue _receiveQueue;
  late final List<RttBackend> _backends;
  final StreamController<void> _dataAvailableController =
      StreamController<void>.broadcast(sync: true);
  StreamSubscription<RttDataChunk>? _dataSubscription;
  StreamSubscription<String>? _diagnosticSubscription;
  Timer? _connectionMonitor;
  RttBackend? _activeBackend;
  RttProbeKind? _activeProbeKind;
  RttConnectionState _state = RttConnectionState.disconnected;
  String? _lastError;
  String _diagnostic = '';
  int _receivedBytes = 0;
  bool _disposed = false;

  RttConnectionState get state => _state;
  bool get isConnected => _state == RttConnectionState.connected;
  bool get isConnecting => _state == RttConnectionState.connecting;
  String? get lastError => _lastError;
  String get diagnostic => _diagnostic;
  String get activeBackendName => _activeBackend?.displayName ?? '';
  RttProbeKind? get activeProbeKind => _activeProbeKind;
  int get receivedBytes => _receivedBytes;
  int get queuedBytes => _receiveQueue.queuedBytes;
  int get droppedBytes => _receiveQueue.droppedBytes;
  bool get pageEnabled => AppSettings().rttPageEnabled;
  Stream<void> get dataAvailable => _dataAvailableController.stream;

  void setPageEnabled(bool value) {
    if (isConnected || AppSettings().rttPageEnabled == value) return;
    AppSettings().rttPageEnabled = value;
    unawaited(AppSettings().save());
    _notify();
  }

  static Directory get targetsDirectory => Directory(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}config${Platform.pathSeparator}rtt'
    '${Platform.pathSeparator}targets',
  );

  Future<void> initialize() async {
    await targetsDirectory.create(recursive: true);
    final example = File(
      '${targetsDirectory.path}${Platform.pathSeparator}_example.yaml',
    );
    if (!await example.exists()) {
      try {
        final content = await rootBundle.loadString('assets/rtt/_example.yaml');
        await example.writeAsString(content, flush: true);
      } catch (error) {
        AppLogger().warning('创建 RTT 目标示例失败: $error', category: 'RTT');
      }
    }
  }

  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async {
    // 连接窗口在活动会话中可能被再次打开。此时刷新辅助信息不能覆盖连接
    // 状态，否则界面会显示已断开，但实际后端进程仍在运行。
    final reportsDiscovery = _state == RttConnectionState.disconnected;
    if (reportsDiscovery) _setState(RttConnectionState.discovering);
    try {
      final backend = await _resolveBackend(kind);
      return await backend.listProbes(kind);
    } finally {
      if (reportsDiscovery && _state == RttConnectionState.discovering) {
        _setState(RttConnectionState.disconnected);
      }
    }
  }

  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async {
    final backend = await _resolveBackend(kind);
    return backend.listTargets(kind);
  }

  /// 按当前设置解析连接时将实际使用的后端，但不枚举或连接探针。
  ///
  /// 连接窗口与正式连接共用此选择逻辑，避免自动回退状态与实际行为不一致。
  Future<String> expectedBackendName(RttProbeKind kind) async {
    final backend = await _resolveBackend(kind);
    return backend.displayName;
  }

  /// 检测设置页展示的三个后端，不触发探针连接。
  Future<Map<String, RttBackendAvailability>> checkBackendAvailability() async {
    final result = <String, RttBackendAvailability>{};
    for (final backend in _backends) {
      final kind = switch (backend.id) {
        'external-jlink' => RttProbeKind.jlink,
        'external-pyocd' => RttProbeKind.cmsisDap,
        _ => RttProbeKind.jlink,
      };
      try {
        final available = await backend.isAvailable(kind);
        String? version;
        if (available && backend is RttBackendVersionProvider) {
          try {
            version = await (backend as RttBackendVersionProvider)
                .detectVersion(kind);
          } catch (_) {
            // 工具已找到但版本命令失败时仍应报告可用，避免误导为未安装。
          }
        }
        result[backend.id] = RttBackendAvailability(
          available: available,
          version: version,
        );
      } catch (_) {
        result[backend.id] = const RttBackendAvailability(available: false);
      }
    }
    return result;
  }

  Future<void> connect(RttConnectionConfig config) async {
    if (isConnected || isConnecting) return;
    if (!_connectionOwners.tryAcquire(ConnectionOwner.rtt)) {
      throw StateError('串口已连接，请先手动断开串口');
    }
    _lastError = null;
    _receivedBytes = 0;
    _receiveQueue.clear(resetDropped: true);
    _setState(RttConnectionState.connecting);
    try {
      final backend = await _resolveBackend(config.probeKind);
      await _bindBackend(backend);
      await backend.connect(config);
      _activeBackend = backend;
      _activeProbeKind = config.probeKind;
      _persistConnection(config);
      _setState(RttConnectionState.connected);
      _connectionMonitor = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) {
        if (_activeBackend != null && !_activeBackend!.isConnected) {
          unawaited(_handleUnexpectedDisconnect());
        }
      });
    } catch (error, stackTrace) {
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

  Future<RttBackend> _resolveBackend(RttProbeKind kind) async {
    final mode = RttBackendMode.fromString(AppSettings().rttBackendMode);
    final externalId =
        kind == RttProbeKind.jlink ? 'external-jlink' : 'external-pyocd';
    final external = _backends.firstWhere((item) => item.id == externalId);
    final builtin = _backends.firstWhere(
      (item) => item.id == 'builtin-probe-rs',
    );
    if (mode == RttBackendMode.external) {
      if (!await external.isAvailable(kind)) {
        throw RttBackendUnavailableException(
          kind == RttProbeKind.jlink
              ? '未找到 JLinkGDBServerCL.exe'
              : '未找到 pyocd.exe',
        );
      }
      return external;
    }
    if (mode == RttBackendMode.builtin) {
      if (!await builtin.isAvailable(kind)) {
        throw const RttBackendUnavailableException('内置探针辅助进程不存在');
      }
      return builtin;
    }
    if (await external.isAvailable(kind)) return external;
    if (await builtin.isAvailable(kind)) return builtin;
    throw const RttBackendUnavailableException('没有可用的 RTT 后端');
  }

  Future<void> _bindBackend(RttBackend backend) async {
    await _dataSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    _dataSubscription = backend.dataStream.listen(_handleData);
    _diagnosticSubscription = backend.diagnosticStream.listen((message) {
      _diagnostic = message;
      AppLogger().info(message, category: 'RTT');
      _notify();
    });
  }

  void _handleData(RttDataChunk chunk) {
    if (chunk.channel != 0 || chunk.data.isEmpty) return;
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

  Future<void> disconnect() async {
    _lastError = null;
    await _unbindBackend(disconnect: true);
    _connectionOwners.release(ConnectionOwner.rtt);
    _setState(RttConnectionState.disconnected);
  }

  Future<void> _handleUnexpectedDisconnect() async {
    if (_state == RttConnectionState.disconnected) return;
    final backend = _activeBackend;
    final backendFailure =
        backend is RttBackendFailureProvider
            ? (backend as RttBackendFailureProvider).lastFailure
            : null;
    _lastError =
        backendFailure ??
        (_diagnostic.isNotEmpty ? _diagnostic : 'RTT 探针连接已断开');
    await _unbindBackend(disconnect: false);
    _connectionOwners.release(ConnectionOwner.rtt);
    _setState(RttConnectionState.disconnected);
    AppNotifications.show(_lastError!);
  }

  Future<void> _unbindBackend({required bool disconnect}) async {
    _connectionMonitor?.cancel();
    _connectionMonitor = null;
    final backend = _activeBackend;
    _activeBackend = null;
    _activeProbeKind = null;
    if (disconnect) await backend?.disconnect();
    await _dataSubscription?.cancel();
    await _diagnosticSubscription?.cancel();
    _dataSubscription = null;
    _diagnosticSubscription = null;
  }

  void _persistConnection(RttConnectionConfig config) {
    final settings =
        AppSettings()
          ..rttProbeKind = config.probeKind.value
          ..rttLastProbeId = config.probeId
          ..rttTarget = config.target
          ..rttAutoDetectTarget = config.autoDetectTarget
          ..rttWireProtocol = config.wireProtocol.value
          ..rttClockKhz = config.clockKhz
          ..rttControlBlockMode = config.controlBlockMode.value
          ..rttControlBlockAddress = config.controlBlockAddress
          ..rttControlBlockRangeStart = config.controlBlockRangeStart
          ..rttControlBlockRangeEnd = config.controlBlockRangeEnd;
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

  @override
  void dispose() {
    _disposed = true;
    _connectionMonitor?.cancel();
    unawaited(_dataSubscription?.cancel());
    unawaited(_diagnosticSubscription?.cancel());
    for (final backend in _backends) {
      unawaited(backend.dispose());
    }
    unawaited(_dataAvailableController.close());
    _connectionOwners.release(ConnectionOwner.rtt);
    super.dispose();
  }
}
