import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/models/probe_plot_config.dart';
import '../data/models/probe_connection_config.dart';
import 'elf_symbol_reader.dart';
import 'probe_backend.dart';

const _pyOcdMagic = <int>[0x56, 0x53, 0x50, 0x59]; // VSPY
const _pyOcdProtocolVersion = 1;
const _frameRequest = 1;
const _frameResponse = 2;
const _frameDiagnostic = 3;
const _frameRttData = 4;
const _frameSampleData = 5;
const _frameDownData = 6;
const _monitorProfile = 'nonIntrusiveMonitor';

/// 从外置 pyOCD Worker 解码出的一个完整协议帧。
///
/// 保持公开是为了在不启动 Python、不接触探针的情况下测试拆包与粘包。
class PyOcdWorkerFrame {
  const PyOcdWorkerFrame(this.type, this.requestId, this.payload);

  final int type;
  final int requestId;
  final Uint8List payload;
}

/// 带版本校验的 VSPY 二进制协议增量解码器。
class PyOcdWorkerFrameDecoder {
  final List<int> _buffer = <int>[];

  List<PyOcdWorkerFrame> add(List<int> bytes) {
    // stdout 的一次回调不等于一个协议帧，因此必须缓存半帧，并在一次回调
    // 中连续取出可能粘在一起的多个完整帧。
    _buffer.addAll(bytes);
    final result = <PyOcdWorkerFrame>[];
    while (_buffer.length >= 16) {
      for (var index = 0; index < _pyOcdMagic.length; index++) {
        if (_buffer[index] != _pyOcdMagic[index]) {
          throw const FormatException('pyOCD Worker 协议 magic 无效');
        }
      }
      if (_buffer[4] != _pyOcdProtocolVersion) {
        throw FormatException('不支持的 pyOCD Worker 协议版本：${_buffer[4]}');
      }
      final header = ByteData.sublistView(Uint8List.fromList(_buffer), 0, 16);
      final requestId = header.getUint32(8, Endian.little);
      final length = header.getUint32(12, Endian.little);
      if (length > 64 * 1024 * 1024) {
        throw const FormatException('pyOCD Worker 帧过大');
      }
      if (_buffer.length < 16 + length) break;
      result.add(
        PyOcdWorkerFrame(
          _buffer[5],
          requestId,
          Uint8List.fromList(_buffer.sublist(16, 16 + length)),
        ),
      );
      _buffer.removeRange(0, 16 + length);
    }
    return result;
  }
}

class _WorkerDiagnostic {
  const _WorkerDiagnostic(this.message, {this.fatal = false});

  final String message;
  final bool fatal;
}

class _WorkerRttData {
  const _WorkerRttData(this.channel, this.data);

  final int channel;
  final Uint8List data;
}

class _PyOcdWorkerClient {
  /// 管理单个 Python Worker 进程及其请求、实时数据和异常生命周期。
  _PyOcdWorkerClient({required this.pythonPath, required this.workerPath});

  final String pythonPath;
  final String workerPath;
  final StreamController<_WorkerDiagnostic> _diagnostics =
      StreamController<_WorkerDiagnostic>.broadcast();
  final StreamController<_WorkerRttData> _rtt =
      StreamController<_WorkerRttData>.broadcast();
  final StreamController<ProbeSampleChunk> _samples =
      StreamController<ProbeSampleChunk>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final PyOcdWorkerFrameDecoder _decoder = PyOcdWorkerFrameDecoder();
  Process? _process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _nextRequestId = 1;
  bool _closing = false;
  DateTime? _lastStderrDiagnosticAt;
  int _suppressedStderrDiagnostics = 0;

  Stream<_WorkerDiagnostic> get diagnostics => _diagnostics.stream;
  Stream<_WorkerRttData> get rttData => _rtt.stream;
  Stream<ProbeSampleChunk> get samples => _samples.stream;
  bool get isRunning => _process != null;

  Future<void> start() async {
    if (_process != null) return;
    _closing = false;
    final process = await Process.start(
      pythonPath,
      ['-I', '-u', workerPath],
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    // stdout 只允许承载 VSPY 二进制帧；Worker 的普通诊断统一走 stderr。
    _stdoutSubscription = process.stdout.listen(
      _handleStdout,
      onError: (Object error, StackTrace stackTrace) {
        _fail('pyOCD Worker 协议读取失败：$error');
      },
      onDone: () {
        if (!_closing) _fail('pyOCD Worker 输出已关闭');
      },
      cancelOnError: true,
    );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final message = line.trim();
          if (message.isEmpty || _diagnostics.isClosed) return;
          final now = DateTime.now();
          final last = _lastStderrDiagnosticAt;
          // 第三方库可能在 USB 异常时高速重复打印。这里限频转发，避免日志
          // 刷新反过来拖死 UI；被抑制数量会合并到下一条诊断中。
          if (last != null &&
              now.difference(last) < const Duration(milliseconds: 500)) {
            _suppressedStderrDiagnostics++;
            return;
          }
          final suppressed = _suppressedStderrDiagnostics;
          _suppressedStderrDiagnostics = 0;
          _lastStderrDiagnosticAt = now;
          _diagnostics.add(
            _WorkerDiagnostic(
              suppressed == 0 ? message : '$message（已抑制 $suppressed 条重复诊断）',
            ),
          );
        });
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          if (!_closing) _fail('pyOCD Worker 已退出，代码 $code');
        }
      }),
    );
  }

  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    final payload = utf8.encode(
      jsonEncode(<String, dynamic>{'command': command, 'args': args}),
    );
    return _sendRequest(_frameRequest, Uint8List.fromList(payload));
  }

  Future<Map<String, dynamic>> sendDown(Uint8List data) =>
      _sendRequest(_frameDownData, data);

  Future<Map<String, dynamic>> _sendRequest(int type, Uint8List payload) async {
    final process = _process;
    if (process == null) throw StateError('pyOCD Worker 未运行');
    final requestId = _nextRequestId++;
    // requestId 将异步响应准确归还给对应调用；实时数据帧固定使用 ID 0，
    // 不会占用控制请求的等待表。
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    try {
      process.stdin.add(_encodeFrame(type, requestId, payload));
      await process.stdin.flush();
      return await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _pending.remove(requestId);
      throw TimeoutException('pyOCD Worker 请求超时：${commandForType(type)}');
    } catch (_) {
      _pending.remove(requestId);
      rethrow;
    }
  }

  void _handleStdout(List<int> bytes) {
    try {
      for (final frame in _decoder.add(bytes)) {
        switch (frame.type) {
          case _frameResponse:
            // 控制响应可能早于或晚于实时数据到达，必须按 requestId 完成。
            final decoded = _decodeJsonObject(frame.payload);
            final completer = _pending.remove(frame.requestId);
            if (completer == null) continue;
            if (decoded['ok'] == true) {
              final result = decoded['result'];
              completer.complete(
                result is Map
                    ? Map<String, dynamic>.from(result)
                    : <String, dynamic>{'value': result},
              );
            } else {
              completer.completeError(
                StateError('${decoded['error'] ?? 'pyOCD Worker 请求失败'}'),
              );
            }
          case _frameDiagnostic:
            final decoded = _decodeJsonObject(frame.payload);
            if (!_diagnostics.isClosed) {
              _diagnostics.add(
                _WorkerDiagnostic(
                  '${decoded['message'] ?? ''}',
                  fatal: decoded['fatal'] == true,
                ),
              );
            }
          case _frameRttData:
            if (frame.payload.length < 2) {
              throw const FormatException('pyOCD RTT 数据帧过短');
            }
            final data = ByteData.sublistView(frame.payload);
            if (!_rtt.isClosed) {
              _rtt.add(
                _WorkerRttData(
                  data.getUint16(0, Endian.little),
                  Uint8List.sublistView(frame.payload, 2),
                ),
              );
            }
          case _frameSampleData:
            _decodeSample(frame.payload);
          default:
            throw FormatException('未知 pyOCD Worker 帧类型：${frame.type}');
        }
      }
    } catch (error) {
      _fail('pyOCD Worker 协议错误：$error');
    }
  }

  void _decodeSample(Uint8List payload) {
    if (payload.length < 10) {
      throw const FormatException('pyOCD HSS 数据帧过短');
    }
    final bytes = ByteData.sublistView(payload);
    final monotonicUs = bytes.getUint64(0, Endian.little);
    final count = bytes.getUint16(8, Endian.little);
    if (payload.length != 10 + count * 8) {
      throw const FormatException('pyOCD HSS 数据帧长度无效');
    }
    final values = Float64List(count);
    for (var index = 0; index < count; index++) {
      values[index] = bytes.getFloat64(10 + index * 8, Endian.little);
    }
    if (!_samples.isClosed) {
      _samples.add(ProbeSampleChunk(monotonicUs: monotonicUs, values: values));
    }
  }

  void _fail(String message) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(StateError(message));
    }
    _pending.clear();
    if (!_diagnostics.isClosed) {
      _diagnostics.add(_WorkerDiagnostic(message, fatal: true));
    }
  }

  Future<void> close() async {
    // 正常关闭先请求 Worker 自行释放主机侧探针传输；若 Worker 无响应才杀进程。
    final process = _process;
    if (process == null) return;
    _closing = true;
    try {
      await request('shutdown').timeout(const Duration(seconds: 3));
    } catch (_) {
      process.kill();
    }
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    }
    _process = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _fail('pyOCD Worker 已关闭');
  }

  Future<void> terminate(String reason) async {
    // 超时或协议故障时直接终止 Worker，不能调用可能触碰目标状态的补救流程。
    final process = _process;
    if (process == null) return;
    _closing = true;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    }
    _process = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _fail(reason);
  }

  Future<void> dispose() async {
    await close();
    await _diagnostics.close();
    await _rtt.close();
    await _samples.close();
  }
}

String commandForType(int type) =>
    type == _frameDownData ? 'writeDown0' : 'control';

Uint8List _encodeFrame(int type, int requestId, Uint8List payload) {
  final result = Uint8List(16 + payload.length);
  result.setRange(0, 4, _pyOcdMagic);
  final header = ByteData.sublistView(result);
  header.setUint8(4, _pyOcdProtocolVersion);
  header.setUint8(5, type);
  header.setUint16(6, 0, Endian.little);
  header.setUint32(8, requestId, Endian.little);
  header.setUint32(12, payload.length, Endian.little);
  result.setRange(16, result.length, payload);
  return result;
}

Map<String, dynamic> _decodeJsonObject(Uint8List payload) {
  final value = jsonDecode(utf8.decode(payload));
  if (value is! Map) throw const FormatException('Worker JSON 响应不是对象');
  return Map<String, dynamic>.from(value);
}

/// 解析 `--check` 输出，并强制使用已经审查过的 pyOCD API 版本。
Map<String, dynamic> parsePyOcdWorkerCheck(String output) {
  final value = jsonDecode(output.trim());
  if (value is! Map) throw const FormatException('pyOCD 检测输出无效');
  final result = Map<String, dynamic>.from(value);
  if (result['ok'] != true) {
    throw StateError('${result['error'] ?? 'pyOCD 环境不可用'}');
  }
  final version = '${result['pyocdVersion'] ?? ''}';
  if (!RegExp(r'^0\.45(?:\.|$)').hasMatch(version)) {
    throw StateError('仅支持 pyOCD 0.45.x，当前版本为 $version');
  }
  if (result['protocolVersion'] != _pyOcdProtocolVersion) {
    throw StateError('pyOCD Worker 协议版本不匹配');
  }
  return result;
}

Future<String?> findPyOcdWorkerScript() async {
  // 第一项对应打包后的 Flutter assets，第二项供源码调试和单元测试使用。
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    '$executableDirectory/data/flutter_assets/assets/runtime/pyocd_worker.py',
    '${Directory.current.path}/assets/runtime/pyocd_worker.py',
  ];
  for (final candidate in candidates) {
    if (await File(candidate).exists()) return File(candidate).absolute.path;
  }
  return null;
}

/// 外置 pyOCD 0.45.x 后端，只建立受限 MEM-AP 监控会话。
///
/// RTT Viewer、RTT 绘图和 HSS 共用连接，但开始/停止各自的数据轮询任务。
/// 本后端不暴露烧录、核心控制、断点或观察点命令。
class ExternalPyOcdBackend
    implements
        ProbeBackend,
        ProbeBackendVersionProvider,
        ProbeBackendFailureProvider,
        RttActivityBackend,
        RttControlBlockConfigurable,
        ProbePlotBackend,
        RttChannelMetadataProvider,
        ConfiguredProbeDiscovery {
  ExternalPyOcdBackend({required this.configuredPythonPath});

  final String Function() configuredPythonPath;
  final StreamController<RttDataChunk> _dataController =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnosticController =
      StreamController<String>.broadcast();
  final StreamController<ProbeSampleChunk> _sampleController =
      StreamController<ProbeSampleChunk>.broadcast();
  final Stopwatch _monotonicClock = Stopwatch()..start();
  _PyOcdWorkerClient? _client;
  StreamSubscription<_WorkerDiagnostic>? _diagnosticSubscription;
  StreamSubscription<_WorkerRttData>? _rttSubscription;
  StreamSubscription<ProbeSampleChunk>? _sampleSubscription;
  RttControlBlockConfig _rttConfig = const RttControlBlockConfig(
    mode: RttControlBlockMode.automatic,
  );
  bool _connected = false;
  bool _disconnecting = false;
  String? _lastFailure;

  @override
  String get id => 'external-pyocd';
  @override
  String get displayName => '外置 pyOCD';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get supportsAutomaticControlBlock => true;
  @override
  bool get isConnected => _connected;
  @override
  String? get lastFailure => _lastFailure;
  @override
  Stream<RttDataChunk> get dataStream => _dataController.stream;
  @override
  Stream<String> get diagnosticStream => _diagnosticController.stream;
  @override
  Stream<ProbeSampleChunk> get sampleStream => _sampleController.stream;
  @override
  Set<ProbeBackendCapability> get capabilities => const {
    ProbeBackendCapability.downChannel0,
    ProbeBackendCapability.independentActivity,
    ProbeBackendCapability.memorySampling,
    ProbeBackendCapability.channelMetadata,
  };

  Future<(String, String)?> _runtime() async {
    final python = configuredPythonPath().trim();
    if (python.isEmpty || !await File(python).exists()) return null;
    final worker = await findPyOcdWorkerScript();
    if (worker == null) return null;
    return (File(python).absolute.path, worker);
  }

  Future<Map<String, dynamic>> _check() async {
    final runtime = await _runtime();
    if (runtime == null) {
      throw const ProbeBackendUnavailableException(
        '请在高级设置中配置能够 import pyocd 的 python.exe',
      );
    }
    final result = await Process.run(runtime.$1, [
      '-I',
      '-u',
      runtime.$2,
      '--check',
    ], runInShell: false).timeout(const Duration(seconds: 5));
    final output = '${result.stdout}'.trim();
    if (output.isEmpty) {
      throw StateError(
        '${result.stderr}'.trim().isEmpty
            ? 'pyOCD 环境检测没有输出'
            : '${result.stderr}'.trim(),
      );
    }
    return parsePyOcdWorkerCheck(output);
  }

  @override
  Future<bool> isAvailable(ProbeKind kind) async {
    if (kind != ProbeKind.cmsisDap) return false;
    try {
      await _check();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> detectVersion(ProbeKind kind) async {
    if (kind != ProbeKind.cmsisDap) return null;
    final result = await _check();
    return 'Python ${result['pythonVersion']} / pyOCD ${result['pyocdVersion']}';
  }

  Future<T> _withTemporaryClient<T>(
    Future<T> Function(_PyOcdWorkerClient client) operation,
  ) async {
    // 枚举和版本查询不应占用长期探针会话，完成后始终回收临时 Worker。
    final runtime = await _runtime();
    if (runtime == null) {
      throw const ProbeBackendUnavailableException(
        '请在高级设置中配置能够 import pyocd 的 python.exe',
      );
    }
    final client = _PyOcdWorkerClient(
      pythonPath: runtime.$1,
      workerPath: runtime.$2,
    );
    try {
      await client.start();
      await _validateHello(await client.request('hello'));
      return await operation(client);
    } finally {
      await client.dispose();
    }
  }

  Future<void> _validateHello(Map<String, dynamic> hello) async {
    final version = '${hello['pyocdVersion'] ?? ''}';
    if (!RegExp(r'^0\.45(?:\.|$)').hasMatch(version)) {
      throw StateError('仅支持 pyOCD 0.45.x，当前版本为 $version');
    }
    if (hello['protocolVersion'] != _pyOcdProtocolVersion) {
      throw StateError('pyOCD Worker 协议版本不匹配');
    }
    final profiles = List<Object?>.from(hello['implementedProfiles'] as List);
    if (!profiles.contains(_monitorProfile)) {
      throw StateError('pyOCD Worker 不支持 $_monitorProfile');
    }
  }

  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async {
    return listProbesForConfig(
      ProbeConnectionConfig(
        probeKind: kind,
        target: '',
        pyOcdCmsisDapVersion: PyOcdCmsisDapVersion.automatic,
      ),
    );
  }

  @override
  Future<List<ProbeInfo>> listProbesForConfig(
    ProbeConnectionConfig config,
  ) async {
    final kind = config.probeKind;
    if (kind != ProbeKind.cmsisDap) return const [];
    return _withTemporaryClient((client) async {
      // 用户主动刷新只读取 Windows 缓存的 USB 名称和 VID/PID，不运行
      // pyOCD 全量探针发现；真正连接时再对用户选中的设备定向识别。
      final response = await client.request('listUsbDevices');
      return List<Object?>.from(response['value'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .map(
            (item) => ProbeInfo(
              id: 'usb:${item['vendorId'] as int}:${item['productId'] as int}',
              name:
                  '${item['name'] ?? 'USB 设备'} '
                  '(${(item['vendorId'] as int).toRadixString(16).padLeft(4, '0').toUpperCase()}:'
                  '${(item['productId'] as int).toRadixString(16).padLeft(4, '0').toUpperCase()})',
              kind: ProbeKind.cmsisDap,
              usbVendorId: item['vendorId'] as int?,
              usbProductId: item['productId'] as int?,
            ),
          )
          .toList();
    });
  }

  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) async {
    if (kind != ProbeKind.cmsisDap) return const [];
    return _withTemporaryClient((client) async {
      final response = await client.request('listTargets');
      return List<Object?>.from(response['value'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .map(
            (item) => ProbeTargetInfo(
              name: '${item['name'] ?? ''}',
              vendor: '${item['vendor'] ?? ''}',
              source: '${item['source'] ?? 'pyOCD'}',
            ),
          )
          .toList();
    });
  }

  @override
  Future<void> connect(ProbeConnectionConfig config) async {
    if (config.probeKind != ProbeKind.cmsisDap) {
      throw const ProbeBackendUnavailableException('外置 pyOCD 仅支持 CMSIS-DAP');
    }
    await disconnect();
    final runtime = await _runtime();
    if (runtime == null) {
      throw const ProbeBackendUnavailableException(
        '请在高级设置中配置能够 import pyocd 的 python.exe',
      );
    }
    _lastFailure = null;
    _disconnecting = false;
    final client = _PyOcdWorkerClient(
      pythonPath: runtime.$1,
      workerPath: runtime.$2,
    );
    _client = client;
    // 致命诊断会立即反映为断开；普通诊断只转发给统一日志/状态界面。
    _diagnosticSubscription = client.diagnostics.listen((event) {
      if (event.fatal && !_disconnecting) {
        _lastFailure = event.message;
        _connected = false;
      }
      if (!_diagnosticController.isClosed) {
        _diagnosticController.add(event.message);
      }
    });
    _rttSubscription = client.rttData.listen((event) {
      if (_dataController.isClosed || event.data.isEmpty) return;
      _dataController.add(
        // Worker 时间戳只用于 HSS 数据包；RTT 数据在 Dart 收到时补充统一
        // 单调时钟与墙钟，保持与其他后端相同的数据模型。
        RttDataChunk(
          channel: event.channel,
          data: event.data,
          monotonicUs: _monotonicClock.elapsedMicroseconds,
          wallClockUs: DateTime.now().microsecondsSinceEpoch,
        ),
      );
    });
    _sampleSubscription = client.samples.listen(_sampleController.add);
    try {
      await client.start();
      await _validateHello(await client.request('hello'));
      await client.request('connect', {
        'profile': _monitorProfile,
        // 用户选过轻量 USB 列表时传 VID/PID，Worker 只检查这一项；保持
        // “自动选择”时则传 probeId/空值，走隔离的自动发现流程。
        'probeId':
            config.usbVendorId == null || config.usbProductId == null
                ? config.probeId
                : '',
        if (config.usbVendorId != null) 'usbVendorId': config.usbVendorId,
        if (config.usbProductId != null) 'usbProductId': config.usbProductId,
        'target': config.target,
        'autoDetectTarget': config.autoDetectTarget,
        'wireProtocol': config.wireProtocol.value,
        'clockKhz': config.clockKhz,
        'cmsisDapVersion': config.pyOcdCmsisDapVersion.value,
      });
      _connected = true;
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<void> configureRttControlBlock(RttControlBlockConfig config) async {
    _rttConfig = config;
    final client = _client;
    if (client == null || !_connected) return;
    await client.request('configureRtt', _rttConfigJson(config));
  }

  Map<String, dynamic> _rttConfigJson(RttControlBlockConfig config) => {
    'mode': config.mode.value,
    'pollingIntervalMs': config.pollingIntervalMs,
    if (config.address != null) 'address': config.address,
    if (config.rangeStart != null) 'rangeStart': config.rangeStart,
    if (config.rangeEnd != null) 'rangeEnd': config.rangeEnd,
  };

  Future<_PyOcdWorkerClient> _configuredClient() async {
    final client = _client;
    if (client == null || !_connected) throw StateError('pyOCD 探针尚未连接');
    await client.request('configureRtt', _rttConfigJson(_rttConfig));
    return client;
  }

  @override
  Future<void> startRttViewer() async {
    await (await _configuredClient()).request('startRttViewer');
  }

  @override
  Future<List<RttChannelInfo>> listRttUpChannels() async {
    final response = await (await _configuredClient()).request(
      'listRttChannels',
    );
    return List<Object?>.from(response['value'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .map(
          (item) => RttChannelInfo(
            index: item['index'] as int,
            name: '${item['name'] ?? ''}',
            size: item['size'] as int,
            flags: item['flags'] as int,
          ),
        )
        .toList();
  }

  @override
  Future<void> startRttPlot(String channelName) async {
    final channels = await listRttUpChannels();
    final channel =
        channels.where((item) => item.name == channelName).firstOrNull;
    if (channel == null) throw StateError('RTT Up 通道不存在：$channelName');
    await _client!.request('startRttPlot', {'channel': channel.index});
  }

  @override
  Future<void> startHss(
    List<ProbeSampleVariable> variables, {
    required int frequencyHz,
  }) async {
    final client = _client;
    if (client == null || !_connected) throw StateError('pyOCD 探针尚未连接');
    await client.request('startHss', {
      'frequencyHz': frequencyHz,
      'variables': [
        for (final variable in variables)
          {
            'name': variable.name,
            'address': variable.address,
            'type': variable.type.label,
          },
      ],
    });
  }

  @override
  Future<List<ProbeSymbolInfo>> readSymbols(String path) =>
      readElfDataSymbols(path);

  @override
  Future<void> stopActivity() async {
    final client = _client;
    if (client == null || !_connected) return;
    try {
      await client.request('stopActivity').timeout(const Duration(seconds: 3));
    } catch (error) {
      // 停止超时意味着 Worker 状态未知。为保证目标安全，只杀掉主机进程，
      // 不尝试 reset/resume 等所谓“恢复”操作。
      _lastFailure = 'pyOCD 数据活动停止失败，已终止 Worker：$error';
      _connected = false;
      await client.terminate(_lastFailure!);
      throw StateError(_lastFailure!);
    }
  }

  @override
  Future<void> writeDownChannel0(Uint8List data) async {
    final client = _client;
    if (client == null || !_connected) throw StateError('pyOCD 探针尚未连接');
    await client.sendDown(data);
  }

  @override
  Future<void> disconnect() async {
    _disconnecting = true;
    _connected = false;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.request('disconnect').timeout(const Duration(seconds: 3));
      } catch (_) {
        // close() 只终止 Worker，不执行目标 reset/resume 清理。
      }
      await client.dispose();
    }
    await _diagnosticSubscription?.cancel();
    await _rttSubscription?.cancel();
    await _sampleSubscription?.cancel();
    _diagnosticSubscription = null;
    _rttSubscription = null;
    _sampleSubscription = null;
    _disconnecting = false;
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
    await _diagnosticController.close();
    await _sampleController.close();
  }
}
