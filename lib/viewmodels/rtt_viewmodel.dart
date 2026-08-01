import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/constants/rtt_configuration.dart';
import '../core/utils/atomic_file.dart';
import '../data/models/probe_connection_config.dart';
import '../services/app_settings.dart';
import '../services/probe_connection_service.dart';
import '../services/shell_stream_decoder.dart';
import '../services/rtt_virtual_terminal_router.dart';
import '../services/terminal_control_filter.dart';

/// RTT Viewer 的多终端显示、重建与双向发送状态。
class RttViewModel extends ChangeNotifier {
  RttViewModel(this.service) {
    final settings = AppSettings();
    _encoding = settings.rttEncoding;
    _displayMode = RttDisplayMode.fromString(settings.rttDisplayMode);
    _timestampEnabled = settings.rttTimestampEnabled;
    _autoScroll = settings.rttAutoScroll;
    _historyLineLimit = settings.rttHistoryLineLimit;
    _fontFamily = settings.rttFontFamily;
    _fontSize = settings.rttFontSize;
    _terminalColors = List.of(settings.rttTerminalColors);
    _terminalLabels = List.of(settings.rttTerminalLabels);
    _decoder = ShellStreamDecoder(_encoding);
    _resetTerminalBuffers();
    _dataSubscription = service.dataAvailable.listen((_) => _scheduleDrain());
    service.addListener(_handleServiceChanged);
  }

  final ProbeConnectionService service;
  final List<String> _lines = [];
  final List<_RttTerminalBuffer> _terminals = [];
  final RttVirtualTerminalRouter _terminalRouter = RttVirtualTerminalRouter();
  final Queue<RttDataChunk> _rawHistory = Queue<RttDataChunk>();
  final Queue<RttDataChunk> _rebuildQueue = Queue<RttDataChunk>();
  late ShellStreamDecoder _decoder;
  StreamSubscription<void>? _dataSubscription;
  Timer? _drainTimer;
  Timer? _rebuildTimer;
  String _partialLine = '';
  int _rawHistoryBytes = 0;
  int _pausedBytes = 0;
  int _pausedLineCount = 0;
  int _lastDroppedBytes = 0;
  int _outputRevision = 0;
  bool _rebuilding = false;
  bool _paused = false;
  late String _encoding;
  late RttDisplayMode _displayMode;
  late bool _timestampEnabled;
  late bool _autoScroll;
  late int _historyLineLimit;
  late String _fontFamily;
  late double _fontSize;
  late List<int> _terminalColors;
  late List<String> _terminalLabels;
  int _selectedTerminal = 0;

  List<String> get lines {
    final source =
        _selectedTerminal < 0 ? _lines : _terminals[_selectedTerminal].lines;
    return List.unmodifiable(
      _paused ? source.take(_pausedLineCount.clamp(0, source.length)) : source,
    );
  }

  String get partialLine =>
      _selectedTerminal < 0 ? '' : _terminals[_selectedTerminal].partialLine;
  bool get paused => _paused;
  int get pausedBytes => _pausedBytes;
  String get encoding => _encoding;
  RttDisplayMode get displayMode => _displayMode;
  bool get timestampEnabled => _timestampEnabled;
  bool get autoScroll => _autoScroll;
  int get historyLineLimit => _historyLineLimit;
  String get fontFamily => _fontFamily;
  double get fontSize => _fontSize;
  int get rawHistoryBytes => _rawHistoryBytes;
  int get outputRevision => _outputRevision;
  bool get rebuilding => _rebuilding;
  int get selectedTerminal => _selectedTerminal;
  bool get allTerminalsSelected => _selectedTerminal < 0;
  bool terminalHasData(int terminal) => _terminals[terminal].hasData;
  int terminalColorValue(int terminal) =>
      _terminalColors[terminal.clamp(0, 15).toInt()];
  String terminalLabel(int terminal) =>
      _terminalLabels[terminal.clamp(0, 15).toInt()];
  bool get canSend =>
      service.activityOwner == ProbeActivityOwner.rttViewer &&
      !allTerminalsSelected &&
      service.canWriteDownChannel0;

  void selectTerminal(int terminal) {
    if (terminal < -1 || terminal > 15 || _selectedTerminal == terminal) return;
    _selectedTerminal = terminal;
    notifyListeners();
  }

  void setTerminalColor(int terminal, int colorValue) {
    if (terminal < 0 || terminal >= _terminalColors.length) return;
    final opaque = 0xFF000000 | (colorValue & 0x00FFFFFF);
    if (_terminalColors[terminal] == opaque) return;
    _terminalColors[terminal] = opaque;
    AppSettings().rttTerminalColors = List.of(_terminalColors);
    unawaited(AppSettings().save());
    notifyListeners();
  }

  void setTerminalAppearance(int terminal, String label, int colorValue) {
    if (terminal < 0 || terminal >= _terminalColors.length) return;
    final normalizedLabel = label.replaceAll(RegExp(r'[\[\]]'), '').trim();
    if (normalizedLabel.isEmpty || normalizedLabel.length > 32) return;
    final opaque = 0xFF000000 | (colorValue & 0x00FFFFFF);
    if (_terminalLabels[terminal] == normalizedLabel &&
        _terminalColors[terminal] == opaque) {
      return;
    }
    _terminalLabels[terminal] = normalizedLabel;
    _terminalColors[terminal] = opaque;
    final settings = AppSettings();
    settings
      ..rttTerminalLabels = List.of(_terminalLabels)
      ..rttTerminalColors = List.of(_terminalColors);
    unawaited(settings.save());
    notifyListeners();
  }

  void _handleServiceChanged() => notifyListeners();

  void _scheduleDrain() {
    if (_drainTimer != null) return;
    _drainTimer = Timer(Duration.zero, _drain);
  }

  void _drain() {
    _drainTimer = null;
    final chunks = service.drainUpTo(RttConfiguration.maxDrainBytesPerFrame);
    var outputChanged = false;
    if (service.droppedBytes > _lastDroppedBytes) {
      final dropped = service.droppedBytes - _lastDroppedBytes;
      _lastDroppedBytes = service.droppedBytes;
      _resetDecoders();
      final warning = '【RTT 接收过载：已丢弃 $dropped 字节，文本解码已重新同步】';
      _appendLine(warning);
      for (final terminal in _terminals) {
        terminal.appendLine(warning, _historyLineLimit);
      }
      outputChanged = true;
    }
    if (chunks.isEmpty) {
      if (outputChanged) {
        _outputRevision++;
        if (!_paused) notifyListeners();
      }
      return;
    }
    var consumed = 0;
    for (final chunk in chunks) {
      consumed += chunk.data.length;
      _retainRaw(chunk);
      if (_rebuilding) {
        _rebuildQueue.add(chunk);
      } else {
        _appendChunk(chunk);
      }
    }
    _outputRevision++;
    if (_paused) {
      _pausedBytes += consumed;
    } else {
      notifyListeners();
    }
    if (service.queuedBytes > 0) {
      _drainTimer = Timer(const Duration(milliseconds: 16), _drain);
    }
  }

  void _retainRaw(RttDataChunk chunk) {
    _rawHistory.add(chunk);
    _rawHistoryBytes += chunk.data.length;
    while (_rawHistoryBytes > RttConfiguration.rawHistoryLimitBytes &&
        _rawHistory.isNotEmpty) {
      _rawHistoryBytes -= _rawHistory.removeFirst().data.length;
    }
  }

  void _appendChunk(RttDataChunk chunk) {
    for (final segment in _terminalRouter.add(chunk.data)) {
      _appendTerminalSegment(segment, chunk.wallClockUs);
    }
  }

  void _appendTerminalSegment(RttTerminalSegment segment, int wallClockUs) {
    final terminal = _terminals[segment.terminal];
    terminal.hasData = true;
    if (_displayMode == RttDisplayMode.hex) {
      final hex = segment.data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final line = _withTimestamp(hex, wallClockUs);
      terminal.appendLine(line, _historyLineLimit);
      _appendLine('[Terminal ${segment.terminal}] $line');
      return;
    }
    final decoded = terminal.decoder.add(segment.data);
    final text = terminal.controlFilter.add(decoded);
    if (text.isEmpty) return;
    final completedLines = terminal.addText(text);
    for (final complete in completedLines) {
      final line = _withTimestamp(complete, wallClockUs);
      terminal.appendLine(line, _historyLineLimit);
      _appendLine('[Terminal ${segment.terminal}] $line');
    }
  }

  String _withTimestamp(String text, int wallClockUs) {
    if (!_timestampEnabled) return text;
    final time = DateTime.fromMicrosecondsSinceEpoch(wallClockUs);
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '[${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${three(time.millisecond)}] $text';
  }

  void _appendLine(String line) {
    _lines.add(line);
    final excess = _lines.length - _historyLineLimit;
    if (excess > 0) _lines.removeRange(0, excess);
  }

  void togglePaused() {
    _paused = !_paused;
    if (_paused) {
      _pausedLineCount =
          _selectedTerminal < 0
              ? _lines.length
              : _terminals[_selectedTerminal].lines.length;
    } else {
      _pausedBytes = 0;
      _pausedLineCount = 0;
    }
    notifyListeners();
  }

  void clear() {
    // 清空必须覆盖显示内容、原始重建历史和服务层待处理队列，否则设置页
    // 的 RTT 内存占用仍会包含尚未排空的数据，并可能在下一帧重新出现。
    _drainTimer?.cancel();
    _drainTimer = null;
    service.clearBufferedData();
    _lines.clear();
    for (final terminal in _terminals) {
      terminal.clear(_encoding);
    }
    _terminalRouter.reset();
    _rawHistory.clear();
    _rebuildQueue.clear();
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    _rebuilding = false;
    _rawHistoryBytes = 0;
    _partialLine = '';
    _pausedBytes = 0;
    _pausedLineCount = 0;
    _lastDroppedBytes = 0;
    _resetDecoders();
    _outputRevision++;
    notifyListeners();
  }

  void setEncoding(String value) {
    if (_encoding == value) return;
    _encoding = value;
    AppSettings().rttEncoding = value;
    unawaited(AppSettings().save());
    _rebuildFromRawHistory();
  }

  void setDisplayMode(RttDisplayMode value) {
    if (_displayMode == value) return;
    _displayMode = value;
    AppSettings().rttDisplayMode = value.value;
    unawaited(AppSettings().save());
    _rebuildFromRawHistory();
  }

  void setTimestampEnabled(bool value) {
    if (_timestampEnabled == value) return;
    _timestampEnabled = value;
    AppSettings().rttTimestampEnabled = value;
    unawaited(AppSettings().save());
    _rebuildFromRawHistory();
  }

  void setAutoScroll(bool value) {
    _autoScroll = value;
    AppSettings().rttAutoScroll = value;
    unawaited(AppSettings().save());
    notifyListeners();
  }

  void setFontFamily(String value) {
    _fontFamily = value;
    AppSettings().rttFontFamily = value;
    unawaited(AppSettings().save());
    notifyListeners();
  }

  void setFontSize(double value) {
    _fontSize = value.clamp(10, 24).toDouble();
    AppSettings().rttFontSize = _fontSize;
    unawaited(AppSettings().save());
    notifyListeners();
  }

  void setHistoryLineLimit(int value) {
    _historyLineLimit =
        value
            .clamp(
              RttConfiguration.minHistoryLines,
              RttConfiguration.maxHistoryLines,
            )
            .toInt();
    AppSettings().rttHistoryLineLimit = _historyLineLimit;
    unawaited(AppSettings().save());
    if (_lines.length > _historyLineLimit) {
      _lines.removeRange(0, _lines.length - _historyLineLimit);
    }
    for (final terminal in _terminals) {
      terminal.trim(_historyLineLimit);
    }
    notifyListeners();
  }

  void _rebuildFromRawHistory() {
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    _rebuildQueue
      ..clear()
      ..addAll(_rawHistory);
    // 编码、显示模式或时间戳变化时，所有可见文本都必须从原始字节唯一重放。
    // 过去这里只清空 All Terminals 汇总，单终端已完成行仍被保留，导致每次
    // 切换时间戳都会把同一段历史再次追加到单终端中。
    _lines.clear();
    _partialLine = '';
    _decoder.reset(encoding: _encoding);
    _terminalRouter.reset();
    for (final terminal in _terminals) {
      terminal.clear(_encoding);
    }
    _rebuilding = true;
    _scheduleRebuildBatch();
    notifyListeners();
  }

  void _scheduleRebuildBatch() {
    if (_rebuildTimer != null) return;
    _rebuildTimer = Timer(Duration.zero, _processRebuildBatch);
  }

  void _processRebuildBatch() {
    _rebuildTimer = null;
    var processed = 0;
    while (_rebuildQueue.isNotEmpty &&
        processed < RttConfiguration.maxDrainBytesPerFrame) {
      final chunk = _rebuildQueue.removeFirst();
      processed += chunk.data.length;
      _appendChunk(chunk);
    }
    _outputRevision++;
    if (!_paused) notifyListeners();
    if (_rebuildQueue.isEmpty) {
      _rebuilding = false;
      return;
    }
    _rebuildTimer = Timer(
      const Duration(milliseconds: 16),
      _processRebuildBatch,
    );
  }

  Future<void> exportText(String path) async {
    const committer = AtomicFileCommitter();
    final part = File(committer.partPath(path));
    await part.parent.create(recursive: true);
    if (await part.exists()) await part.delete();
    final output = part.openWrite();
    var closed = false;
    var firstLine = true;
    var bufferedCharacters = 0;
    final buffer = StringBuffer();

    Future<void> flushBuffer() async {
      if (bufferedCharacters == 0) return;
      output.write(buffer.toString());
      buffer.clear();
      bufferedCharacters = 0;
      // 定期让出事件循环并把数据下推到文件系统，避免大历史导出时卡住界面。
      await output.flush();
    }

    void appendLine(String line) {
      if (!firstLine) {
        buffer.write('\r\n');
        bufferedCharacters += 2;
      }
      buffer.write(line);
      bufferedCharacters += line.length;
      firstLine = false;
    }

    try {
      for (final line in _lines) {
        appendLine(line);
        if (bufferedCharacters >= 256 * 1024) await flushBuffer();
      }
      if (_partialLine.isNotEmpty) appendLine(_partialLine);
      await flushBuffer();
      await output.close();
      closed = true;
      await committer.commitPart(path);
    } catch (_) {
      if (!closed) await output.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  Future<void> sendText(String value, {String lineEnding = '\r\n'}) async {
    if (!canSend) throw StateError('当前终端不可发送');
    await service.writeDownChannel0(
      encodeShellText(value + lineEnding, _encoding),
    );
  }

  Future<void> sendHex(String value) async {
    if (!canSend) throw StateError('当前终端不可发送');
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length.isOdd) {
      throw const FormatException('HEX 数据必须包含完整字节');
    }
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
      throw const FormatException('HEX 数据只能包含 0-9、A-F');
    }
    final bytes = Uint8List(compact.length ~/ 2);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = int.parse(
        compact.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    await service.writeDownChannel0(bytes);
  }

  void _resetTerminalBuffers() {
    _terminals
      ..clear()
      ..addAll(List.generate(16, (_) => _RttTerminalBuffer(_encoding)));
  }

  void _resetDecoders() {
    _decoder.reset(encoding: _encoding);
    _terminalRouter.reset();
    for (final terminal in _terminals) {
      terminal.resetDecoder(_encoding);
    }
  }

  Future<void> exportBinary(String path) async {
    const committer = AtomicFileCommitter();
    final part = File(committer.partPath(path));
    await part.parent.create(recursive: true);
    if (await part.exists()) await part.delete();
    final output = part.openWrite();
    var closed = false;
    try {
      for (final chunk in _rawHistory) {
        output.add(chunk.data);
      }
      await output.flush();
      await output.close();
      closed = true;
      await committer.commitPart(path);
    } catch (_) {
      if (!closed) await output.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  @override
  void dispose() {
    service.removeListener(_handleServiceChanged);
    _drainTimer?.cancel();
    _rebuildTimer?.cancel();
    unawaited(_dataSubscription?.cancel());
    super.dispose();
  }
}

class _RttTerminalBuffer {
  _RttTerminalBuffer(String encoding) : decoder = ShellStreamDecoder(encoding);

  final List<String> lines = [];
  ShellStreamDecoder decoder;
  final TerminalControlFilter controlFilter = TerminalControlFilter();
  String partialLine = '';
  int _cursorOffset = 0;
  bool hasData = false;

  List<String> addText(String text) {
    final completed = <String>[];
    for (final codePoint in text.runes) {
      switch (codePoint) {
        case 0x0a:
          completed.add(partialLine);
          partialLine = '';
          _cursorOffset = 0;
        case 0x0d:
          _cursorOffset = 0;
        case 0x08:
          if (_cursorOffset > 0) {
            _cursorOffset--;
            if (_cursorOffset > 0 &&
                _isLowSurrogate(partialLine.codeUnitAt(_cursorOffset)) &&
                _isHighSurrogate(partialLine.codeUnitAt(_cursorOffset - 1))) {
              _cursorOffset--;
            }
          }
        case 0x09:
          final spaces = 8 - (_cursorOffset % 8);
          for (var index = 0; index < spaces; index++) {
            _writeCodePoint(0x20);
          }
        default:
          if (codePoint >= 0x20) _writeCodePoint(codePoint);
      }
    }
    return completed;
  }

  void _writeCodePoint(int codePoint) {
    final value = String.fromCharCode(codePoint);
    if (_cursorOffset < partialLine.length) {
      var replacedEnd = _cursorOffset + 1;
      if (_isHighSurrogate(partialLine.codeUnitAt(_cursorOffset)) &&
          replacedEnd < partialLine.length &&
          _isLowSurrogate(partialLine.codeUnitAt(replacedEnd))) {
        replacedEnd++;
      }
      partialLine = partialLine.replaceRange(_cursorOffset, replacedEnd, value);
    } else {
      if (_cursorOffset > partialLine.length) {
        partialLine += ' ' * (_cursorOffset - partialLine.length);
      }
      partialLine += value;
    }
    _cursorOffset += value.length;
  }

  bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;

  bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;

  void appendLine(String value, int limit) {
    lines.add(value);
    trim(limit);
  }

  void trim(int limit) {
    final excess = lines.length - limit;
    if (excess > 0) lines.removeRange(0, excess);
  }

  void resetDecoder(String encoding) {
    decoder.reset(encoding: encoding);
    controlFilter.reset();
    partialLine = '';
    _cursorOffset = 0;
  }

  void clear(String encoding) {
    lines.clear();
    hasData = false;
    resetDecoder(encoding);
  }
}
