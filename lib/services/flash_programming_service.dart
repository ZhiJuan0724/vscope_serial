import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models/flash_programming_models.dart';
import 'connection_owner_service.dart';
import 'flash_programming_backend.dart';
import 'jlink_programming_backend.dart';
import 'openocd_programming_backend.dart';

typedef FlashBackendBuilder =
    FlashProgrammingBackend Function(ProgrammingBackendSelection selection);

/// Flash页面唯一的高权限会话门面。
///
/// 服务先取得`ConnectionOwner.programming`，再建立完全独立的工具进程。
/// 自动选择只发生在连接前；连接成功后所有操作都固定使用同一个后端。
class FlashProgrammingService extends ChangeNotifier {
  FlashProgrammingService({
    ConnectionOwnerService? owners,
    FlashBackendBuilder? backendBuilder,
  }) : _owners = owners ?? ConnectionOwnerService(),
       _backendBuilder = backendBuilder ?? _defaultBackendBuilder;

  final ConnectionOwnerService _owners;
  final FlashBackendBuilder _backendBuilder;
  final List<String> _outputLines = [];
  FlashProgrammingBackend? _backend;
  StreamSubscription<String>? _outputSubscription;
  FlashConnectionConfig? _config;
  FlashOperationState _state = FlashOperationState.disconnected;
  double _progress = 0;
  String _stage = '';
  Object? _lastError;
  int _operationGeneration = 0;

  FlashOperationState get state => _state;
  bool get isConnected => _backend?.isConnected ?? false;
  bool get isConnecting => _state == FlashOperationState.connecting;
  bool get isBusy => switch (_state) {
    FlashOperationState.connecting ||
    FlashOperationState.erasing ||
    FlashOperationState.programming ||
    FlashOperationState.verifying ||
    FlashOperationState.reading ||
    FlashOperationState.disconnecting => true,
    _ => false,
  };
  bool get hasSession => _backend != null;
  ProgrammingBackendSelection? get activeBackend => _backend?.selection;
  String? get activeBackendName => _backend?.displayName;
  FlashConnectionConfig? get config => _config;
  double get progress => _progress;
  String get stage => _stage;
  Object? get lastError => _lastError;
  List<String> get outputLines => List.unmodifiable(_outputLines);

  static FlashProgrammingBackend _defaultBackendBuilder(
    ProgrammingBackendSelection selection,
  ) => switch (selection) {
    ProgrammingBackendSelection.externalJlink => JLinkProgrammingBackend(),
    ProgrammingBackendSelection.externalOpenocd => OpenOcdProgrammingBackend(
      bundled: false,
    ),
    ProgrammingBackendSelection.bundledOpenocd => OpenOcdProgrammingBackend(
      bundled: true,
    ),
    ProgrammingBackendSelection.automatic =>
      throw ArgumentError('自动选择不是具体Flash后端'),
  };

  List<ProgrammingBackendSelection> _candidates(FlashConnectionConfig config) {
    if (config.backend != ProgrammingBackendSelection.automatic) {
      return [config.backend];
    }
    return switch (config.probeKind) {
      FlashProbeKind.jlink => [ProgrammingBackendSelection.externalJlink],
      FlashProbeKind.cmsisDap => [
        ProgrammingBackendSelection.externalOpenocd,
        ProgrammingBackendSelection.bundledOpenocd,
      ],
    };
  }

  /// 仅检查编程工具和配置是否可用，不建立目标连接。
  ///
  /// Flash连接窗口复用探针连接表单时通过此入口显示预计后端；实际连接
  /// 仍由本服务创建独立高权限后端，不复用RTT监控后端实例。
  Future<String> expectedBackendName(FlashConnectionConfig config) async {
    for (final selection in _candidates(config)) {
      final backend = _backendBuilder(selection);
      if (await backend.isToolAvailable(config)) return backend.displayName;
    }
    throw StateError('没有检测到可用的Flash编程工具');
  }

  Future<void> connect(FlashConnectionConfig config) async {
    if (_backend != null || isConnecting) return;
    if (!_owners.tryAcquire(ConnectionOwner.programming)) {
      throw StateError('请先断开数据连接和探针连接');
    }
    _state = FlashOperationState.connecting;
    _lastError = null;
    _config = config;
    _stage = '检查编程工具';
    final generation = ++_operationGeneration;
    notifyListeners();
    FlashProgrammingBackend? candidate;
    try {
      for (final selection in _candidates(config)) {
        final backend = _backendBuilder(selection);
        if (await backend.isAvailable(config)) {
          candidate = backend;
          break;
        }
      }
      if (candidate == null) {
        throw StateError('没有可用且配置完整的Flash编程后端');
      }
      _backend = candidate;
      _outputSubscription = candidate.output.listen(_appendOutput);
      _stage = '连接${candidate.displayName}';
      notifyListeners();
      // 选定候选后连接失败不再切换后端，避免掩盖目标或占用错误。
      await candidate.connect(config);
      if (generation != _operationGeneration) {
        await candidate.forceTerminate();
        return;
      }
      _state = FlashOperationState.connected;
      _stage = '已连接 ${candidate.displayName}';
    } catch (error) {
      if (generation == _operationGeneration) {
        _lastError = error;
        _state = FlashOperationState.disconnected;
      }
      await _outputSubscription?.cancel();
      _outputSubscription = null;
      await candidate?.forceTerminate();
      _backend = null;
      _owners.release(ConnectionOwner.programming);
      if (generation == _operationGeneration) rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _appendOutput(String value) {
    for (final line in value.replaceAll('\r\n', '\n').split('\n')) {
      if (line.isNotEmpty) _outputLines.add(line);
    }
    if (_outputLines.length > 3000) {
      _outputLines.removeRange(0, _outputLines.length - 3000);
    }
    notifyListeners();
  }

  void clearOutput() {
    _outputLines.clear();
    notifyListeners();
  }

  Future<void> program(FlashProgramRequest request) => _runOperation(
    FlashOperationState.programming,
    (backend) => backend.program(request, _updateProgress),
  );

  Future<void> erase(FlashEraseRequest request) => _runOperation(
    FlashOperationState.erasing,
    (backend) => backend.erase(request, _updateProgress),
  );

  Future<void> read(FlashReadRequest request) => _runOperation(
    FlashOperationState.reading,
    (backend) => backend.read(request, _updateProgress),
  );

  /// 读取结果先由既有后端写入临时BIN，再加载到内存交给HEX查看器。
  /// 临时文件仅是外部工具的交换介质，不向用户暴露，也不会作为读取操作的保存结果。
  Future<Uint8List> readBytes({
    required int address,
    required int length,
  }) async {
    final separator = Platform.pathSeparator;
    final path =
        '${Directory.systemTemp.path}${Directory.systemTemp.path.endsWith(separator) ? '' : separator}'
        'vscope_flash_${DateTime.now().microsecondsSinceEpoch}.bin';
    final file = File(path);
    try {
      await read(
        FlashReadRequest(address: address, length: length, outputPath: path),
      );
      return await file.readAsBytes();
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 临时文件清理失败不覆盖已经完成的读取结果或原始后端错误。
      }
    }
  }

  Future<void> _runOperation(
    FlashOperationState operation,
    Future<void> Function(FlashProgrammingBackend backend) action,
  ) async {
    final backend = _backend;
    if (backend == null || !backend.isConnected) {
      throw StateError('Flash编程会话未连接');
    }
    if (isBusy) throw StateError('已有Flash操作正在进行');
    _state = operation;
    final generation = ++_operationGeneration;
    _progress = 0;
    _lastError = null;
    notifyListeners();
    try {
      await action(backend);
      if (generation == _operationGeneration) {
        _state = FlashOperationState.connected;
      }
    } catch (error) {
      if (generation != _operationGeneration) return;
      _lastError = error;
      _state =
          backend.isConnected
              ? FlashOperationState.connected
              : FlashOperationState.unknown;
      if (!backend.isConnected) {
        await _dropBackend(releaseOwner: true);
      }
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void _updateProgress(double value, String stage) {
    _progress = value.clamp(0, 1);
    _stage = stage;
    notifyListeners();
  }

  Future<void> disconnect() async {
    if (isBusy) throw StateError('Flash操作期间不能普通断开');
    final backend = _backend;
    _operationGeneration++;
    if (backend == null) return;
    _state = FlashOperationState.disconnecting;
    _stage = '断开编程会话';
    notifyListeners();
    try {
      await backend.disconnect();
      await _dropBackend(releaseOwner: true);
      _state = FlashOperationState.disconnected;
      _stage = '';
    } catch (error) {
      _lastError = error;
      _state = FlashOperationState.unknown;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// 用户二次确认后的紧急终止：不发送reset/resume等补救命令。
  Future<void> forceTerminate() async {
    final backend = _backend;
    _operationGeneration++;
    _state = FlashOperationState.unknown;
    _stage = '强制终止，目标状态未知';
    notifyListeners();
    await backend?.forceTerminate();
    await _dropBackend(releaseOwner: true);
    notifyListeners();
  }

  Future<void> _dropBackend({required bool releaseOwner}) async {
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    _backend = null;
    if (releaseOwner) _owners.release(ConnectionOwner.programming);
  }

  Future<void> shutdown() async {
    if (isBusy) return;
    try {
      await disconnect();
    } catch (_) {
      await forceTerminate();
    }
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
