import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/probe_connection_config.dart';
import 'probe_backend.dart';

/// 管理外部调试工具进程，并从其 RTT TCP 端口读取 Up 0。
abstract class TcpProcessProbeBackend
    implements
        ProbeBackend,
        ProbeBackendFailureProvider,
        RttActivityBackend,
        RttControlBlockConfigurable {
  static final Stopwatch _monotonicClock = Stopwatch()..start();

  final StreamController<RttDataChunk> _dataController =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnosticController =
      StreamController<String>.broadcast();
  Process? _process;
  Socket? _socket;
  // 订阅在停止活动和断开后端时显式取消。
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _socketSubscription;
  Future<void>? _diagnosticForwarding;
  bool _connected = false;
  bool _disconnecting = false;
  Completer<void>? _transportClosed;
  String? _lastFailure;
  String? _lastDiagnostic;
  int _realtimeDiagnosticCount = 0;
  DateTime? _lastRealtimeDiagnosticLogAt;
  bool _fatalDisconnectHandled = false;
  ProbeConnectionConfig? _connectionConfig;
  int? _rttPort;

  @override
  Stream<RttDataChunk> get dataStream => _dataController.stream;
  @override
  Stream<String> get diagnosticStream => _diagnosticController.stream;
  @override
  bool get isConnected => _connected;
  @override
  String? get lastFailure => _lastFailure;
  bool get supportsDownChannel0 => true;
  bool get connectRttSocketOnConnect => true;
  @override
  bool get supportsAutomaticControlBlock => true;
  ProbeConnectionConfig get connectionConfig =>
      _connectionConfig ?? (throw StateError('$displayName 尚未保存连接参数'));
  int get rttTransportPort =>
      _rttPort ?? (throw StateError('$displayName 尚未分配 RTT 端口'));

  @override
  Set<ProbeBackendCapability> get capabilities => {
    ProbeBackendCapability.independentActivity,
    if (supportsDownChannel0) ProbeBackendCapability.downChannel0,
  };

  Duration get startupStabilityDuration => const Duration(milliseconds: 800);
  Duration get startupTimeout => const Duration(seconds: 12);

  Future<String?> executablePath(ProbeKind kind);
  Future<List<String>> buildArguments(ProbeConnectionConfig config, int port);

  Future<void> configureRttSocket(
    Socket socket,
    ProbeConnectionConfig config,
  ) async {}

  Uint8List filterRttData(Uint8List data) => data;
  void resetRttDataFilter() {}
  String? parseFailureDiagnostic(String line) => null;
  String? parseFatalDisconnectDiagnostic(String line) => null;
  void onDiagnosticLine(String line) {}
  bool isRealtimeDataDiagnostic(String line) => false;

  /// 子后端附加 RTT 通道或 Tcl 控制连接时复用当前进程的就绪检测。
  Future<Socket> connectBackendPort(int port) async {
    final process = _process;
    if (process == null) throw StateError('$displayName 后台进程未运行');
    return _connectWithRetry(port, process);
  }

  Future<int> reserveBackendPort() => reserveRttTcpPort();

  void emitRttData(int channel, Uint8List bytes) {
    if (bytes.isEmpty || _dataController.isClosed) return;
    _dataController.add(
      RttDataChunk(
        channel: channel,
        data: bytes,
        monotonicUs: _monotonicClock.elapsedMicroseconds,
        wallClockUs: DateTime.now().microsecondsSinceEpoch,
      ),
    );
  }

  void emitBackendDiagnostic(String message) {
    if (!_diagnosticController.isClosed) _diagnosticController.add(message);
    AppLogger().warning(message, category: 'RTT');
  }

  int get monotonicMicroseconds => _monotonicClock.elapsedMicroseconds;

  @override
  Future<bool> isAvailable(ProbeKind kind) async =>
      await executablePath(kind) != null;

  @override
  Future<void> connect(ProbeConnectionConfig config) async {
    await disconnect();
    _lastFailure = null;
    _lastDiagnostic = null;
    _realtimeDiagnosticCount = 0;
    _lastRealtimeDiagnosticLogAt = null;
    _fatalDisconnectHandled = false;
    _disconnecting = false;
    resetRttDataFilter();
    _connectionConfig = config;
    final executable = await executablePath(config.probeKind);
    if (executable == null) {
      throw ProbeBackendUnavailableException('$displayName 未安装或路径无效');
    }
    final port = await reserveRttTcpPort();
    _rttPort = port;
    final arguments = await buildArguments(config, port);
    final launchMessage = '启动 $displayName: $executable ${arguments.join(' ')}';
    AppLogger().info(launchMessage, category: 'RTT');
    emitBackendDiagnostic(launchMessage);
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    final diagnosticForwarding = Future.wait<void>([
      _forwardDiagnostics(process.stdout),
      _forwardDiagnostics(process.stderr),
    ]);
    _diagnosticForwarding = diagnosticForwarding;
    unawaited(diagnosticForwarding);
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          if (!_fatalDisconnectHandled) {
            final message = '$displayName 已退出，代码 $code';
            AppLogger().warning(message, category: 'RTT');
            emitBackendDiagnostic(message);
            if (!_disconnecting) {
              _lastFailure ??=
                  _lastDiagnostic == null
                      ? message
                      : '$message：$_lastDiagnostic';
            }
          }
          _markDisconnected();
        }
      }),
    );

    try {
      if (connectRttSocketOnConnect) {
        await ensureRttTransportConnected();
      } else {
        await _awaitProcessStability(process);
        _connected = true;
      }
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<void> _awaitProcessStability(Process process) async {
    await Future<void>.delayed(startupStabilityDuration);
    _throwIfStartupFailed();
    if (!identical(_process, process) || await _hasExited(process)) {
      await _diagnosticForwarding;
      _throwIfStartupFailed();
      throw StateError('$displayName 在连接确认前退出');
    }
  }

  Future<void> ensureRttTransportConnected() async {
    if (_socket != null) return;
    final process = _process;
    if (process == null) throw StateError('$displayName 后台进程未运行');
    final socket = await _connectWithRetry(rttTransportPort, process);
    final transportClosed = Completer<void>();
    _transportClosed = transportClosed;
    try {
      await configureRttSocket(socket, connectionConfig);
    } catch (_) {
      await socket.close();
      _transportClosed = null;
      rethrow;
    }
    _socket = socket;
    _socketSubscription = socket.listen(
      (bytes) {
        final filtered = filterRttData(Uint8List.fromList(bytes));
        emitRttData(0, filtered);
      },
      onError: (Object error, StackTrace stackTrace) {
        final message = '$displayName RTT 读取失败: $error';
        AppLogger().error(
          message,
          category: 'RTT',
          error: error,
          stackTrace: stackTrace,
        );
        emitBackendDiagnostic(message);
        if (!_disconnecting) _lastFailure = message;
        _markDisconnected();
      },
      onDone: () {
        if (!_disconnecting) {
          _lastFailure ??= '$displayName 未能保持 RTT 连接，请检查目标板连接和供电';
        }
        _markDisconnected();
      },
      cancelOnError: true,
    );
    if (!_connected) {
      try {
        await transportClosed.future.timeout(startupStabilityDuration);
        throw StateError(_lastFailure ?? '$displayName 在连接确认前关闭了 RTT 通道');
      } on TimeoutException {
        if (!identical(_process, process) || _socket == null) {
          throw StateError(_lastFailure ?? '$displayName RTT 通道已关闭');
        }
        if (_lastFailure != null) throw StateError(_lastFailure!);
        _transportClosed = null;
        _connected = true;
      }
    }
  }

  Future<void> closeRttTransport() async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    _transportClosed = null;
    await socket?.close();
  }

  @override
  Future<void> configureRttControlBlock(RttControlBlockConfig config) async {
    _connectionConfig = connectionConfig.copyWithControlBlock(config);
  }

  @override
  Future<void> startRttViewer() async {
    if (!isConnected) throw StateError('$displayName 尚未连接');
    await ensureRttTransportConnected();
  }

  @override
  Future<void> stopActivity() async {}

  @override
  Future<void> writeDownChannel0(Uint8List data) async {
    if (!supportsDownChannel0) {
      throw StateError('$displayName 当前模式不支持 RTT Down 0');
    }
    final socket = _socket;
    if (!_connected || socket == null) throw StateError('$displayName 尚未连接');
    socket.add(data);
    await socket.flush();
  }

  Future<void> _forwardDiagnostics(Stream<List<int>> stream) async {
    await for (final line in stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final message = stripRttAnsi(line).trim();
      if (message.isEmpty) continue;
      if (_fatalDisconnectHandled) continue;
      if (isRealtimeDataDiagnostic(message)) {
        _recordRealtimeDiagnostic(message);
        continue;
      }
      final fatalFailure = parseFatalDisconnectDiagnostic(message);
      if (fatalFailure != null && !_disconnecting) {
        _fatalDisconnectHandled = true;
        _lastDiagnostic = message;
        _lastFailure = fatalFailure;
        AppLogger().warning('$fatalFailure（原始信息：$message）', category: 'RTT');
        emitBackendDiagnostic(fatalFailure);
        _markDisconnected();
        _process?.kill();
        continue;
      }
      _lastDiagnostic = message;
      AppLogger().info('$displayName: $message', category: 'RTT');
      emitBackendDiagnostic(message);
      onDiagnosticLine(message);
      final failure = parseFailureDiagnostic(message);
      if (failure != null && !_disconnecting) {
        _lastFailure = failure;
        AppLogger().warning(failure, category: 'RTT');
      }
    }
  }

  void _recordRealtimeDiagnostic(String message) {
    if (!AppLogger().diagnosticEnabled) return;
    _realtimeDiagnosticCount++;
    final now = DateTime.now();
    final last = _lastRealtimeDiagnosticLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    AppLogger().debug(
      '$displayName: 高频实时输出 $_realtimeDiagnosticCount 行'
      '（最近：$message）',
      category: 'RTT',
    );
    _realtimeDiagnosticCount = 0;
    _lastRealtimeDiagnosticLogAt = now;
  }

  Future<Socket> _connectWithRetry(int port, Process process) async {
    final deadline = DateTime.now().add(startupTimeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      _throwIfStartupFailed();
      if (await _hasExited(process)) {
        // 进程退出和 stdout/stderr 的最后一行到达顺序不固定。先消费完
        // 诊断流，确保“未插探针”等明确原因不会退化成笼统退出提示。
        await _diagnosticForwarding;
        _throwIfStartupFailed();
        throw StateError('$displayName 在 TCP 服务就绪前退出');
      }
      try {
        return await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 400),
        );
      } catch (error) {
        lastError = error;
        _throwIfStartupFailed();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        _throwIfStartupFailed();
      }
    }
    _throwIfStartupFailed();
    throw TimeoutException('等待 $displayName TCP 服务超时: $lastError');
  }

  void _throwIfStartupFailed() {
    final failure = _lastFailure;
    if (failure != null) throw StateError(failure);
  }

  Future<bool> _hasExited(Process process) async {
    try {
      await process.exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _markDisconnected() {
    _connected = false;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    unawaited(subscription?.cancel());
    final transportClosed = _transportClosed;
    _transportClosed = null;
    if (transportClosed != null && !transportClosed.isCompleted) {
      transportClosed.complete();
    }
    _socket?.destroy();
    _socket = null;
  }

  @override
  Future<void> disconnect() async {
    _disconnecting = true;
    _connected = false;
    final diagnosticForwarding = _diagnosticForwarding;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
    // 进程退出不代表 stdout/stderr 的管道尾部已被 Dart 消费完。
    // 在 dispose 关闭广播控制器前等待转发循环收尾，避免尾行输出
    // 写入已关闭控制器。超时时仍由 isClosed 防护保证安全退出。
    if (diagnosticForwarding != null) {
      try {
        await diagnosticForwarding.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        // 某些外部工具的管道关闭通知可能延迟，不阻塞断开流程。
      }
    }
    _diagnosticForwarding = null;
    _transportClosed = null;
    _rttPort = null;
    _disconnecting = false;
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
    await _diagnosticController.close();
  }
}

String stripRttAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

Future<int> reserveRttTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<String?> findRttExecutable(
  String configuredPath,
  String name, {
  List<String> extraDirectories = const [],
}) async {
  final configured = configuredPath.trim();
  if (configured.isNotEmpty && await File(configured).exists()) {
    return File(configured).absolute.path;
  }
  final pathParts = <String>[
    ...?Platform.environment['PATH']?.split(';'),
    ...extraDirectories,
  ];
  for (final rawDirectory in pathParts) {
    final directory = Directory(rawDirectory.trim());
    if (!await directory.exists()) continue;
    final direct = File('${directory.path}${Platform.pathSeparator}$name');
    if (await direct.exists()) return direct.absolute.path;
    if (extraDirectories.contains(rawDirectory)) {
      final matches = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is Directory) {
          final candidate = File(
            '${entity.path}${Platform.pathSeparator}$name',
          );
          if (await candidate.exists()) matches.add(candidate);
        }
      }
      if (matches.isNotEmpty) {
        matches.sort((a, b) => b.path.compareTo(a.path));
        return matches.first.absolute.path;
      }
    }
  }
  return null;
}
