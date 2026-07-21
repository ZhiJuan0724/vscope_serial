import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/models/rtt_config.dart';
import 'rtt_backend.dart';

/// 与随应用发布的通用 probe-rs 探针辅助进程通信。
class ProbeRsBackend implements RttBackend, RttBackendVersionProvider {
  ProbeRsBackend({
    required this.configuredPath,
    required this.targetsDirectory,
  });

  static const int _magic = 0x31545452; // ASCII: RTT1
  static const int _headerLength = 9;
  static const int _maxFrameLength = 16 * 1024 * 1024;

  final String Function() configuredPath;
  final String Function() targetsDirectory;
  final StreamController<RttDataChunk> _dataController =
      StreamController<RttDataChunk>.broadcast();
  final StreamController<String> _diagnosticController =
      StreamController<String>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final BytesBuilder _input = BytesBuilder(copy: false);
  Process? _process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int _requestId = 0;
  bool _connected = false;

  @override
  String get id => 'builtin-probe-rs';
  @override
  String get displayName => '内置 probe-rs';
  @override
  Stream<RttDataChunk> get dataStream => _dataController.stream;
  @override
  Stream<String> get diagnosticStream => _diagnosticController.stream;
  @override
  bool get isConnected => _connected;

  Future<String?> _helperPath() async {
    final configured = configuredPath().trim();
    final candidates = <String>[
      if (configured.isNotEmpty) configured,
      '${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.pathSeparator}probe_helper.exe',
      '${Directory.current.path}${Platform.pathSeparator}native'
          '${Platform.pathSeparator}probe_helper${Platform.pathSeparator}target'
          '${Platform.pathSeparator}release${Platform.pathSeparator}probe_helper.exe',
      '${Directory.current.path}${Platform.pathSeparator}native'
          '${Platform.pathSeparator}probe_helper${Platform.pathSeparator}target'
          '${Platform.pathSeparator}debug${Platform.pathSeparator}probe_helper.exe',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return File(candidate).absolute.path;
    }
    return null;
  }

  @override
  Future<bool> isAvailable(RttProbeKind kind) async =>
      await _helperPath() != null;

  @override
  Future<String?> detectVersion(RttProbeKind kind) async {
    final path = await _helperPath();
    if (path == null) return null;
    final result = await Process.run(path, const [
      '--version',
    ]).timeout(const Duration(seconds: 3));
    final match = RegExp(
      r'probe_helper\s+(v?\d+\.\d+\.\d+)',
      caseSensitive: false,
    ).firstMatch('${result.stdout}\n${result.stderr}');
    if (match == null) return null;
    final version = match.group(1)!;
    return version.startsWith('v') ? version : 'v$version';
  }

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async {
    final response = await _request('listProbes', {'kind': kind.value});
    return (response['probes'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => RttProbeInfo(
            id: '${item['id'] ?? ''}',
            name: '${item['name'] ?? item['id'] ?? ''}',
            kind: RttProbeKind.fromString('${item['kind'] ?? kind.value}'),
          ),
        )
        .where((probe) => probe.kind == kind)
        .toList();
  }

  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async {
    final response = await _request('listTargets', {
      'kind': kind.value,
      'directory': targetsDirectory(),
    });
    return (response['targets'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => RttTargetInfo(
            name: '${item['name'] ?? ''}',
            vendor: '${item['vendor'] ?? ''}',
            source: '${item['source'] ?? 'probe-rs'}',
          ),
        )
        .where((target) => target.name.isNotEmpty)
        .toList();
  }

  @override
  Future<void> connect(RttConnectionConfig config) async {
    if (_connected) await disconnect();
    await _request('connect', {
      'kind': config.probeKind.value,
      'probeId': config.probeId,
      'target': config.target,
      'autoDetectTarget': config.autoDetectTarget,
      'wireProtocol': config.wireProtocol.value,
      'clockKhz': config.clockKhz,
      'controlBlockMode': config.controlBlockMode.value,
      'controlBlockAddress': config.controlBlockAddress,
      'controlBlockRangeStart': config.controlBlockRangeStart,
      'controlBlockRangeEnd': config.controlBlockRangeEnd,
      'targetsDirectory': targetsDirectory(),
    }, timeout: const Duration(seconds: 15));
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    if (_process != null) {
      try {
        await _request(
          'disconnect',
          const {},
          timeout: const Duration(seconds: 3),
        );
      } catch (_) {
        // helper 已退出时继续完成本地清理。
      }
    }
    _connected = false;
  }

  Future<void> _ensureStarted() async {
    if (_process != null) return;
    final path = await _helperPath();
    if (path == null) {
      throw const RttBackendUnavailableException('内置探针辅助进程不存在');
    }
    final process = await Process.start(path, const [], runInShell: false);
    _process = process;
    _stdoutSubscription = process.stdout.listen(
      _onBytes,
      onError: _failAll,
      onDone: () => _handleExit('内置探针辅助进程输出已关闭'),
    );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _diagnosticController.add(line));
    unawaited(
      process.exitCode.then((code) => _handleExit('内置探针辅助进程已退出，代码 $code')),
    );
    final hello = await _requestWithoutStart('hello', const {
      'protocolVersion': 1,
    }, timeout: const Duration(seconds: 2));
    if (hello['protocolVersion'] != 1) {
      await _stopProcess();
      throw StateError('内置探针辅助进程协议版本不兼容');
    }
    final capabilities =
        (hello['capabilities'] as List? ?? const [])
            .map((item) => '$item')
            .toSet();
    if (!capabilities.contains('rtt.up.read')) {
      await _stopProcess();
      throw StateError('内置探针辅助进程不支持 RTT 读取');
    }
  }

  Future<Map<String, dynamic>> _request(
    String command,
    Map<String, dynamic> arguments, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await _ensureStarted();
    return _requestWithoutStart(command, arguments, timeout: timeout);
  }

  Future<Map<String, dynamic>> _requestWithoutStart(
    String command,
    Map<String, dynamic> arguments, {
    required Duration timeout,
  }) {
    final process = _process;
    if (process == null) throw StateError('探针辅助进程尚未启动');
    final id = ++_requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final payload = utf8.encode(
      jsonEncode({'id': id, 'command': command, 'arguments': arguments}),
    );
    process.stdin.add(_encodeFrame(1, Uint8List.fromList(payload)));
    unawaited(process.stdin.flush());
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('探针辅助进程请求超时: $command');
      },
    );
  }

  void _onBytes(List<int> bytes) {
    _input.add(bytes);
    var data = _input.takeBytes();
    var offset = 0;
    while (data.length - offset >= _headerLength) {
      final header = ByteData.sublistView(data, offset, offset + _headerLength);
      if (header.getUint32(0, Endian.little) != _magic) {
        _failAll(StateError('探针辅助进程返回了无效帧头'));
        return;
      }
      final type = header.getUint8(4);
      final length = header.getUint32(5, Endian.little);
      if (length > _maxFrameLength) {
        _failAll(StateError('探针辅助进程帧超过上限: $length'));
        return;
      }
      if (data.length - offset < _headerLength + length) break;
      final payload = Uint8List.sublistView(
        data,
        offset + _headerLength,
        offset + _headerLength + length,
      );
      _handleFrame(type, payload);
      offset += _headerLength + length;
    }
    if (offset < data.length) _input.add(data.sublist(offset));
  }

  void _handleFrame(int type, Uint8List payload) {
    if (type == 2) {
      final response = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final id = (response['id'] as num?)?.toInt();
      if (id == null) return;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (response['ok'] == true) {
        completer.complete(
          (response['result'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      } else {
        completer.completeError(
          StateError('${response['error'] ?? '探针辅助进程请求失败'}'),
        );
      }
      return;
    }
    if (type == 3 && payload.length >= 20) {
      final header = ByteData.sublistView(payload, 0, 20);
      _dataController.add(
        RttDataChunk(
          channel: header.getUint32(0, Endian.little),
          monotonicUs: header.getInt64(4, Endian.little),
          wallClockUs: header.getInt64(12, Endian.little),
          data: Uint8List.fromList(payload.sublist(20)),
        ),
      );
      return;
    }
    if (type == 4) _diagnosticController.add(utf8.decode(payload));
    if (type == 5) {
      final event = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      _connected = event['connected'] == true;
      final error = '${event['error'] ?? ''}'.trim();
      if (error.isNotEmpty) _diagnosticController.add(error);
    }
  }

  Uint8List _encodeFrame(int type, Uint8List payload) {
    final frame = Uint8List(_headerLength + payload.length);
    final header = ByteData.sublistView(frame);
    header.setUint32(0, _magic, Endian.little);
    header.setUint8(4, type);
    header.setUint32(5, payload.length, Endian.little);
    frame.setRange(_headerLength, frame.length, payload);
    return frame;
  }

  void _handleExit(String message) {
    if (_process == null) return;
    _diagnosticController.add(message);
    _connected = false;
    _process = null;
    _failAll(StateError(message));
  }

  void _failAll(Object error, [StackTrace? stackTrace]) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
  }

  Future<void> _stopProcess() async {
    final process = _process;
    _process = null;
    process?.kill();
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stopProcess();
    await _dataController.close();
    await _diagnosticController.close();
  }
}
