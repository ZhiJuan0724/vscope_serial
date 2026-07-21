import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/rtt_config.dart';
import 'rtt_backend.dart';
import 'windows_file_version.dart';

/// 管理外部调试工具进程，并从其 RTT TCP 端口读取 Up 0。
abstract class TcpProcessRttBackend
    implements RttBackend, RttBackendFailureProvider {
  static final Stopwatch _monotonicClock = Stopwatch()..start();

  final StreamController<RttDataChunk> _dataController =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnosticController =
      StreamController<String>.broadcast();
  Process? _process;
  // Socket 在 disconnect 中显式关闭；异常退出时由 _markDisconnected 销毁。
  // ignore: close_sinks
  Socket? _socket;
  bool _connected = false;
  bool _disconnecting = false;
  Completer<void>? _transportClosed;
  String? _lastFailure;

  @override
  Stream<RttDataChunk> get dataStream => _dataController.stream;
  @override
  Stream<String> get diagnosticStream => _diagnosticController.stream;
  @override
  bool get isConnected => _connected;
  @override
  String? get lastFailure => _lastFailure;

  /// RTT TCP 建立后保持打开达到该时长，才认为外部后端完成初始连接。
  Duration get startupStabilityDuration => const Duration(milliseconds: 800);

  Future<String?> executablePath(RttProbeKind kind);
  Future<List<String>> buildArguments(RttConnectionConfig config, int port);

  /// RTT TCP 建立后、开始消费数据前应用后端专用配置。
  Future<void> configureRttSocket(
    Socket socket,
    RttConnectionConfig config,
  ) async {}

  /// 过滤外部工具写入 RTT TCP 的协议头；默认原样交付。
  Uint8List filterRttData(Uint8List data) => data;

  /// 每次连接前重置有状态的数据过滤器。
  void resetRttDataFilter() {}

  /// 从外部工具诊断中提取适合直接展示给用户的失败原因。
  String? parseFailureDiagnostic(String line) => null;

  /// 允许子类使用已分行的诊断消息确认后端就绪状态。
  void onDiagnosticLine(String line) {}

  @override
  Future<bool> isAvailable(RttProbeKind kind) async =>
      await executablePath(kind) != null;

  @override
  Future<void> connect(RttConnectionConfig config) async {
    await disconnect();
    _lastFailure = null;
    _disconnecting = false;
    resetRttDataFilter();
    final executable = await executablePath(config.probeKind);
    if (executable == null) {
      throw RttBackendUnavailableException('$displayName 未安装或路径无效');
    }
    final port = await _reserveTcpPort();
    final arguments = await buildArguments(config, port);
    _diagnosticController.add('启动 $displayName: $executable');
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    unawaited(_forwardDiagnostics(process.stdout));
    unawaited(_forwardDiagnostics(process.stderr));
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          final message = '$displayName 已退出，代码 $code';
          _diagnosticController.add(message);
          if (!_disconnecting) _lastFailure ??= message;
          _markDisconnected();
        }
      }),
    );

    try {
      _socket = await _connectWithRetry(port, process);
      final transportClosed = Completer<void>();
      _transportClosed = transportClosed;
      await configureRttSocket(_socket!, config);
      _socket!.listen(
        (bytes) {
          final filtered = filterRttData(Uint8List.fromList(bytes));
          if (filtered.isEmpty) return;
          final now = DateTime.now().microsecondsSinceEpoch;
          _dataController.add(
            RttDataChunk(
              channel: 0,
              data: filtered,
              monotonicUs: _monotonicClock.elapsedMicroseconds,
              wallClockUs: now,
            ),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          final message = '$displayName RTT 读取失败: $error';
          _diagnosticController.add(message);
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
      try {
        await transportClosed.future.timeout(startupStabilityDuration);
        throw StateError(_lastFailure ?? '$displayName 在连接确认前关闭了 RTT 通道');
      } on TimeoutException {
        if (!identical(_process, process) || _socket == null) {
          throw StateError(_lastFailure ?? '$displayName RTT 通道已关闭');
        }
        _transportClosed = null;
        _connected = true;
      }
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<void> _forwardDiagnostics(Stream<List<int>> stream) async {
    await for (final line in stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final message = line.trim();
      if (message.isEmpty) continue;
      _diagnosticController.add(message);
      onDiagnosticLine(message);
      final failure = parseFailureDiagnostic(message);
      if (failure != null && !_disconnecting) _lastFailure = failure;
    }
  }

  Future<Socket> _connectWithRetry(int port, Process process) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      if (await _hasExited(process)) {
        throw StateError('$displayName 在 RTT 服务就绪前退出');
      }
      try {
        return await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 400),
        );
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw TimeoutException('等待 $displayName RTT 服务超时: $lastError');
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
    _transportClosed = null;
    _disconnecting = false;
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
    await _diagnosticController.close();
  }
}

class ExternalJLinkBackend extends TcpProcessRttBackend
    implements RttBackendVersionProvider {
  ExternalJLinkBackend({
    required this.configuredPath,
    this.fileVersionReader = readWindowsFileVersion,
  });

  final String Function() configuredPath;
  final String? Function(String path) fileVersionReader;
  final JlinkRttBannerFilter _bannerFilter = JlinkRttBannerFilter();

  @override
  String get id => 'external-jlink';
  @override
  String get displayName => '外部 J-Link';

  @override
  Duration get startupStabilityDuration => const Duration(milliseconds: 1500);

  @override
  void resetRttDataFilter() => _bannerFilter.reset();

  @override
  Uint8List filterRttData(Uint8List data) => _bannerFilter.add(data);

  @override
  String? parseFailureDiagnostic(String line) =>
      parseJlinkConnectionFailure(line);

  @override
  Future<String?> executablePath(RttProbeKind kind) async {
    if (kind != RttProbeKind.jlink) return null;
    return _findExecutable(
      configuredPath(),
      'JLinkGDBServerCL.exe',
      extraDirectories: [
        if (Platform.environment['ProgramFiles'] case final path?)
          '$path\\SEGGER',
        if (Platform.environment['ProgramFiles(x86)'] case final path?)
          '$path\\SEGGER',
      ],
    );
  }

  @override
  Future<String?> detectVersion(RttProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return null;
    final resourceVersion = fileVersionReader(executable);
    if (resourceVersion != null) {
      return normalizeJlinkVersion(resourceVersion);
    }
    return parseJlinkVersionFromPath(executable);
  }

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async {
    final gdbServer = await executablePath(kind);
    if (gdbServer == null) return const [];
    final commander = File(
      '${File(gdbServer).parent.path}${Platform.pathSeparator}JLink.exe',
    );
    if (await commander.exists()) {
      final commandFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'serialtools-jlink-list-${DateTime.now().microsecondsSinceEpoch}.jlink',
      );
      try {
        await commandFile.writeAsString('ShowEmuList USB\nExit\n', flush: true);
        final process = await Process.start(commander.path, [
          '-NoGui',
          '1',
          '-ExitOnError',
          '1',
          '-CommandFile',
          commandFile.path,
        ], runInShell: false);
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill();
          throw TimeoutException('J-Link Commander 探针枚举超时');
        }
        final probes = parseJlinkProbeList('${await stdout}\n${await stderr}');
        if (probes.isNotEmpty) return probes;
      } catch (error) {
        AppLogger().warning('J-Link 探针枚举失败: $error', category: 'RTT');
      } finally {
        if (await commandFile.exists()) await commandFile.delete();
      }
    }
    return const [
      RttProbeInfo(id: '', name: 'J-Link（自动选择）', kind: RttProbeKind.jlink),
    ];
  }

  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return const [];
    final root = File(executable).parent;
    final names = <String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('jlinkdevices.xml')) {
        continue;
      }
      try {
        final content = await entity.readAsString();
        for (final match in RegExp(
          r'(?:Name|ChipName)\s*=\s*"([^"]+)"',
          caseSensitive: false,
        ).allMatches(content)) {
          final name = match.group(1)?.trim();
          if (name != null && name.isNotEmpty) names.add(name);
        }
      } catch (error) {
        AppLogger().warning(
          '读取 J-Link 设备数据库失败: ${entity.path}, $error',
          category: 'RTT',
        );
      }
    }
    return names
        .map((name) => RttTargetInfo(name: name, source: 'J-Link'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<List<String>> buildArguments(
    RttConnectionConfig config,
    int port,
  ) async {
    if (config.autoDetectTarget || config.target.trim().isEmpty) {
      throw const FormatException('J-Link 外部模式必须手动选择目标芯片');
    }
    final gdbPort = await _reserveTcpPort();
    return [
      '-device',
      config.target,
      '-if',
      config.wireProtocol == RttWireProtocol.swd ? 'SWD' : 'JTAG',
      '-speed',
      '${config.clockKhz}',
      // GDB Server V8.24+ 使用 -USB 按序列号选择指定探针。
      if (config.probeId.isNotEmpty) ...['-USB', config.probeId],
      '-port',
      '$gdbPort',
      '-RTTTelnetPort',
      '$port',
      // GDB Server 默认会在启动时停住目标核；RTT 只读查看必须保持固件运行，
      // 否则只能读到停机前缓冲，强制结束进程后目标也可能继续保持停止状态。
      '-nohalt',
      '-singlerun',
      '-nogui',
    ];
  }

  @override
  Future<void> configureRttSocket(
    Socket socket,
    RttConnectionConfig config,
  ) async {
    final command = buildJlinkRttConfigString(config);
    if (command == null) return;
    socket.add(utf8.encode(command));
    await socket.flush();
  }
}

/// 过滤 J-Link RTT Telnet 在每次连接开头注入的三行服务信息。
///
/// 这些内容描述 J-Link 软件和探针，并非目标固件输出；过滤器按行增量处理，
/// 即使 TCP 将 banner 拆成多个数据块也不会泄漏到 RTT 历史中。
class JlinkRttBannerFilter {
  static const int _maxProbeBytes = 4096;
  final List<int> _pending = [];
  int _removedLines = 0;
  bool _complete = false;

  Uint8List add(Uint8List data) {
    if (_complete || data.isEmpty) return data;
    _pending.addAll(data);
    if (_pending.length > _maxProbeBytes) return _finish();

    if (_removedLines == 0 && _pending.length >= 16) {
      final prefix = ascii.decode(
        _pending.take(16).toList(growable: false),
        allowInvalid: true,
      );
      if (!prefix.startsWith('SEGGER J-Link')) return _finish();
    }

    while (true) {
      final newline = _pending.indexOf(0x0A);
      if (newline < 0) return Uint8List(0);
      final line =
          ascii
              .decode(_pending.sublist(0, newline + 1), allowInvalid: true)
              .trim();
      if (!_isJlinkBannerLine(line)) return _finish();
      _pending.removeRange(0, newline + 1);
      _removedLines++;
      if (_removedLines >= 3) return _finish();
    }
  }

  void reset() {
    _pending.clear();
    _removedLines = 0;
    _complete = false;
  }

  Uint8List _finish() {
    _complete = true;
    final output = Uint8List.fromList(_pending);
    _pending.clear();
    return output;
  }
}

bool _isJlinkBannerLine(String line) {
  if (line.startsWith('SEGGER J-Link') &&
      line.contains('Real time terminal output')) {
    return true;
  }
  if (line.startsWith('SEGGER J-Link') && line.contains('SN=')) return true;
  return line == 'Process: JLinkGDBServerCL.exe';
}

/// 将常见 J-Link GDB Server 失败诊断转换为用户可操作的中文提示。
String? parseJlinkConnectionFailure(String line) {
  final lower = line.toLowerCase();
  if (RegExp(r'target voltage:\s*0(?:\.0+)?\s*v').hasMatch(lower)) {
    return 'J-Link 未检测到目标板供电，请检查目标板电源、地线和调试接口';
  }
  if (lower.contains('could not connect to target') ||
      lower.contains('cannot connect to target') ||
      lower.contains('failed to connect to target') ||
      lower.contains('target connection failed')) {
    return 'J-Link 无法连接目标芯片，请检查供电、接线、芯片型号和调试接口';
  }
  if (lower.contains('no emulators connected') ||
      lower.contains('cannot connect to j-link')) {
    return '无法连接 J-Link 探针，请检查 USB 连接和探针占用状态';
  }
  if (lower.contains('error:')) return 'J-Link：${line.trim()}';
  return null;
}

/// 生成 J-Link RTT Telnet 配置串；Auto 使用 J-Link 默认扫描，无需发送。
String? buildJlinkRttConfigString(RttConnectionConfig config) {
  switch (config.controlBlockMode) {
    case RttControlBlockMode.automatic:
      return null;
    case RttControlBlockMode.address:
      final address = config.controlBlockAddress;
      if (address == null || address < 0) {
        throw const FormatException('指定地址模式需要有效的 RTT 控制块地址');
      }
      return r'$$SEGGER_TELNET_ConfigStr=SetRTTAddr;'
          '0x${address.toRadixString(16)};'
          r'$$';
    case RttControlBlockMode.range:
      final start = config.controlBlockRangeStart;
      final end = config.controlBlockRangeEnd;
      if (start == null || start < 0 || end == null || end <= start) {
        throw const FormatException('指定范围模式需要有效的起始地址和结束地址');
      }
      final size = end - start;
      return r'$$SEGGER_TELNET_ConfigStr=SetRTTSearchRanges;'
          '0x${start.toRadixString(16)} 0x${size.toRadixString(16)};'
          r'$$';
  }
}

/// 解析 J-Link Commander `ShowEmuList USB` 的稳定字段。
List<RttProbeInfo> parseJlinkProbeList(String output) {
  final probes = <RttProbeInfo>[];
  final pattern = RegExp(
    r'J-Link\[\d+\]:.*?Serial number:\s*([^,\r\n]+)'
    r'(?:,\s*ProductName:\s*([^\r\n]+))?',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(output)) {
    final serial = match.group(1)?.trim() ?? '';
    if (serial.isEmpty) continue;
    final product = match.group(2)?.trim();
    probes.add(
      RttProbeInfo(
        id: serial,
        name:
            product == null || product.isEmpty
                ? 'J-Link ($serial)'
                : '$product ($serial)',
        kind: RttProbeKind.jlink,
      ),
    );
  }
  return probes;
}

class ExternalPyOcdBackend extends TcpProcessRttBackend
    implements RttBackendVersionProvider {
  ExternalPyOcdBackend({required this.configuredPath});

  final String Function() configuredPath;
  bool? _supportedVersion;
  String? _checkedExecutable;
  Completer<void>? _startupReady;

  @override
  String get id => 'external-pyocd';
  @override
  String get displayName => '外部 pyOCD';

  @override
  Future<String?> executablePath(RttProbeKind kind) async {
    if (kind != RttProbeKind.cmsisDap) return null;
    final executable = await _findExecutable(configuredPath(), 'pyocd.exe');
    if (executable == null) return null;
    if (_checkedExecutable != executable) {
      _checkedExecutable = executable;
      _supportedVersion = null;
    }
    if (_supportedVersion == false) return null;
    _supportedVersion ??= await _supportsRttCommand(executable);
    return _supportedVersion! ? executable : null;
  }

  @override
  Future<String?> detectVersion(RttProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return null;
    final result = await Process.run(executable, const [
      '--version',
    ]).timeout(const Duration(seconds: 3));
    return parsePyOcdVersion('${result.stdout}\n${result.stderr}');
  }

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return const [];
    final result = await Process.run(executable, const [
      'json',
      '--probes',
    ]).timeout(const Duration(seconds: 8));
    if (result.exitCode != 0) {
      throw StateError('pyOCD 探针枚举失败：${result.stderr}');
    }
    return parsePyOcdProbeJson('${result.stdout}');
  }

  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return const [];
    final result = await Process.run(executable, const [
      'json',
      '--targets',
    ]).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      throw StateError('pyOCD 目标列表读取失败：${result.stderr}');
    }
    return parsePyOcdTargetJson('${result.stdout}');
  }

  @override
  Future<void> connect(RttConnectionConfig config) async {
    await disconnect();
    _lastFailure = null;
    _disconnecting = false;
    final startupReady = Completer<void>();
    _startupReady = startupReady;
    final executable = await executablePath(config.probeKind);
    if (executable == null) {
      throw const RttBackendUnavailableException('pyOCD 未安装、路径无效或版本不支持 RTT');
    }
    final arguments = await buildArguments(config, 0);
    _diagnosticController.add('启动 $displayName: $executable');
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    final transportClosed = Completer<void>();
    _transportClosed = transportClosed;
    final diagnosticsDone = _forwardDiagnostics(process.stderr);
    unawaited(diagnosticsDone);
    process.stdout.listen(
      (bytes) {
        if (bytes.isEmpty) return;
        if (!startupReady.isCompleted) startupReady.complete();
        final now = DateTime.now().microsecondsSinceEpoch;
        _dataController.add(
          RttDataChunk(
            channel: 0,
            data: Uint8List.fromList(bytes),
            monotonicUs:
                TcpProcessRttBackend._monotonicClock.elapsedMicroseconds,
            wallClockUs: now,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        final message = 'pyOCD RTT 输出读取失败: $error';
        _diagnosticController.add(message);
        if (!_disconnecting) _lastFailure = message;
        _markDisconnected();
      },
      cancelOnError: true,
    );
    unawaited(
      process.exitCode.then((code) async {
        if (!identical(_process, process)) return;
        // 先读完 stderr，避免通用退出码覆盖 pyOCD 的真实失败原因。
        await diagnosticsDone;
        if (!identical(_process, process)) return;
        final message = '外部 pyOCD 已退出，代码 $code';
        _diagnosticController.add(message);
        if (!_disconnecting) _lastFailure ??= message;
        _markDisconnected();
      }),
    );
    try {
      final result = await Future.any<int>([
        startupReady.future.then((_) => 0),
        transportClosed.future.then((_) => 1),
      ]).timeout(const Duration(seconds: 15));
      if (result == 1 || !identical(_process, process)) {
        throw StateError(_lastFailure ?? 'pyOCD RTT 会话已结束');
      }
      _transportClosed = null;
      _connected = true;
    } on TimeoutException {
      await disconnect();
      throw TimeoutException(
        _lastFailure ?? 'pyOCD 未在 15 秒内找到 RTT 控制块或 Up 0 通道',
      );
    } catch (_) {
      await disconnect();
      rethrow;
    } finally {
      if (identical(_startupReady, startupReady)) _startupReady = null;
    }
  }

  @override
  void onDiagnosticLine(String line) {
    if (line.toLowerCase().contains('reading from up channel')) {
      final ready = _startupReady;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
  }

  @override
  Future<List<String>> buildArguments(
    RttConnectionConfig config,
    int port,
  ) async {
    _validatePyOcdControlBlock(config);
    return [
      'rtt',
      '--no-wait',
      '--up-channel-id',
      '0',
      if (config.controlBlockMode == RttControlBlockMode.address) ...[
        '--address',
        '0x${config.controlBlockAddress!.toRadixString(16)}',
      ],
      if (config.controlBlockMode == RttControlBlockMode.range) ...[
        '--address',
        '0x${config.controlBlockRangeStart!.toRadixString(16)}',
        '--size',
        '0x${(config.controlBlockRangeEnd! - config.controlBlockRangeStart!).toRadixString(16)}',
      ],
      if (!config.autoDetectTarget && config.target.isNotEmpty) ...[
        '--target',
        config.target,
      ],
      if (config.probeId.isNotEmpty) ...['--uid', config.probeId],
      '--frequency',
      '${config.clockKhz * 1000}',
      '--connect',
      'attach',
      '-O',
      'dap_protocol=${config.wireProtocol.value}',
      '-O',
      'resume_on_disconnect=true',
    ];
  }

  @override
  String? parseFailureDiagnostic(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('no available debug probes') ||
        lower.contains('no connected debug probes') ||
        lower.contains('no probe selected') ||
        lower.contains('no target device available')) {
      return 'pyOCD 未检测到 CMSIS-DAP 探针，请检查 USB 连接、驱动和探针占用状态';
    }
    if (lower.contains('no control block') ||
        lower.contains('rtt control block') && lower.contains('not found')) {
      return 'pyOCD 未找到 RTT 控制块，请检查目标芯片和控制块定位设置';
    }
    if (lower.contains('error') || lower.contains('exception')) {
      return 'pyOCD：${line.trim()}';
    }
    return null;
  }

  Future<bool> _supportsRttCommand(String executable) async {
    try {
      final result = await Process.run(executable, const [
        '--version',
      ]).timeout(const Duration(seconds: 3));
      final match = RegExp(
        r'(\d+)\.(\d+)(?:\.(\d+))?',
      ).firstMatch('${result.stdout} ${result.stderr}');
      if (match == null) return false;
      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      // 外部后端依赖 pyOCD 0.44 起稳定的独立 RTT 命令行接口。
      return major > 0 || minor >= 44;
    } catch (_) {
      return false;
    }
  }
}

void _validatePyOcdControlBlock(RttConnectionConfig config) {
  switch (config.controlBlockMode) {
    case RttControlBlockMode.automatic:
      return;
    case RttControlBlockMode.address:
      final address = config.controlBlockAddress;
      if (address == null || address < 0) {
        throw const FormatException('指定地址模式需要有效的 RTT 控制块地址');
      }
      return;
    case RttControlBlockMode.range:
      final start = config.controlBlockRangeStart;
      final end = config.controlBlockRangeEnd;
      if (start == null || start < 0 || end == null || end <= start) {
        throw const FormatException('指定范围模式需要有效的起始地址和结束地址');
      }
      return;
  }
}

/// 解析 `pyocd json --probes` 的稳定机器接口，UID 不限制长度或字符集。
List<RttProbeInfo> parsePyOcdProbeJson(String output) {
  final root = jsonDecode(output);
  if (root is! Map) throw const FormatException('pyOCD 探针 JSON 根节点无效');
  if (root['status'] != 0) {
    throw FormatException('${root['error'] ?? 'pyOCD 探针枚举失败'}');
  }
  return (root['boards'] as List? ?? const [])
      .whereType<Map>()
      .map((item) {
        final id = '${item['unique_id'] ?? ''}'.trim();
        final info = '${item['info'] ?? ''}'.trim();
        final product = '${item['product_name'] ?? ''}'.trim();
        return RttProbeInfo(
          id: id,
          name:
              (info.isNotEmpty
                  ? info
                  : product.isNotEmpty
                  ? product
                  : 'CMSIS-DAP') +
              (id.isEmpty ? '' : ' ($id)'),
          kind: RttProbeKind.cmsisDap,
        );
      })
      .where((item) => item.id.isNotEmpty)
      .toList(growable: false);
}

/// 解析 `pyocd json --targets`，避免依赖终端表格列宽和本地化文本。
List<RttTargetInfo> parsePyOcdTargetJson(String output) {
  final root = jsonDecode(output);
  if (root is! Map) throw const FormatException('pyOCD 目标 JSON 根节点无效');
  if (root['status'] != 0) {
    throw FormatException('${root['error'] ?? 'pyOCD 目标列表读取失败'}');
  }
  return (root['targets'] as List? ?? const [])
      .whereType<Map>()
      .map(
        (item) => RttTargetInfo(
          name: '${item['name'] ?? ''}'.trim(),
          vendor: '${item['vendor'] ?? ''}'.trim(),
          source: '${item['source'] ?? 'pyOCD'}'.trim(),
        ),
      )
      .where((item) => item.name.isNotEmpty)
      .toList(growable: false);
}

/// 从 J-Link GDB Server 版本输出提取统一的 `vX.Y` 形式。
String? parseJlinkVersion(String output) {
  final match = RegExp(
    r'J-Link GDB Server\s+V(\d+(?:\.\d+)*(?:[A-Za-z]+\d*)?)',
    caseSensitive: false,
  ).firstMatch(output);
  return match == null ? null : 'v${match.group(1)}';
}

/// 统一 Windows 版本资源中的 `V7.52d`、`7.52.4` 等表示。
String? normalizeJlinkVersion(String value) {
  final match = RegExp(
    r'v?(\d+(?:\.\d+)+(?:[A-Za-z]+\d*)?)',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  return 'v${match.group(1)}';
}

/// 版本资源缺失时，从 `JLink_V752d` 一类 SEGGER 安装目录名解析版本。
String? parseJlinkVersionFromPath(String path) {
  final match = RegExp(
    r'JLink[_ -]?V?(\d)(\d{2})([A-Za-z]?)',
    caseSensitive: false,
  ).firstMatch(path);
  if (match == null) return null;
  return 'v${match.group(1)}.${match.group(2)}${match.group(3)}';
}

/// 从 pyOCD 版本输出提取统一的 `vX.Y.Z` 形式。
String? parsePyOcdVersion(String output) {
  final match = RegExp(
    r'\b(\d+\.\d+(?:\.\d+)?(?:[A-Za-z0-9.+-]*)?)\b',
  ).firstMatch(output);
  return match == null ? null : 'v${match.group(1)}';
}

Future<int> _reserveTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<String?> _findExecutable(
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
