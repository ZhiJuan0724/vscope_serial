import 'dart:io';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

/// 日志条目
class LogEntry {
  final String level; // TRACE, DEBUG, INFO, WARNING, ERROR, FATAL
  final DateTime timestamp;
  final String? category;
  final String message;

  LogEntry({
    required this.level,
    required this.timestamp,
    this.category,
    required this.message,
  });

  String get displayText {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    final time = '$h:$m:$s.$ms';
    final levelFull = levelFullName(level);
    if (category != null) {
      return '[$time] [$levelFull] [$category] $message';
    }
    return '[$time] [$levelFull] $message';
  }

  static String levelFullName(String level) {
    switch (level) {
      case 'T': return 'TRACE';
      case 'D': return 'DEBUG';
      case 'I': return 'INFO';
      case 'W': return 'WARNING';
      case 'E': return 'ERROR';
      case 'F': return 'FATAL';
      default: return level;
    }
  }
}

/// 自定义文件输出 - 使用 RandomAccessFile 保持打开，性能更好
class FileLogOutput extends LogOutput {
  RandomAccessFile? _raf;
  File? _file;

  @override
  Future<void> init() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final logDir = Directory('${exeDir.path}/logs');
    await logDir.create(recursive: true);
    _file = File('${logDir.path}/latest.log');
    _raf = await _file!.open(mode: FileMode.append);
  }

  @override
  void output(OutputEvent event) {
    if (_raf == null) return;
    for (final line in event.lines) {
      // 写入文件时去除 ANSI 颜色码
      final cleanLine = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
      debugPrint(line);
      _raf!.writeStringSync('$cleanLine\n');
    }
    _raf!.flushSync();
  }

  /// 关闭文件（程序退出时调用）
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
}

/// 内存日志输出 - 用于状态栏显示最新日志
class MemoryLogOutput extends LogOutput {
  final _entries = Queue<LogEntry>();
  static const int _maxEntries = 200;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  LogEntry? get latest => _entries.isNotEmpty ? _entries.last : null;

  @override
  void output(OutputEvent event) {
    for (final line in event.lines) {
      final entry = _parseLine(line);
      if (entry != null) {
        _addEntry(entry);
      }
    }
  }

  void _addEntry(LogEntry entry) {
    _entries.addLast(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
  }

  LogEntry? _parseLine(String line) {
    // SimplePrinter 格式（含 ANSI 颜色码）:
    // \x1B[38;5;12m[I]\x1B[0m TIME: 2026-05-18T14:24:55.799686 [CATEGORY] message
    try {
      // 去除 ANSI 颜色码
      final cleanLine = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

      // 解析 level: [I]
      final levelMatch = RegExp(r'^\[(.)\]').firstMatch(cleanLine);
      if (levelMatch == null) return null;
      final level = levelMatch.group(1)!;

      // 解析时间: TIME: 2026-05-18T14:24:55.799686
      final timeMatch = RegExp(r'TIME:\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)').firstMatch(cleanLine);
      if (timeMatch == null) return null;
      final timeStr = timeMatch.group(1)!;
      final timestamp = DateTime.parse(timeStr);

      // 从时间后面开始解析 category 和 message
      final afterTime = cleanLine.substring(cleanLine.indexOf(timeStr) + timeStr.length).trim();

      String? category;
      String message;

      // category 格式: [CATEGORY] message
      final catMatch = RegExp(r'^\[([A-Z]+)\]\s+(.*)$').firstMatch(afterTime);
      if (catMatch != null) {
        category = catMatch.group(1);
        message = catMatch.group(2)!;
      } else {
        message = afterTime;
      }

      return LogEntry(
        level: level,
        timestamp: timestamp,
        category: category,
        message: message,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 应用日志 - 全局单例，支持 ChangeNotifier 供 UI 监听
class AppLogger extends ChangeNotifier {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  late final Logger _logger;
  final _fileOutput = FileLogOutput();
  final _memoryOutput = MemoryLogOutput();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _fileOutput.init();
    _logger = Logger(
      filter: ProductionFilter(),
      printer: SimplePrinter(printTime: true),
      output: MultiOutput([_fileOutput, _memoryOutput]),
    );
    _initialized = true;
    _memoryOutput._addEntry(LogEntry(
      level: 'I',
      timestamp: DateTime.now(),
      category: 'APP',
      message: '日志系统初始化完成',
    ));
    // 使用微任务延迟通知，避免构建阶段触发 setState
    Future.microtask(() => notifyListeners());
  }

  /// 程序退出时关闭日志文件
  Future<void> disposeLogger() async {
    await _fileOutput.close();
  }

  /// 最新日志条目
  LogEntry? get latestLog => _memoryOutput.latest;

  /// 所有日志条目
  List<LogEntry> get allLogs => _memoryOutput.entries;

  void _log(String level, String msg, {String? category}) {
    final formatted = category != null ? '[$category] $msg' : msg;
    switch (level) {
      case 'T':
        _logger.t(formatted);
        break;
      case 'D':
        _logger.d(formatted);
        break;
      case 'I':
        _logger.i(formatted);
        break;
      case 'W':
        _logger.w(formatted);
        break;
      case 'E':
        _logger.e(formatted);
        break;
      case 'F':
        _logger.f(formatted);
        break;
    }
    notifyListeners();
  }

  void trace(String msg, {String? category}) => _log('T', msg, category: category);
  void debug(String msg, {String? category}) => _log('D', msg, category: category);
  void info(String msg, {String? category}) => _log('I', msg, category: category);
  void warning(String msg, {String? category}) => _log('W', msg, category: category);
  void error(String msg, {String? category, dynamic error, StackTrace? stackTrace}) =>
      _log('E', msg, category: category);
  void fatal(String msg, {String? category, dynamic error, StackTrace? stackTrace}) =>
      _log('F', msg, category: category);
}
