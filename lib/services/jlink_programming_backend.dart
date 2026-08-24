import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/models/flash_programming_models.dart';
import 'flash_programming_backend.dart';
import 'rtt_process_backend_base.dart';

String buildJLinkLoadFileCommand(FlashProgramRequest request) {
  request.validate();
  final address =
      request.isBinary ? ' 0x${request.binAddress!.toRadixString(16)}' : ' 0';
  return 'LoadFile ${quoteJlinkPath(request.filePath)}$address noreset';
}

class JLinkProgrammingBackend implements FlashProgrammingBackend {
  JLinkProgrammingBackend();

  final _outputController = StreamController<String>.broadcast();
  bool _outputClosed = false;
  _JLinkCommanderSession? _session;

  @override
  ProgrammingBackendSelection get selection =>
      ProgrammingBackendSelection.externalJlink;

  @override
  String get displayName => '外部 J-Link';

  @override
  bool get isConnected => _session != null && !_session!.exited;

  @override
  Stream<String> get output => _outputController.stream;

  Future<String?> _findExecutable(FlashConnectionConfig config) =>
      findRttExecutable(
        config.jlinkExecutablePath,
        'JLink.exe',
        extraDirectories: [
          if (Platform.environment['ProgramFiles'] case final path?)
            '$path\\SEGGER',
          if (Platform.environment['ProgramFiles(x86)'] case final path?)
            '$path\\SEGGER',
        ],
      );

  @override
  Future<bool> isToolAvailable(FlashConnectionConfig config) async =>
      await _findExecutable(config) != null;

  @override
  Future<bool> isAvailable(FlashConnectionConfig config) async =>
      config.probeKind == FlashProbeKind.jlink &&
      config.target.trim().isNotEmpty &&
      await isToolAvailable(config);

  @override
  Future<void> connect(FlashConnectionConfig config) async {
    if (_session != null) return;
    final executable = await _findExecutable(config);
    if (executable == null) throw StateError('未找到J-Link Commander');
    if (config.target.trim().isEmpty) throw const FormatException('必须填写目标芯片');
    final arguments = <String>[
      '-device',
      config.target.trim(),
      '-if',
      config.wireProtocol == FlashWireProtocol.swd ? 'SWD' : 'JTAG',
      '-speed',
      '${config.clockKhz}',
      '-autoconnect',
      '1',
      if (config.probeId.trim().isNotEmpty) ...[
        '-SelectEmuBySN',
        config.probeId.trim(),
      ],
    ];
    final session = await _JLinkCommanderSession.start(
      executable,
      arguments,
      _outputController.add,
    );
    _session = session;
    final check = await session.execute('IsHalted');
    _throwIfFailed(check, 'J-Link无法确认目标连接');
  }

  @override
  Future<void> program(
    FlashProgramRequest request,
    FlashProgressCallback onProgress,
  ) async {
    request.validate();
    final session = _requireSession();
    if (!await File(request.filePath).exists()) {
      throw const FileSystemException('待烧写文件不存在');
    }
    // LoadFile由J-Link Flash Loader完成必要扇区擦除、写入和默认校验；
    // 不预先执行全片Erase，避免局部镜像破坏无关数据区。
    onProgress(0.35, request.erase ? '擦除相关扇区并烧写文件' : '烧写文件');
    final output = await session.execute(
      buildJLinkLoadFileCommand(request),
      timeout: const Duration(minutes: 10),
    );
    _throwIfFailed(output, 'J-Link烧写失败');
    // J-Link的LoadFile默认包含校验；BIN在用户要求校验时再显式比较一次。
    if (request.verify && request.isBinary) {
      onProgress(0.8, '校验文件');
      final verify = await session.execute(
        'VerifyBin ${quoteJlinkPath(request.filePath)} 0x${request.binAddress!.toRadixString(16)}',
        timeout: const Duration(minutes: 5),
      );
      _throwIfFailed(verify, 'J-Link校验失败');
    }
    onProgress(0.95, request.keepHalted ? '保持停止' : '复位并运行');
    if (request.keepHalted) {
      await session.execute('Halt');
    } else {
      await session.execute('Reset');
      await session.execute('Go');
    }
    onProgress(1, '完成');
  }

  @override
  Future<void> erase(
    FlashEraseRequest request,
    FlashProgressCallback onProgress,
  ) async {
    final session = _requireSession();
    onProgress(0.15, request.wholeChip ? '全片擦除' : '范围擦除');
    final command =
        request.wholeChip
            ? 'Erase noreset'
            : 'Erase 0x${request.address!.toRadixString(16)} '
                '0x${(request.address! + request.length!).toRadixString(16)} noreset';
    final output = await session.execute(
      command,
      timeout: const Duration(minutes: 5),
    );
    _throwIfFailed(output, 'J-Link擦除失败');
    await session.execute('Halt');
    onProgress(1, '擦除完成，目标保持停止');
  }

  @override
  Future<void> read(
    FlashReadRequest request,
    FlashProgressCallback onProgress,
  ) async {
    final session = _requireSession();
    final state = await session.execute('IsHalted');
    final wasHalted =
        RegExp('halted', caseSensitive: false).hasMatch(state) &&
        !RegExp('not halted', caseSensitive: false).hasMatch(state);
    if (!wasHalted) await session.execute('Halt');
    try {
      onProgress(0.2, '读取目标内存');
      final output = await session.execute(
        'SaveBin ${quoteJlinkPath(request.outputPath)} '
        '0x${request.address.toRadixString(16)} 0x${request.length.toRadixString(16)}',
        timeout: const Duration(minutes: 10),
      );
      _throwIfFailed(output, 'J-Link读取失败');
      onProgress(1, '读取完成');
    } finally {
      if (!wasHalted && isConnected) await session.execute('Go');
    }
  }

  void _throwIfFailed(String output, String message) {
    if (RegExp(
      r'\b(error|failed|cannot)\b',
      caseSensitive: false,
    ).hasMatch(output)) {
      throw StateError('$message：${output.trim()}');
    }
  }

  _JLinkCommanderSession _requireSession() =>
      _session ?? (throw StateError('J-Link编程会话未连接'));

  @override
  Future<void> disconnect() async {
    final session = _session;
    _session = null;
    await session?.close();
    await _closeOutput();
  }

  @override
  Future<void> forceTerminate() async {
    final session = _session;
    _session = null;
    await session?.terminate();
    await _closeOutput();
  }

  Future<void> _closeOutput() async {
    if (_outputClosed) return;
    _outputClosed = true;
    await _outputController.close();
  }
}

class _JLinkCommanderSession {
  _JLinkCommanderSession._(this._process, this._onOutput) {
    _stdoutSubscription = _process.stdout.listen(_handleOutput);
    _stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .listen(_onOutput);
    _exitFuture = _process.exitCode.then((code) {
      _exited = true;
      final pending = _pendingPrompt;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('J-Link Commander已退出，代码$code'));
      }
      return code;
    });
  }

  final Process _process;
  final void Function(String) _onOutput;
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  late final Future<int> _exitFuture;
  bool _exited = false;
  final StringBuffer _buffer = StringBuffer();
  static const int _maxBufferChars = 1024 * 1024;
  Completer<String>? _pendingPrompt;
  Future<void> _commandTail = Future.value();

  static Future<_JLinkCommanderSession> start(
    String executable,
    List<String> arguments,
    void Function(String) onOutput,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    final session = _JLinkCommanderSession._(process, onOutput);
    try {
      await session._waitForPrompt().timeout(const Duration(seconds: 20));
      return session;
    } catch (_) {
      await session.terminate();
      rethrow;
    }
  }

  void _handleOutput(List<int> data) {
    final text = utf8.decode(data, allowMalformed: true);
    _onOutput(text);
    _buffer.write(text);
    final content = _buffer.toString();
    final prompt = content.lastIndexOf('J-Link>');
    if (prompt < 0) {
      if (_buffer.length > _maxBufferChars) _buffer.clear();
      return;
    }
    final response = content.substring(0, prompt);
    _buffer
      ..clear()
      ..write(content.substring(prompt + 'J-Link>'.length));
    final pending = _pendingPrompt;
    if (pending != null && !pending.isCompleted) pending.complete(response);
  }

  Future<String> _waitForPrompt() {
    final pending = Completer<String>();
    _pendingPrompt = pending;
    return pending.future.whenComplete(() {
      if (identical(_pendingPrompt, pending)) _pendingPrompt = null;
    });
  }

  bool get exited => _exited;

  Future<String> execute(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final previous = _commandTail;
    final release = Completer<void>();
    _commandTail = release.future;
    await previous;
    try {
      _buffer.clear();
      final response = _waitForPrompt();
      _process.stdin.writeln(command);
      await _process.stdin.flush();
      try {
        return await response.timeout(timeout);
      } on TimeoutException {
        // Commander没有请求ID；超时响应可能被下一条命令误认，必须终止会话。
        await terminate();
        rethrow;
      }
    } finally {
      release.complete();
    }
  }

  Future<void> close() async {
    try {
      _process.stdin.writeln('Exit');
      await _process.stdin.flush();
      await _exitFuture.timeout(const Duration(seconds: 3));
    } catch (_) {
      _process.kill();
    }
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    await _process.stdin.close();
  }

  Future<void> terminate() async {
    _process.kill();
    try {
      await _exitFuture.timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    await _process.stdin.close();
  }
}
