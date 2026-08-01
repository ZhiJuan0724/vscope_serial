import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../core/utils/atomic_file.dart';
import '../core/utils/crc.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/retention_usage.dart';
import 'app_notifications.dart';
import 'shell_stream_decoder.dart';
import 'time_window_aggregator.dart';

typedef RawExportProgressCallback = void Function(double progress);

/// 原始接收页面的一次内存会话。
///
/// 本类唯一拥有完整字节、文本显示缓存、流式解码状态和自动换行窗口。
/// 串口连接与活动所有权由上层服务管理，并通过回调接收容量停止事件。
class RawReceiveSession {
  RawReceiveSession({
    required void Function() onChanged,
    required void Function() onRetentionLimitReached,
  }) : _onChanged = onChanged,
       _onRetentionLimitReached = onRetentionLimitReached;

  static const int rawRetentionLimitBytes = 512 * 1024 * 1024;
  static const int textDisplayCacheLimitBytes = 128 * 1024 * 1024;
  static const int minDisplayLineLimit = 100;
  static const int defaultDisplayLineLimit = 100000;
  static const int maxDisplayLineLimit = 100000;
  static const int minAutoLineBreakIntervalMs = 1;
  static const int defaultAutoLineBreakIntervalMs = 100;
  static const int maxAutoLineBreakIntervalMs = 10000;

  static const double _retentionWarningRatio = 0.8;
  static const int _maxTextLineLength = 4096;
  static const int _maxAutoLineBreakBufferBytes = 64 * 1024;

  final void Function() _onChanged;
  final void Function() _onRetentionLimitReached;
  final ChunkedByteBuffer _rawBytes = ChunkedByteBuffer();
  final _CircularStringList _receivedLines = _CircularStringList();
  final ShellStreamDecoder _textDecoder = ShellStreamDecoder('UTF-8');

  TimeWindowAggregator? _aggregator;
  Timer? _displayNotifyTimer;
  DateTime? _lastTextTimestamp;
  int _receivedTextBytes = 0;
  int _displayRevision = 0;
  bool _displayBatchHasTrim = false;
  int _displayTrimRevision = 0;
  List<String> _lastTrimmedDisplayLines = <String>[];
  String _pendingReceiveText = '';
  int? _pendingReceiveLineIndex;
  String _pendingReceiveLinePrefix = '';
  String _pendingSendText = '';
  int? _pendingSendLineIndex;
  String _pendingSendLinePrefix = '';
  int _displayLineLimit = defaultDisplayLineLimit;
  bool _retentionWarningShown = false;
  bool _retentionLimitShown = false;

  bool receiveHex = false;
  bool showTimestamp = false;
  bool autoLineBreak = true;
  int autoLineBreakIntervalMs = defaultAutoLineBreakIntervalMs;
  String textEncoding = 'UTF-8';
  int? debugRetentionLimitBytes;

  List<String> get receivedLines => _receivedLines;
  int get displayRevision => _displayRevision;
  int get displayTrimRevision => _displayTrimRevision;
  List<String> get lastTrimmedDisplayLines => _lastTrimmedDisplayLines;
  int get displayLineLimit => _displayLineLimit;
  int get textDisplayCacheBytes => _receivedTextBytes;
  bool get hasRawData => _rawBytes.isNotEmpty;

  int get _retentionLimitBytes =>
      debugRetentionLimitBytes ?? rawRetentionLimitBytes;

  RetentionUsage get retentionUsage {
    final limit = _retentionLimitBytes;
    final ratio = limit <= 0 ? 0.0 : _rawBytes.length / limit;
    final state =
        _rawBytes.length >= limit
            ? RetentionState.limitReached
            : ratio >= _retentionWarningRatio
            ? RetentionState.warning
            : RetentionState.normal;
    return RetentionUsage(
      usedBytes: _rawBytes.length,
      limitBytes: limit,
      state: state,
    );
  }

  /// 在容量内追加完整原始字节，并返回实际接受的前缀。
  Uint8List appendRawBytes(Uint8List data, {required bool stopAtLimit}) {
    if (data.isEmpty) return data;
    final limit = _retentionLimitBytes;
    final remaining = (limit - _rawBytes.length).clamp(0, limit);
    final acceptedLength = data.length.clamp(0, remaining).toInt();
    final accepted =
        acceptedLength == data.length
            ? data
            : Uint8List.sublistView(data, 0, acceptedLength);
    if (accepted.isNotEmpty) _rawBytes.append(accepted);

    final usage = retentionUsage;
    if (!_retentionWarningShown && usage.ratio >= _retentionWarningRatio) {
      _retentionWarningShown = true;
      final message =
          '原始数据已使用 ${(usage.ratio * 100).clamp(0, 100).toStringAsFixed(0)}%，'
          '达到 ${_formatByteSize(usage.limitBytes)} 后将自动停止接收';
      AppLogger().warning(message, category: 'DATA');
      AppNotifications.show(message);
    }

    if (usage.state == RetentionState.limitReached && !_retentionLimitShown) {
      _retentionLimitShown = true;
      final message =
          '原始数据已达到 ${_formatByteSize(usage.limitBytes)} 上限，'
          '${stopAtLimit ? '已自动停止接收' : '后续传输不再写入原始追踪'}';
      AppLogger().warning(message, category: 'DATA');
      AppNotifications.show(message);
      if (stopAtLimit) _onRetentionLimitReached();
    }
    _onChanged();
    return accepted;
  }

  void addReceivedData(Uint8List data, DateTime timestamp) {
    _addRawDataLine(timestamp, data);
  }

  void feedReceivedData(
    Uint8List data,
    DateTime timestamp, {
    int? monotonicUs,
  }) {
    // 自动换行关闭时保留每个原生数据包的边界；开启时由单调时间窗口合并。
    if (!autoLineBreak) {
      _addRawDataLine(timestamp, data);
      return;
    }
    _aggregator ??= TimeWindowAggregator(
      idleTimeoutUs:
          autoLineBreakIntervalMs * Duration.microsecondsPerMillisecond,
      maxBufferBytes: _maxAutoLineBreakBufferBytes,
      onWindowComplete: (windowTimestamp, bytes) {
        _addRawDataLine(windowTimestamp, bytes);
        if (!receiveHex) _finishPendingReceiveLine();
      },
    );
    _aggregator!.feed(
      data,
      monotonicUs ?? timestamp.microsecondsSinceEpoch,
      timestamp,
    );
  }

  void addSendData(
    Uint8List data, {
    required String decodedText,
    required bool displayAsHex,
    required bool isPlot,
  }) {
    if (displayAsHex) {
      final text = data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final prefix = _sendLinePrefix(DateTime.now(), isPlot: isPlot);
      final hexMark = !receiveHex ? '[HEX] ' : '';
      _addDisplayLine('$prefix$hexMark$text (${data.length} bytes)');
      return;
    }
    _addTextDataLines(
      decodedText,
      timestamp: DateTime.now(),
      isReceive: false,
      isPlot: isPlot,
    );
  }

  void flushAutoLineBreak() {
    // 超时换行只处理当前未完成窗口，设备明确发送的 \n 仍会即时分行。
    _aggregator?.flush();
    _aggregator = null;
  }

  void flushTextDecoder() {
    // 停止接收时冲刷跨包多字节字符，避免最后一个字符永久滞留在解码器中。
    if (receiveHex) {
      _textDecoder.reset(encoding: textEncoding);
      return;
    }
    final text = _textDecoder.flush();
    if (text.isNotEmpty) {
      _addTextDataLines(
        text,
        timestamp: _lastTextTimestamp ?? DateTime.now(),
        isReceive: true,
      );
    }
    _lastTextTimestamp = null;
  }

  bool setReceiveHex(bool value) {
    if (receiveHex == value) return false;
    flushAutoLineBreak();
    receiveHex = value;
    // 显示格式切换不能把旧编码残留拼接到新模式。
    _textDecoder.reset(encoding: textEncoding);
    _resetTextLineBuffers();
    return true;
  }

  bool setTextEncoding(String encoding) {
    if (textEncoding == encoding) return false;
    textEncoding = encoding;
    _textDecoder.reset(encoding: encoding);
    _resetTextLineBuffers();
    return true;
  }

  bool setShowTimestamp(bool value) {
    if (showTimestamp == value) return false;
    flushAutoLineBreak();
    showTimestamp = value;
    _resetTextLineBuffers();
    return true;
  }

  bool setAutoLineBreak(bool value) {
    if (autoLineBreak == value) return false;
    flushAutoLineBreak();
    autoLineBreak = value;
    return true;
  }

  bool setAutoLineBreakIntervalMs(int milliseconds) {
    final next = milliseconds.clamp(
      minAutoLineBreakIntervalMs,
      maxAutoLineBreakIntervalMs,
    );
    if (autoLineBreakIntervalMs == next) return false;
    flushAutoLineBreak();
    autoLineBreakIntervalMs = next;
    return true;
  }

  bool setDisplayLineLimit(int value) {
    final next = value.clamp(minDisplayLineLimit, maxDisplayLineLimit).toInt();
    if (next == _displayLineLimit) return false;
    _displayLineLimit = next;
    _beginDisplayMutation();
    _trimDisplayLines();
    _scheduleDisplayNotify();
    return true;
  }

  void clear() {
    // 清屏同时重置显示、导出字节和解码残留，避免新会话继承半个字符或半行。
    _aggregator?.reset();
    _aggregator = null;
    _rawBytes.clear();
    _retentionWarningShown = false;
    _retentionLimitShown = false;
    _receivedLines.clear();
    _receivedTextBytes = 0;
    _textDecoder.reset(encoding: textEncoding);
    _lastTextTimestamp = null;
    _resetTextLineBuffers();
    _onChanged();
  }

  Map<String, String> get dataStats {
    final retention = retentionUsage;
    return <String, String>{
      '显示行数': '${receivedLines.length} / $_displayLineLimit',
      '显示文本缓存': '${(_receivedTextBytes / 1024 / 1024).toStringAsFixed(2)} MB',
      '完整原始数据':
          '${_rawBytes.length} B (${(_rawBytes.length / 1024 / 1024).toStringAsFixed(2)} MB)',
      '原始数据容量':
          '${(retention.ratio * 100).clamp(0, 100).toStringAsFixed(1)}% / '
          '${_formatByteSize(retention.limitBytes)}',
      '文本导出编码': textEncoding,
    };
  }

  Future<String?> exportAsText({
    Directory? outputDirectory,
    RawExportProgressCallback? onProgress,
  }) async {
    if (!hasRawData) {
      AppLogger().warning('没有原始接收数据，已取消文本导出', category: 'DATA');
      return null;
    }
    String? partPath;
    try {
      onProgress?.call(0.05);
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = outputDirectory ?? Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.txt';
      const committer = AtomicFileCommitter();
      partPath = committer.partPath(path);
      final file = File(partPath);
      if (await file.exists()) await file.delete();
      final exportEncoding = textEncoding;
      await _exportTextStreaming(file, exportEncoding, onProgress);
      await committer.commitPart(path);
      partPath = null;
      onProgress?.call(1);
      AppLogger().info(
        '已导出完整接收文本: $path，编码=$exportEncoding，原始字节=${_rawBytes.length}',
        category: 'DATA',
      );
      return path;
    } catch (error) {
      await _deleteExportPart(partPath);
      AppLogger().error('导出失败: $error', category: 'DATA');
      return null;
    }
  }

  Future<String?> exportAsRawBytes({
    Directory? outputDirectory,
    RawExportProgressCallback? onProgress,
  }) async {
    if (!hasRawData) {
      AppLogger().warning('没有原始接收数据，已取消BIN导出', category: 'DATA');
      return null;
    }
    String? partPath;
    try {
      onProgress?.call(0.05);
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = outputDirectory ?? Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.bin';
      const committer = AtomicFileCommitter();
      partPath = committer.partPath(path);
      final file = File(partPath);
      if (await file.exists()) await file.delete();
      await _exportRawBytesStreaming(file, onProgress);
      await committer.commitPart(path);
      partPath = null;
      onProgress?.call(1);
      AppLogger().info('已导出原始字节: $path', category: 'DATA');
      return path;
    } catch (error) {
      await _deleteExportPart(partPath);
      AppLogger().error('导出失败: $error', category: 'DATA');
      return null;
    }
  }

  void dispose() {
    _displayNotifyTimer?.cancel();
    _displayNotifyTimer = null;
    _aggregator?.reset();
    _aggregator = null;
  }

  void _addRawDataLine(DateTime timestamp, Uint8List data) {
    if (receiveHex) {
      final text = data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final prefix = showTimestamp ? '← [${_formatTimestamp(timestamp)}] ' : '';
      _addDisplayLine('$prefix$text (${data.length} bytes)');
      return;
    }
    _lastTextTimestamp = timestamp;
    _addTextDataLines(
      _textDecoder.add(data),
      timestamp: timestamp,
      isReceive: true,
    );
  }

  void _finishPendingReceiveLine() {
    _pendingReceiveText = '';
    _pendingReceiveLineIndex = null;
    _pendingReceiveLinePrefix = '';
  }

  void _addTextDataLines(
    String text, {
    required DateTime timestamp,
    required bool isReceive,
    bool isPlot = false,
  }) {
    if (text.isEmpty) return;

    final prefix =
        isReceive
            ? (showTimestamp ? '← [${_formatTimestamp(timestamp)}] ' : '')
            : _sendLinePrefix(timestamp, isPlot: isPlot);
    var pendingText = isReceive ? _pendingReceiveText : _pendingSendText;
    var pendingIndex =
        isReceive ? _pendingReceiveLineIndex : _pendingSendLineIndex;
    var pendingPrefix =
        isReceive ? _pendingReceiveLinePrefix : _pendingSendLinePrefix;
    if (!isReceive && pendingPrefix != prefix) {
      pendingText = '';
      pendingIndex = null;
      pendingPrefix = '';
    }

    void savePending() {
      if (isReceive) {
        _pendingReceiveText = pendingText;
        _pendingReceiveLineIndex = pendingIndex;
        _pendingReceiveLinePrefix = pendingPrefix;
      } else {
        _pendingSendText = pendingText;
        _pendingSendLineIndex = pendingIndex;
        _pendingSendLinePrefix = pendingPrefix;
      }
    }

    void ensureLine() {
      if (pendingIndex != null &&
          pendingIndex! >= 0 &&
          pendingIndex! < receivedLines.length) {
        return;
      }
      pendingPrefix = prefix;
      pendingIndex = _addDisplayLine(pendingPrefix);
    }

    void updateLine() {
      ensureLine();
      _updateDisplayLine(pendingIndex!, '$pendingPrefix$pendingText');
    }

    for (var index = 0; index < text.length; index++) {
      final codeUnit = text.codeUnitAt(index);
      if (codeUnit == 13 || codeUnit == 10) {
        updateLine();
        pendingText = '';
        pendingIndex = null;
        pendingPrefix = '';
        if (codeUnit == 13 &&
            index + 1 < text.length &&
            text.codeUnitAt(index + 1) == 10) {
          index++;
        }
      } else {
        pendingText += text[index];
        if (pendingText.length >= _maxTextLineLength) {
          updateLine();
          pendingText = '';
          pendingIndex = null;
          pendingPrefix = '';
        }
      }
    }

    if (pendingText.isNotEmpty) updateLine();
    savePending();
  }

  String _sendLinePrefix(DateTime timestamp, {required bool isPlot}) {
    final buffer = StringBuffer();
    if (showTimestamp) {
      buffer.write('→ [${_formatTimestamp(timestamp)}] ');
    }
    if (isPlot) buffer.write('[绘图发送] ');
    return buffer.toString();
  }

  int _addDisplayLine(String line) {
    _beginDisplayMutation();
    _receivedLines.add(line);
    _receivedTextBytes += line.length * 2;
    _trimDisplayLines();
    _scheduleDisplayNotify();
    return _receivedLines.length - 1;
  }

  void _updateDisplayLine(int index, String line) {
    if (index < 0 || index >= _receivedLines.length) return;
    _beginDisplayMutation();
    final oldLine = _receivedLines[index];
    _receivedLines[index] = line;
    _receivedTextBytes += (line.length - oldLine.length) * 2;
    _trimDisplayLines();
    _scheduleDisplayNotify();
  }

  void _trimDisplayLines() {
    while (_receivedTextBytes > textDisplayCacheLimitBytes &&
        _receivedLines.isNotEmpty) {
      _removeFirstDisplayLine();
    }
    while (_receivedLines.length > _displayLineLimit) {
      _removeFirstDisplayLine();
    }
  }

  void _removeFirstDisplayLine() {
    final removed = _receivedLines.removeFirst();
    _receivedTextBytes -= removed.length * 2;
    _recordTrimmedDisplayLine(removed);
    _pendingReceiveLineIndex = _shiftPendingIndex(_pendingReceiveLineIndex);
    _pendingSendLineIndex = _shiftPendingIndex(_pendingSendLineIndex);
  }

  int? _shiftPendingIndex(int? index) {
    if (index == null || index <= 0) return null;
    return index - 1;
  }

  void _beginDisplayMutation() {
    if (_displayNotifyTimer == null) _displayBatchHasTrim = false;
  }

  void _recordTrimmedDisplayLine(String line) {
    if (!_displayBatchHasTrim) {
      _displayBatchHasTrim = true;
      _displayTrimRevision++;
      _lastTrimmedDisplayLines = <String>[];
    }
    _lastTrimmedDisplayLines.add(line);
  }

  void _scheduleDisplayNotify() {
    if (_displayNotifyTimer != null) return;
    _displayNotifyTimer = Timer(const Duration(milliseconds: 16), () {
      _displayNotifyTimer = null;
      _displayRevision++;
      _onChanged();
    });
  }

  void _resetTextLineBuffers() {
    _pendingReceiveText = '';
    _pendingReceiveLineIndex = null;
    _pendingReceiveLinePrefix = '';
    _pendingSendText = '';
    _pendingSendLineIndex = null;
    _pendingSendLinePrefix = '';
  }

  Future<void> _exportTextStreaming(
    File file,
    String encoding,
    RawExportProgressCallback? onProgress,
  ) async {
    final output = file.openWrite();
    final decoder = ShellStreamDecoder(encoding);
    var written = 0;
    try {
      for (final chunk in _rawBytes.readChunks()) {
        output.write(decoder.add(chunk));
        written += chunk.length;
        onProgress?.call(0.05 + 0.9 * written / _rawBytes.length);
        await Future<void>.delayed(Duration.zero);
      }
      output.write(decoder.flush());
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
      rethrow;
    }
  }

  Future<void> _exportRawBytesStreaming(
    File file,
    RawExportProgressCallback? onProgress,
  ) async {
    final crc = CrcCalculator(crc32Polys['CRC-32']!);
    final output = await file.open(mode: FileMode.write);
    var written = 0;
    try {
      for (final chunk in _rawBytes.readChunks()) {
        crc.add(chunk);
        await output.writeFrom(chunk);
        written += chunk.length;
        onProgress?.call(0.05 + 0.9 * written / _rawBytes.length);
        await Future<void>.delayed(Duration.zero);
      }
      await output.writeFrom(Uint8List.fromList(crcToBytes(crc.digest, 32)));
      await output.flush();
      await output.close();
    } catch (_) {
      await output.close();
      rethrow;
    }
  }

  Future<void> _deleteExportPart(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static String _formatTimestamp(DateTime timestamp) {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    final millisecond = timestamp.millisecond.toString().padLeft(3, '0');
    return '$hour:$minute:$second.$millisecond';
  }

  static String _formatByteSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GiB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MiB';
  }
}

/// 支持 O(1) 头部淘汰的字符串列表。
/// 为高频显示缓存提供 O(1) 头部淘汰的环形字符串列表。
class _CircularStringList extends ListBase<String> {
  List<String?> _items = List<String?>.filled(16, null);
  int _head = 0;
  int _length = 0;

  @override
  int get length => _length;

  @override
  set length(int value) {
    if (value < 0) throw RangeError.range(value, 0, null, 'length');
    if (value > _length) {
      throw UnsupportedError('不能通过 length 扩展环形列表');
    }
    while (_length > value) {
      removeLast();
    }
  }

  @override
  String operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _items[_physicalIndex(index)]!;
  }

  @override
  void operator []=(int index, String value) {
    RangeError.checkValidIndex(index, this);
    _items[_physicalIndex(index)] = value;
  }

  @override
  void add(String value) {
    _ensureCapacity(_length + 1);
    _items[_physicalIndex(_length)] = value;
    _length++;
  }

  String removeFirst() {
    if (_length == 0) throw StateError('列表为空');
    final value = _items[_head]!;
    _items[_head] = null;
    _head = (_head + 1) % _items.length;
    _length--;
    if (_length == 0) _head = 0;
    return value;
  }

  @override
  String removeLast() {
    if (_length == 0) throw StateError('列表为空');
    final index = _physicalIndex(_length - 1);
    final value = _items[index]!;
    _items[index] = null;
    _length--;
    if (_length == 0) _head = 0;
    return value;
  }

  @override
  String removeAt(int index) {
    RangeError.checkValidIndex(index, this);
    if (index == 0) return removeFirst();
    if (index == _length - 1) return removeLast();
    final value = this[index];
    for (var offset = index; offset < _length - 1; offset++) {
      this[offset] = this[offset + 1];
    }
    removeLast();
    return value;
  }

  @override
  void clear() {
    _items = List<String?>.filled(16, null);
    _head = 0;
    _length = 0;
  }

  int _physicalIndex(int logicalIndex) =>
      (_head + logicalIndex) % _items.length;

  void _ensureCapacity(int required) {
    if (required <= _items.length) return;
    final next = List<String?>.filled(_items.length * 2, null);
    for (var index = 0; index < _length; index++) {
      next[index] = this[index];
    }
    _items = next;
    _head = 0;
  }
}
