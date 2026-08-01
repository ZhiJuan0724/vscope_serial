import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/models/probe_plot_config.dart';
import '../data/models/probe_connection_config.dart';
import 'elf_symbol_reader.dart';
import 'probe_backend.dart';
import 'rtt_process_backend_base.dart';

/// OpenOCD 后端只使用 RTT 与运行态 read_memory；不得发送 halt/reset/resume。
class ExternalOpenOcdBackend extends TcpProcessProbeBackend
    implements
        ProbeBackendVersionProvider,
        ProbePlotBackend,
        RttChannelMetadataProvider {
  ExternalOpenOcdBackend({
    required this.configuredPath,
    this.bundledRuntime = false,
  });

  final String Function() configuredPath;
  final bool bundledRuntime;
  final StreamController<ProbeSampleChunk> _sampleController =
      StreamController<ProbeSampleChunk>.broadcast();
  int? _tclPort;
  _OpenOcdTclClient? _tclClient;
  // Socket 在停止绘图或断开后端时显式销毁。
  // ignore: close_sinks
  Socket? _plotSocket;
  // 订阅在停止绘图和断开后端时显式取消。
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _plotSubscription;
  int? _plotPort;
  int _activityGeneration = 0;
  Future<void>? _samplingLoop;
  List<RttChannelInfo> _channels = const [];
  final OpenOcdRttLifecycle _rttLifecycle = OpenOcdRttLifecycle();
  Future<void> _transitionTail = Future<void>.value();
  bool _rttConfigured = false;
  bool _viewerServerStarted = false;

  @override
  String get id => bundledRuntime ? 'bundled-openocd' : 'external-openocd';
  @override
  String get displayName => bundledRuntime ? '内置 OpenOCD' : '外置 OpenOCD';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  Duration get startupTimeout => const Duration(seconds: 20);
  @override
  bool get connectRttSocketOnConnect => false;
  @override
  bool get supportsAutomaticControlBlock => false;
  @override
  Stream<ProbeSampleChunk> get sampleStream => _sampleController.stream;
  @override
  Set<ProbeBackendCapability> get capabilities => {
    ...super.capabilities,
    ProbeBackendCapability.memorySampling,
    ProbeBackendCapability.channelMetadata,
  };

  @override
  Future<String?> executablePath(ProbeKind kind) {
    if (kind != ProbeKind.cmsisDap) return Future.value();
    return bundledRuntime
        ? findBundledOpenOcdExecutable()
        : findExternalOpenOcdExecutable(configuredPath());
  }

  @override
  Future<String?> detectVersion(ProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return null;
    final result = await Process.run(executable, const [
      '--version',
    ]).timeout(const Duration(seconds: 3));
    return parseOpenOcdVersion('${result.stdout}\n${result.stderr}');
  }

  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async => [
    ProbeInfo(id: '', name: 'OpenOCD（按接口配置连接）', kind: kind),
  ];

  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) async => const [];

  @override
  Future<List<String>> buildArguments(
    ProbeConnectionConfig config,
    int port,
  ) async {
    final interfaceConfig = config.openOcdInterfaceConfig.trim();
    final targetConfig = config.openOcdTargetConfig.trim();
    if (interfaceConfig.isEmpty || targetConfig.isEmpty) {
      throw const FormatException('OpenOCD 需要接口配置和目标配置');
    }
    _tclPort = await reserveBackendPort();
    return [
      '-f',
      interfaceConfig,
      '-c',
      'transport select ${config.wireProtocol.value}',
      '-f',
      targetConfig,
      '-c',
      'gdb port disabled',
      '-c',
      'telnet port disabled',
      '-c',
      'tcl port $_tclPort',
      '-c',
      'adapter speed ${config.clockKhz}',
      '-c',
      'init',
    ];
  }

  @override
  Future<void> configureRttControlBlock(RttControlBlockConfig config) async {
    if (config.mode == RttControlBlockMode.automatic) {
      throw const FormatException('OpenOCD 不支持 Auto 定位，请选择指定地址或指定范围');
    }
    await super.configureRttControlBlock(config);
    _rttConfigured = false;
    _channels = const [];
  }

  Future<void> _setupRtt() async {
    if (_rttConfigured) return;
    final config = connectionConfig;
    final (address, size) = switch (config.controlBlockMode) {
      RttControlBlockMode.address => (config.controlBlockAddress, 16),
      RttControlBlockMode.range => (
        config.controlBlockRangeStart,
        config.controlBlockRangeStart != null &&
                config.controlBlockRangeEnd != null
            ? config.controlBlockRangeEnd! - config.controlBlockRangeStart!
            : null,
      ),
      RttControlBlockMode.automatic => (null, null),
    };
    if (address == null || address < 0 || size == null || size <= 0) {
      throw const FormatException('OpenOCD RTT 控制块地址或范围无效');
    }
    await (await _tcl()).execute(
      'rtt setup 0x${address.toRadixString(16)} $size "SEGGER RTT"',
    );
    _rttConfigured = true;
  }

  Future<void> _ensureViewerTransport() async {
    await _setupRtt();
    if (!_viewerServerStarted) {
      await (await _tcl()).execute('rtt server start $rttTransportPort 0');
      _viewerServerStarted = true;
    }
    await ensureRttTransportConnected();
  }

  Future<_OpenOcdTclClient> _tcl() async {
    final existing = _tclClient;
    if (existing != null) return existing;
    final port = _tclPort;
    if (!isConnected || port == null) {
      throw StateError('OpenOCD Tcl 控制端口尚未就绪');
    }
    final client = _OpenOcdTclClient(await connectBackendPort(port));
    _tclClient = client;
    return client;
  }

  Future<T> _runTransition<T>(Future<T> Function() operation) {
    final previous = _transitionTail;
    final release = Completer<void>();
    _transitionTail = release.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  @override
  Future<List<RttChannelInfo>> listRttUpChannels() =>
      _runTransition(_listRttUpChannels);

  Future<List<RttChannelInfo>> _listRttUpChannels() async {
    await _setupRtt();
    final tcl = await _tcl();
    return _rttLifecycle.runTemporarily(
      tcl.execute,
      connectionConfig.pollingIntervalMs,
      () async {
        for (var attempt = 0; attempt < 20; attempt++) {
          final response = await tcl.execute('capture "rtt channels"');
          final channels = parseOpenOcdRttChannels(response);
          if (channels.isNotEmpty) {
            _channels = channels;
            return _channels;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        _channels = const [];
        return _channels;
      },
    );
  }

  @override
  Future<void> startRttViewer() => _runTransition(_startRttViewer);

  Future<void> _startRttViewer() async {
    await _stopProbeActivity();
    await _ensureViewerTransport();
    await _rttLifecycle.start(
      (await _tcl()).execute,
      connectionConfig.pollingIntervalMs,
    );
  }

  @override
  Future<void> startRttPlot(String channelName) =>
      _runTransition(() => _startRttPlot(channelName));

  Future<void> _startRttPlot(String channelName) async {
    await _stopProbeActivity();
    await _setupRtt();
    await _rttLifecycle.stop((await _tcl()).execute);
    final channels = _channels.isEmpty ? await _listRttUpChannels() : _channels;
    final requested = channelName.trim();
    RttChannelInfo? channel;
    for (final candidate in channels) {
      if (candidate.name == requested) {
        channel = candidate;
        break;
      }
    }
    if (channel == null) {
      throw StateError('RTT Up 通道不存在：$requested');
    }
    final selectedChannel = channel;
    if (selectedChannel.index == 0) {
      await _ensureViewerTransport();
      await _rttLifecycle.start(
        (await _tcl()).execute,
        connectionConfig.pollingIntervalMs,
      );
      return;
    }

    final tcl = await _tcl();
    final port = await reserveBackendPort();
    await tcl.execute('rtt server start $port ${selectedChannel.index}');
    try {
      // Socket 的所有权立即转交给 _plotSocket，并在停止活动时销毁。
      // ignore: close_sinks
      final socket = await connectBackendPort(port);
      _plotPort = port;
      _plotSocket = socket;
      _plotSubscription = socket.listen(
        (bytes) =>
            emitRttData(selectedChannel.index, Uint8List.fromList(bytes)),
        onError: (Object error) {
          emitBackendDiagnostic('OpenOCD RTT 绘图通道读取失败：$error');
          if (identical(_plotSocket, socket)) {
            _plotSocket = null;
            _plotSubscription = null;
          }
        },
        onDone: () {
          if (identical(_plotSocket, socket)) {
            _plotSocket = null;
            _plotSubscription = null;
          }
        },
        cancelOnError: true,
      );
      await _rttLifecycle.start(
        tcl.execute,
        connectionConfig.pollingIntervalMs,
      );
    } catch (_) {
      await _rttLifecycle.stop(tcl.execute);
      await tcl.execute('rtt server stop $port');
      rethrow;
    }
  }

  @override
  Future<List<ProbeSymbolInfo>> readSymbols(String path) =>
      readElfDataSymbols(path);

  @override
  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) => _runTransition(() => _startHss(variables, frequencyHz: frequencyHz));

  Future<void> _startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) async {
    if (variables.isEmpty || variables.length > 12) {
      throw const FormatException('HSS 必须配置 1～12 个变量');
    }
    await _stopProbeActivity();
    final tcl = await _tcl();
    await _rttLifecycle.stop(tcl.execute);
    final generation = ++_activityGeneration;
    final period = Duration(
      microseconds: (1000000 / frequencyHz.clamp(1, 5000)).round(),
    );
    final first = await _readHssSample(tcl, variables);
    _sampleController.add(first);
    _samplingLoop = _runHssLoop(tcl, variables, period, generation);
  }

  Future<void> _runHssLoop(
    _OpenOcdTclClient tcl,
    List<ProbeSampleVariable> variables,
    Duration period,
    int generation,
  ) async {
    while (generation == _activityGeneration && isConnected) {
      final started = Stopwatch()..start();
      try {
        _sampleController.add(await _readHssSample(tcl, variables));
      } catch (error) {
        if (generation == _activityGeneration) {
          emitBackendDiagnostic('OpenOCD HSS 运行态内存读取失败：$error');
          _activityGeneration++;
        }
        return;
      }
      final remaining = period - started.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
  }

  Future<ProbeSampleChunk> _readHssSample(
    _OpenOcdTclClient tcl,
    List<ProbeSampleVariable> variables,
  ) async {
    final command = StringBuffer('set _vscope_hss {};');
    for (final variable in variables) {
      command.write(
        'lappend _vscope_hss {*}[read_memory '
        '0x${variable.address.toRadixString(16)} 8 ${variable.type.byteSize}];',
      );
    }
    command.write('set _vscope_hss');
    final raw = await tcl.execute(command.toString());
    final tokens =
        RegExp(
          r'(?:0x)?[0-9a-fA-F]+',
        ).allMatches(raw).map((match) => match.group(0)!).toList();
    final expected = variables.fold<int>(
      0,
      (total, variable) => total + variable.type.byteSize,
    );
    if (tokens.length != expected) {
      throw FormatException('内存读取返回 ${tokens.length} 字节，预期 $expected 字节');
    }
    var cursor = 0;
    final values = Float64List(variables.length);
    for (var index = 0; index < variables.length; index++) {
      final variable = variables[index];
      final bytes = Uint8List(variable.type.byteSize);
      for (var offset = 0; offset < bytes.length; offset++) {
        bytes[offset] = _parseOpenOcdInteger(tokens[cursor++]) & 0xff;
      }
      values[index] = _decodeProbeScalar(bytes, variable.type);
    }
    return ProbeSampleChunk(monotonicUs: monotonicMicroseconds, values: values);
  }

  @override
  Future<void> stopActivity() => _runTransition(_stopActivity);

  Future<void> _stopActivity() async {
    await _stopProbeActivity();
    if (isConnected) {
      await _rttLifecycle.stop((await _tcl()).execute);
      await closeRttTransport();
      if (_viewerServerStarted) {
        try {
          await (await _tcl()).execute('rtt server stop $rttTransportPort');
        } finally {
          _viewerServerStarted = false;
        }
      }
    } else {
      _rttLifecycle.reset();
    }
  }

  Future<void> _stopProbeActivity() async {
    _activityGeneration++;
    final loop = _samplingLoop;
    _samplingLoop = null;
    await loop;
    final subscription = _plotSubscription;
    _plotSubscription = null;
    await subscription?.cancel();
    final socket = _plotSocket;
    _plotSocket = null;
    socket?.destroy();
    final port = _plotPort;
    _plotPort = null;
    if (port != null && isConnected) {
      try {
        await (await _tcl()).execute('rtt server stop $port');
      } catch (_) {
        // 断开过程中 OpenOCD 可能已关闭；无需影响主连接清理。
      }
    }
  }

  @override
  Future<void> disconnect() => _runTransition(() async {
    await _stopProbeActivity();
    if (isConnected && _tclClient != null) {
      try {
        await _rttLifecycle.stop(_tclClient!.execute);
      } catch (_) {
        // 外部进程可能已退出；断开清理不能被 RTT stop 失败阻塞。
      }
    }
    _rttLifecycle.reset();
    _rttConfigured = false;
    _viewerServerStarted = false;
    final tcl = _tclClient;
    _tclClient = null;
    await tcl?.close();
    _tclPort = null;
    _channels = const [];
    await super.disconnect();
  });

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _sampleController.close();
  }

  @override
  String? parseFailureDiagnostic(String line) {
    final clean = stripRttAnsi(line).trim();
    final lower = clean.toLowerCase();
    if ((lower.contains('unable to find') &&
            (lower.contains('cmsis-dap') || lower.contains('adapter'))) ||
        lower.contains('no device found')) {
      return 'OpenOCD 未检测到调试探针，请检查 USB、驱动和接口配置';
    }
    if (lower.contains('target examination failed') ||
        lower.contains('jtag scan chain interrogation failed') ||
        lower.contains('init mode failed')) {
      return 'OpenOCD 无法连接目标芯片，请检查目标配置、供电、接线和调试时钟';
    }
    if (lower.startsWith('error:')) return 'OpenOCD：$clean';
    return null;
  }

  @override
  String? parseFatalDisconnectDiagnostic(String line) {
    final lower = stripRttAnsi(line).trim().toLowerCase();
    if (lower.contains('error submitting usb write') ||
        lower.contains('error submitting usb read') ||
        lower.contains('libusb_error_no_device') ||
        (lower.contains('usb bulk') && lower.contains('failed')) ||
        (lower.contains('usb') && lower.contains('input/output error'))) {
      return 'OpenOCD 调试探针的 USB 连接已中断，请重新插入探针后再连接';
    }
    return null;
  }

  @override
  bool isRealtimeDataDiagnostic(String line) => isOpenOcdRealtimeDataLine(line);
}

/// OpenOCD RTT 轮询生命周期。
///
/// 连接阶段只创建 TCP 服务，不启动目标内存轮询；Viewer/RTT 绘图显式启动，
/// HSS 和空闲连接显式停止。通道枚举可短暂借用 RTT，并恢复借用前状态。
class OpenOcdRttLifecycle {
  bool _started = false;

  bool get isStarted => _started;

  Future<void> start(
    Future<String> Function(String) execute,
    int pollingIntervalMs,
  ) async {
    if (_started) return;
    await execute('rtt polling_interval $pollingIntervalMs');
    await execute('rtt start');
    _started = true;
  }

  Future<void> stop(Future<String> Function(String) execute) async {
    if (!_started) return;
    await execute('rtt stop');
    _started = false;
  }

  Future<T> runTemporarily<T>(
    Future<String> Function(String) execute,
    int pollingIntervalMs,
    Future<T> Function() operation,
  ) async {
    final wasStarted = _started;
    if (!wasStarted) await start(execute, pollingIntervalMs);
    try {
      return await operation();
    } finally {
      if (!wasStarted) await stop(execute);
    }
  }

  void reset() => _started = false;
}

bool isOpenOcdRealtimeDataLine(String line) =>
    RegExp(r'^(?:0x[0-9a-fA-F]+\s*)+$').hasMatch(stripRttAnsi(line).trim());

List<RttChannelInfo> parseOpenOcdRttChannels(String output) {
  final channels = <RttChannelInfo>[];
  var inUpChannels = false;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line == 'Up-channels:') {
      inUpChannels = true;
      continue;
    }
    if (line == 'Down-channels:') break;
    if (!inUpChannels) continue;
    final match = RegExp(r'^(\d+):\s+(.*?)\s+(\d+)\s+(\d+)$').firstMatch(line);
    if (match == null) continue;
    channels.add(
      RttChannelInfo(
        index: int.parse(match.group(1)!),
        name: match.group(2)!.trim(),
        size: int.parse(match.group(3)!),
        flags: int.parse(match.group(4)!),
      ),
    );
  }
  return channels;
}

String? parseOpenOcdVersion(String output) {
  final match = RegExp(
    r'Open On-Chip Debugger\s+(\d+(?:\.\d+)+(?:[-+][^\s]+)?)',
    caseSensitive: false,
  ).firstMatch(output);
  return match == null ? null : 'v${match.group(1)}';
}

Future<String?> findOpenOcdConfigDirectory(
  String configuredPath,
  String category,
) async {
  final executable = await findOpenOcdExecutable(configuredPath);
  return _findOpenOcdConfigDirectoryForExecutable(executable, category);
}

Future<String?> findBundledOpenOcdConfigDirectory(String category) async {
  final executable = await findBundledOpenOcdExecutable();
  return _findOpenOcdConfigDirectoryForExecutable(executable, category);
}

Future<String?> findExternalOpenOcdConfigDirectory(
  String configuredPath,
  String category,
) async {
  final executable = await findExternalOpenOcdExecutable(configuredPath);
  return _findOpenOcdConfigDirectoryForExecutable(executable, category);
}

Future<String?> _findOpenOcdConfigDirectoryForExecutable(
  String? executable,
  String category,
) async {
  if (category != 'interface' && category != 'target') {
    throw ArgumentError.value(category, 'category', '仅支持 interface 或 target');
  }
  if (executable == null) return null;
  final executableDirectory = File(executable).parent;
  final installationRoot = executableDirectory.parent;
  final scriptsEnvironment = Platform.environment['OPENOCD_SCRIPTS']?.trim();
  final scriptRoots = [
    if (scriptsEnvironment != null && scriptsEnvironment.isNotEmpty)
      Directory(scriptsEnvironment),
    Directory(
      '${installationRoot.path}${Platform.pathSeparator}share'
      '${Platform.pathSeparator}openocd${Platform.pathSeparator}scripts',
    ),
    Directory(
      '${installationRoot.path}${Platform.pathSeparator}openocd'
      '${Platform.pathSeparator}scripts',
    ),
    Directory('${installationRoot.path}${Platform.pathSeparator}scripts'),
    Directory('${executableDirectory.path}${Platform.pathSeparator}scripts'),
  ];
  for (final scriptsRoot in scriptRoots) {
    final directory = Directory(
      '${scriptsRoot.path}${Platform.pathSeparator}$category',
    );
    if (await directory.exists()) return directory.absolute.path;
  }
  return null;
}

Future<String?> findOpenOcdExecutable(String configuredPath) async {
  return await findExternalOpenOcdExecutable(configuredPath) ??
      await findBundledOpenOcdExecutable();
}

Future<String?> findBundledOpenOcdExecutable() async {
  final separator = Platform.pathSeparator;
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  for (final candidate in [
    '$executableDirectory${separator}runtime${separator}openocd'
        '${separator}bin${separator}openocd.exe',
    'build${separator}windows${separator}x64${separator}runner'
        '${separator}Release${separator}runtime${separator}openocd'
        '${separator}bin${separator}openocd.exe',
    'build${separator}tool_cache${separator}openocd'
        '${separator}xpack-openocd-0.12.0-7${separator}bin'
        '${separator}openocd.exe',
  ]) {
    if (await File(candidate).exists()) return File(candidate).absolute.path;
  }
  return null;
}

Future<String?> findExternalOpenOcdExecutable(String configuredPath) async {
  return findRttExecutable(configuredPath, 'openocd.exe');
}

double _decodeProbeScalar(Uint8List bytes, ProbeScalarType type) {
  final data = ByteData.sublistView(bytes);
  return switch (type) {
    ProbeScalarType.boolean => bytes[0] == 0 ? 0 : 1,
    ProbeScalarType.int8 => data.getInt8(0).toDouble(),
    ProbeScalarType.int16 => data.getInt16(0, Endian.little).toDouble(),
    ProbeScalarType.int32 => data.getInt32(0, Endian.little).toDouble(),
    ProbeScalarType.int64 => data.getInt64(0, Endian.little).toDouble(),
    ProbeScalarType.uint8 => data.getUint8(0).toDouble(),
    ProbeScalarType.uint16 => data.getUint16(0, Endian.little).toDouble(),
    ProbeScalarType.uint32 => data.getUint32(0, Endian.little).toDouble(),
    ProbeScalarType.uint64 => data.getUint64(0, Endian.little).toDouble(),
    ProbeScalarType.float32 => data.getFloat32(0, Endian.little).toDouble(),
    ProbeScalarType.float64 => data.getFloat64(0, Endian.little),
  };
}

int _parseOpenOcdInteger(String token) {
  final normalized = token.toLowerCase();
  return int.parse(
    normalized.startsWith('0x') ? normalized.substring(2) : normalized,
    radix:
        normalized.startsWith('0x') || RegExp(r'[a-f]').hasMatch(normalized)
            ? 16
            : 10,
  );
}

class _OpenOcdTclClient {
  _OpenOcdTclClient(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error, StackTrace stackTrace) {
        _pending?.completeError(error, stackTrace);
        _pending = null;
      },
      onDone: () {
        _pending?.completeError(StateError('OpenOCD Tcl 控制端口已关闭'));
        _pending = null;
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  Completer<String>? _pending;
  Future<void> _requestTail = Future.value();

  Future<String> execute(String command) async {
    final previous = _requestTail;
    final release = Completer<void>();
    _requestTail = release.future;
    await previous;
    try {
      if (_pending != null) throw StateError('OpenOCD Tcl 命令发生重入');
      final response = Completer<String>();
      _pending = response;
      _socket.add([...utf8.encode(command), 0x1a]);
      await _socket.flush();
      return await response.future.timeout(const Duration(seconds: 5));
    } finally {
      _pending = null;
      release.complete();
    }
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    final terminator = _buffer.indexOf(0x1a);
    if (terminator < 0) return;
    final payload = Uint8List.fromList(_buffer.sublist(0, terminator));
    _buffer.removeRange(0, terminator + 1);
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(utf8.decode(payload, allowMalformed: true).trim());
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
