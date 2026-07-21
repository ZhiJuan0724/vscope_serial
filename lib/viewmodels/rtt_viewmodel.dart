import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/constants/rtt_configuration.dart';
import '../core/utils/atomic_file.dart';
import '../data/models/rtt_config.dart';
import '../services/app_settings.dart';
import '../services/rtt_service.dart';
import '../services/shell_stream_decoder.dart';

/// RTT Up 0 只读查看状态。
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
    _decoder = ShellStreamDecoder(_encoding);
    _dataSubscription = service.dataAvailable.listen((_) => _scheduleDrain());
    service.addListener(_handleServiceChanged);
  }

  final RttService service;
  final List<String> _lines = [];
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
  String _pausedPartialLine = '';
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

  List<String> get lines =>
      List.unmodifiable(_paused ? _lines.take(_pausedLineCount) : _lines);
  String get partialLine => _paused ? _pausedPartialLine : _partialLine;
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
      _decoder.reset(encoding: _encoding);
      _partialLine = '';
      _appendLine('【RTT 接收过载：已丢弃 $dropped 字节，文本解码已重新同步】');
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
    if (_displayMode == RttDisplayMode.hex) {
      final hex = chunk.data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      _appendLine(_withTimestamp(hex, chunk.wallClockUs));
      return;
    }
    final text = _decoder.add(chunk.data);
    if (text.isEmpty) return;
    final parts = text.split('\n');
    for (var index = 0; index < parts.length - 1; index++) {
      final complete = '$_partialLine${parts[index]}'.replaceAll('\r', '');
      _partialLine = '';
      _appendLine(_withTimestamp(complete, chunk.wallClockUs));
    }
    _partialLine += parts.last;
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
      _pausedLineCount = _lines.length;
      _pausedPartialLine = _partialLine;
    } else {
      _pausedBytes = 0;
      _pausedLineCount = 0;
      _pausedPartialLine = '';
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
    _rawHistory.clear();
    _rebuildQueue.clear();
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    _rebuilding = false;
    _rawHistoryBytes = 0;
    _partialLine = '';
    _pausedBytes = 0;
    _pausedLineCount = 0;
    _pausedPartialLine = '';
    _lastDroppedBytes = 0;
    _decoder.reset(encoding: _encoding);
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
    notifyListeners();
  }

  void _rebuildFromRawHistory() {
    _rebuildTimer?.cancel();
    _rebuildQueue
      ..clear()
      ..addAll(_rawHistory);
    _lines.clear();
    _partialLine = '';
    _decoder = ShellStreamDecoder(_encoding);
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

  Future<void> exportText(String path) {
    final content = <String>[
      ..._lines,
      if (_partialLine.isNotEmpty) _partialLine,
    ].join('\r\n');
    return const AtomicFileCommitter().writeString(path, content);
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
