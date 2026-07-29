import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// 自定义文件输出 - 每个进程写入独立日志文件，最多保留20份
class FileLogOutput extends LogOutput {
  RandomAccessFile? _raf;
  File? _file;
  static const int _maxLogFiles = 20;

  /// 批量flush：累计一定量或定时flush，减少磁盘IO
  static const int _flushThresholdBytes = 4096;
  int _pendingBytes = 0;
  DateTime? _lastFlushTime;
  bool flushImmediately = false;

  @visibleForTesting
  String? get filePathForTest => _file?.path;

  @override
  Future<void> init() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final logDir = Directory('${exeDir.path}/logs');
    await logDir.create(recursive: true);

    // 清理超期日志
    await _cleanupOldLogs(logDir);

    _file = File('${logDir.path}/${_newLogFileName()}');
    _raf = await _file!.open(mode: FileMode.append);
  }

  String _newLogFileName() {
    final now = DateTime.now();
    final timestamp =
        '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}_'
        '${now.millisecond.toString().padLeft(3, '0')}';
    return 'vscope_log_${timestamp}_$pid.log';
  }

  /// 清理超期日志，只保留最新的 _maxLogFiles 份
  Future<void> _cleanupOldLogs(Directory logDir) async {
    final entities =
        await logDir
            .list()
            .where(
              (e) =>
                  e is File &&
                  e.path
                      .split(Platform.pathSeparator)
                      .last
                      .startsWith('vscope_log_'),
            )
            .toList();

    if (entities.length <= _maxLogFiles) return;

    // 按修改时间排序，旧的在前
    entities.sort(
      (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
    );

    // 删除多余的旧日志，确保归档后总数不超过 _maxLogFiles
    final toDelete = entities.length - _maxLogFiles;
    for (var i = 0; i < toDelete; i++) {
      try {
        await entities[i].delete();
      } catch (_) {
        // 删除失败忽略
      }
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  void output(OutputEvent event) {
    if (_raf == null) return;
    final now = DateTime.now();
    for (final line in event.lines) {
      // 写入文件时去除 ANSI 颜色码
      final cleanLine = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
      debugPrint(line);
      final lineBytes = '$cleanLine\n';
      _raf!.writeStringSync(lineBytes);
      _pendingBytes += lineBytes.length;
    }
    // 批量flush策略：超过阈值或超过100ms未flush
    final shouldFlush =
        _pendingBytes >= _flushThresholdBytes ||
        (_lastFlushTime != null &&
            now.difference(_lastFlushTime!).inMilliseconds > 100);
    if (flushImmediately || shouldFlush) {
      _raf!.flushSync();
      _pendingBytes = 0;
      _lastFlushTime = now;
    }
  }

  /// 关闭文件（程序退出时调用）
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }

  Future<void> flush() async {
    await _raf?.flush();
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

/// 应用日志 - 全局单例，仅输出到文件
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  late final Logger _logger;
  final _fileOutput = FileLogOutput();
  bool _initialized = false;
  bool _diagnosticEnabled = false;

  bool get diagnosticEnabled => _diagnosticEnabled;
  String? get logFilePath => _fileOutput.filePathForTest;

  /// 控制高密度 TRACE/DEBUG 诊断日志是否写入历史文件。
  ///
  /// 开启后每条日志立即刷盘，尽量保留原生崩溃前的最后一个检查点。
  void setDiagnosticEnabled(bool enabled) {
    if (_diagnosticEnabled == enabled) return;
    _diagnosticEnabled = enabled;
    _fileOutput.flushImmediately = enabled;
    info(
      '调试模式已${enabled ? '开启' : '关闭'}'
      '${enabled ? '；TRACE/DEBUG 日志将立即写入磁盘' : ''}',
      category: 'APP',
    );
  }

  Future<void> init() async {
    if (_initialized) return;
    await _fileOutput.init();
    _logger = Logger(
      filter: ProductionFilter(),
      printer: _AppLogPrinter(),
      output: _fileOutput,
    );
    _initialized = true;
    info('日志系统初始化完成', category: 'APP');
  }

  /// 程序退出时关闭日志文件
  Future<void> disposeLogger() async {
    await _fileOutput.close();
  }

  /// 在即将主动终止测试进程前确保现有日志已经落盘。
  Future<void> flush() async {
    await _fileOutput.flush();
  }

  void _log(
    String level,
    String msg, {
    String? category,
    dynamic error,
    StackTrace? stackTrace,
  }) {
    if (!_initialized) return; // 未初始化时静默丢弃（避免单元测试报错）
    final formatted = category != null ? '[$category] $msg' : msg;
    switch (level) {
      case 'T':
        _logger.t(formatted, error: error, stackTrace: stackTrace);
        break;
      case 'D':
        _logger.d(formatted, error: error, stackTrace: stackTrace);
        break;
      case 'I':
        _logger.i(formatted, error: error, stackTrace: stackTrace);
        break;
      case 'W':
        _logger.w(formatted, error: error, stackTrace: stackTrace);
        break;
      case 'E':
        _logger.e(formatted, error: error, stackTrace: stackTrace);
        break;
      case 'F':
        _logger.f(formatted, error: error, stackTrace: stackTrace);
        break;
    }
  }

  void trace(String msg, {String? category}) {
    if (_diagnosticEnabled) _log('T', msg, category: category);
  }

  void debug(String msg, {String? category}) {
    if (_diagnosticEnabled) _log('D', msg, category: category);
  }

  void info(String msg, {String? category}) =>
      _log('I', msg, category: category);
  void warning(String msg, {String? category}) =>
      _log('W', msg, category: category);
  void error(
    String msg, {
    String? category,
    dynamic error,
    StackTrace? stackTrace,
  }) =>
      _log('E', msg, category: category, error: error, stackTrace: stackTrace);
  void fatal(
    String msg, {
    String? category,
    dynamic error,
    StackTrace? stackTrace,
  }) =>
      _log('F', msg, category: category, error: error, stackTrace: stackTrace);
}
