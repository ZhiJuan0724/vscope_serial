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
      case 'TRACE': return 'TRACE';
      case 'DEBUG': return 'DEBUG';
      case 'INFO': return 'INFO';
      case 'WARNING': return 'WARNING';
      case 'ERROR': return 'ERROR';
      case 'FATAL': return 'FATAL';
      // 兼容旧单字母格式
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
    // _AppLogPrinter 格式:
    // [INFO] TIME: 2026-05-18T15:09:11.801621 [CATEGORY] message
    try {
      // 去除 ANSI 颜色码
      final cleanLine = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

      // 解析 level: [INFO]
      final levelMatch = RegExp(r'^\[(\w+)\]\s+TIME:').firstMatch(cleanLine);
      if (levelMatch == null) return null;
      final level = levelMatch.group(1)!;

      // 解析时间: TIME: 2026-05-18T15:09:11.801621
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

/// 自定义日志打印机 - 使用完整级别名称 + ANSI 颜色
class _AppLogPrinter extends LogPrinter {
  static final _levelColors = {
    Level.trace: AnsiColor.fg(AnsiColor.grey(0.5)),
    Level.debug: AnsiColor.fg(6),
    Level.info: AnsiColor.fg(2),
    Level.warning: AnsiColor.fg(3),
    Level.error: AnsiColor.fg(196),
    Level.fatal: AnsiColor.fg(199),
  };

  @override
  List<String> log(LogEvent event) {
    final time = event.time.toIso8601String();
    final level = _levelName(event.level);
    final color = _levelColors[event.level] ?? AnsiColor.none();
    final message = event.message;
    final error = event.error;
    final stackTrace = event.stackTrace;

    final spaces = _levelSpaces(level);
    String output = '${color('[$level]$spaces')} TIME: $time $message';

    if (error != null) {
      output += '\nERROR: $error';
    }
    if (stackTrace != null) {
      output += '\n$stackTrace';
    }

    return [output];
  }

  static String _levelName(Level level) {
    return switch (level) {
      Level.trace => 'TRACE',
      Level.debug => 'DEBUG',
      Level.info => 'INFO',
      Level.warning => 'WARNING',
      Level.error => 'ERROR',
      Level.fatal => 'FATAL',
      _ => level.name.toUpperCase(),
    };
  }

  static String _levelSpaces(String level) {
    // 最长级别名称是 WARNING (7字符)
    // 在 ] 后面补空格，让 TIME: 对齐
    return ' ' * (7 - level.length);
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
      printer: _AppLogPrinter(),
      output: MultiOutput([_fileOutput, _memoryOutput]),
    );
    _initialized = true;
    _memoryOutput._addEntry(LogEntry(
      level: 'INFO',
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

  /// 是否显示 TRACE 调试日志（默认关闭）
  bool showTraceLogs = false;

  /// 最新日志条目（过滤 TRACE）
  LogEntry? get latestLog {
    final entries = _memoryOutput.entries;
    if (showTraceLogs) return entries.isNotEmpty ? entries.last : null;
    // 过滤掉 TRACE，找最后一个非 TRACE
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i].level != 'TRACE') return entries[i];
    }
    return null;
  }

  /// 所有日志条目（过滤 TRACE）
  List<LogEntry> get allLogs {
    final entries = _memoryOutput.entries;
    if (showTraceLogs) return entries;
    return entries.where((e) => e.level != 'TRACE').toList();
  }

  /// 原始日志条目（不过滤，供日志弹窗使用）
  List<LogEntry> get rawLogs => _memoryOutput.entries;

  void setShowTraceLogs(bool value) {
    showTraceLogs = value;
    Future.microtask(() => notifyListeners());
  }

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
    // 使用微任务延迟通知，避免在构建阶段触发 setState
    Future.microtask(() => notifyListeners());
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
