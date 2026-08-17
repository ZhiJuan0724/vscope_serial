import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/models/flash_programming_models.dart';
import 'bundled_openocd_runtime.dart';
import 'flash_programming_backend.dart';
import 'rtt_process_backend_base.dart';

String buildOpenOcdWriteImageCommand(FlashProgramRequest request) {
  request.validate();
  final type = request.isBinary ? ' bin' : '';
  final offset =
      request.isBinary ? ' 0x${request.binAddress!.toRadixString(16)}' : '';
  return 'flash write_image${request.erase ? ' erase' : ''} '
      '${quoteOpenOcdTclPath(request.filePath)}$offset$type';
}

class OpenOcdProgrammingBackend implements FlashProgrammingBackend {
  OpenOcdProgrammingBackend({required this.bundled});

  final bool bundled;
  final _outputController = StreamController<String>.broadcast();
  bool _outputClosed = false;
  Process? _process;
  _ProgrammingTclClient? _client;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<int>? _exitFuture;
  bool _processExited = false;

  @override
  ProgrammingBackendSelection get selection =>
      bundled
          ? ProgrammingBackendSelection.bundledOpenocd
          : ProgrammingBackendSelection.externalOpenocd;

  @override
  String get displayName => bundled ? '内置 OpenOCD' : '外置 OpenOCD';

  @override
  bool get isConnected =>
      _process != null && _client != null && !_processExited;

  @override
  Stream<String> get output => _outputController.stream;

  Future<String?> _findExecutable(FlashConnectionConfig config) async {
    if (bundled) return BundledOpenOcdRuntime().ensureReady();
    return findRttExecutable(config.openocdExecutablePath, 'openocd.exe');
  }

  bool _configurationComplete(FlashConnectionConfig config) =>
      config.probeKind == FlashProbeKind.cmsisDap &&
      config.openOcdInterfaceConfig.trim().isNotEmpty &&
      config.openOcdTargetConfig.trim().isNotEmpty;

  @override
  Future<bool> isToolAvailable(FlashConnectionConfig config) async =>
      await _findExecutable(config) != null;

  @override
  Future<bool> isAvailable(FlashConnectionConfig config) async {
    // 内置后端一经选择就必须先准备运行时。配置尚未填写时也不能短路，
    // 否则用户需要浏览内置cfg，却因运行时未解压而陷入循环依赖。
    return await isToolAvailable(config) && _configurationComplete(config);
  }

  @override
  Future<void> connect(FlashConnectionConfig config) async {
    if (isConnected) return;
    if (!_configurationComplete(config)) {
      throw const FormatException('OpenOCD需要接口配置和目标配置');
    }
    final executable = await _findExecutable(config);
    if (executable == null) {
      throw StateError(bundled ? '内置OpenOCD不可用' : '未找到外置OpenOCD');
    }
    final port = await reserveRttTcpPort();
    final arguments = <String>[
      '-f',
      config.openOcdInterfaceConfig.trim(),
      '-c',
      'transport select ${config.wireProtocol.value}',
      '-f',
      config.openOcdTargetConfig.trim(),
      '-c',
      'gdb port disabled',
      '-c',
      'telnet port disabled',
      '-c',
      'tcl port $port',
      '-c',
      'adapter speed ${config.clockKhz}',
      if (config.probeId.trim().isNotEmpty) ...[
        '-c',
        'adapter serial ${config.probeId.trim()}',
      ],
      '-c',
      'init',
    ];
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    _process = process;
    _processExited = false;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen(_outputController.add);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(_outputController.add);
    _exitFuture = process.exitCode.then((code) {
      _processExited = true;
      return code;
    });
    try {
      // Socket所有权立即移交给_ProgrammingTclClient。
      // ignore: close_sinks
      final socket = await _connectTcl(port, process.exitCode);
      _client = _ProgrammingTclClient(socket);
      await _execute('capture "targets"');
    } catch (_) {
      await forceTerminate();
      rethrow;
    }
  }

  Future<Socket> _connectTcl(int port, Future<int> exitCode) async {
    Object? lastError;
    for (var attempt = 0; attempt < 80; attempt++) {
      try {
        // Socket所有权交给_ProgrammingTclClient，并在后端断开时关闭。
        // ignore: close_sinks
        return await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 200),
        );
      } catch (error) {
        lastError = error;
        final exited = await Future.any<Object?>([
          exitCode.then<Object?>((code) => code),
          Future<Object?>.delayed(const Duration(milliseconds: 50)),
        ]);
        if (exited is int) {
          throw StateError('OpenOCD在编程服务就绪前退出，代码$exited');
        }
      }
    }
    throw TimeoutException('连接OpenOCD Tcl服务超时：$lastError');
  }

  Future<String> _execute(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = _client ?? (throw StateError('OpenOCD编程会话未连接'));
    final response = await client.execute(command, timeout: timeout);
    if (RegExp(
      r'(^|\n)(error|invalid command|unknown command)|not examined|could not|failed',
      caseSensitive: false,
    ).hasMatch(response)) {
      throw StateError('OpenOCD命令失败：$response');
    }
    return response;
  }

  @override
  Future<void> program(
    FlashProgramRequest request,
    FlashProgressCallback onProgress,
  ) async {
    request.validate();
    if (!await File(request.filePath).exists()) {
      throw const FileSystemException('待烧写文件不存在');
    }
    onProgress(0.1, '复位并停止目标');
    await _execute('reset init');
    onProgress(0.25, request.erase ? '擦除并烧写文件' : '烧写文件');
    final type = request.isBinary ? ' bin' : '';
    final offset =
        request.isBinary ? ' 0x${request.binAddress!.toRadixString(16)}' : '';
    await _execute(
      buildOpenOcdWriteImageCommand(request),
      timeout: const Duration(minutes: 10),
    );
    if (request.verify) {
      onProgress(0.75, '校验文件');
      await _execute(
        'verify_image ${quoteOpenOcdTclPath(request.filePath)}$offset$type',
        timeout: const Duration(minutes: 5),
      );
    }
    if (request.keepHalted) {
      onProgress(0.95, '保持停止');
      await _execute('halt');
    } else {
      onProgress(0.95, '复位并运行');
      await _execute('reset run');
    }
    onProgress(1, '完成');
  }

  @override
  Future<void> erase(
    FlashEraseRequest request,
    FlashProgressCallback onProgress,
  ) async {
    onProgress(0.1, '复位并停止目标');
    await _execute('reset init');
    onProgress(0.25, request.wholeChip ? '全片擦除' : '范围擦除');
    if (request.wholeChip) {
      await _execute(
        'set banks [flash list]; '
        'for {set i 0} {\$i < [llength \$banks]} {incr i} '
        '{flash erase_sector \$i 0 last}',
        timeout: const Duration(minutes: 5),
      );
    } else {
      await _execute(
        'flash erase_address 0x${request.address!.toRadixString(16)} '
        '0x${request.length!.toRadixString(16)}',
        timeout: const Duration(minutes: 5),
      );
    }
    await _execute('halt');
    onProgress(1, '擦除完成，目标保持停止');
  }

  @override
  Future<void> read(
    FlashReadRequest request,
    FlashProgressCallback onProgress,
  ) async {
    final state = await _execute('capture "targets"');
    final wasHalted = RegExp(
      r'\bhalted\b',
      caseSensitive: false,
    ).hasMatch(state);
    if (!wasHalted) await _execute('halt');
    try {
      onProgress(0.2, '读取目标内存');
      await _execute(
        'dump_image ${quoteOpenOcdTclPath(request.outputPath)} '
        '0x${request.address.toRadixString(16)} '
        '0x${request.length.toRadixString(16)}',
        timeout: const Duration(minutes: 10),
      );
      onProgress(1, '读取完成');
    } finally {
      if (!wasHalted && isConnected) await _execute('resume');
    }
  }

  @override
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.execute('shutdown', timeout: const Duration(seconds: 2));
      } catch (_) {}
      await client.close();
    }
    final process = _process;
    _process = null;
    if (process != null) {
      await process.stdin.close();
      try {
        await (_exitFuture ?? process.exitCode).timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {
        process.kill();
      }
    }
    await _cancelSubscriptions();
    await _closeOutput();
  }

  @override
  Future<void> forceTerminate() async {
    final client = _client;
    _client = null;
    await client?.close();
    _process?.kill();
    await _process?.stdin.close();
    _process = null;
    await _cancelSubscriptions();
    await _closeOutput();
  }

  Future<void> _closeOutput() async {
    if (_outputClosed) return;
    _outputClosed = true;
    await _outputController.close();
  }

  Future<void> _cancelSubscriptions() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _exitFuture = null;
  }
}

class _ProgrammingTclClient {
  _ProgrammingTclClient(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error, StackTrace stackTrace) {
        _pending?.completeError(error, stackTrace);
        _pending = null;
      },
      onDone: () {
        _pending?.completeError(StateError('OpenOCD Tcl服务已关闭'));
        _pending = null;
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  static const int _maxBufferBytes = 1024 * 1024;
  Completer<String>? _pending;
  Future<void> _tail = Future.value();

  Future<String> execute(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      _buffer.clear();
      final response = Completer<String>();
      _pending = response;
      _socket.add([...utf8.encode(command), 0x1A]);
      await _socket.flush();
      try {
        return await response.future.timeout(timeout);
      } on TimeoutException {
        // Tcl协议没有请求ID；关闭连接，避免迟到响应与下一条命令错配。
        await close();
        rethrow;
      }
    } finally {
      _pending = null;
      release.complete();
    }
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    final end = _buffer.indexOf(0x1A);
    if (end < 0) {
      if (_buffer.length > _maxBufferBytes) _buffer.clear();
      return;
    }
    final value =
        utf8.decode(_buffer.sublist(0, end), allowMalformed: true).trim();
    _buffer.removeRange(0, end + 1);
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(value);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
