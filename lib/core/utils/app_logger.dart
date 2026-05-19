import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';



/// 自定义文件输出 - 每次启动新建日志，旧日志自动归档，最多保留20份
class FileLogOutput extends LogOutput {
  RandomAccessFile? _raf;
  File? _file;
  static const int _maxLogFiles = 20;
  static const String _latestName = 'latest.log';

  @override
  Future<void> init() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final logDir = Directory('${exeDir.path}/logs');
    await logDir.create(recursive: true);

    // 归档旧日志
    await _archiveOldLog(logDir);
    // 清理超期日志
    await _cleanupOldLogs(logDir);

    // 新建 latest.log
    _file = File('${logDir.path}/$_latestName');
    _raf = await _file!.open(mode: FileMode.write);
  }

  /// 将已有的 latest.log 重命名为带时间戳的归档文件
  Future<void> _archiveOldLog(Directory logDir) async {
    final latest = File('${logDir.path}/$_latestName');
    if (!await latest.exists()) return;

    final now = DateTime.now();
    final timestamp =
        '${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final archiveName = 'vscope_log_$timestamp.log';
    final archive = File('${logDir.path}/$archiveName');

    try {
      await latest.rename(archive.path);
    } catch (_) {
      // 重命名失败则忽略（可能被占用）
    }
  }

  /// 清理超期日志，只保留最新的 _maxLogFiles 份
  Future<void> _cleanupOldLogs(Directory logDir) async {
    final entities = await logDir
        .list()
        .where((e) =>
            e is File &&
            e.path.split(Platform.pathSeparator).last.startsWith('vscope_log_'))
        .toList();

    if (entities.length <= _maxLogFiles) return;

    // 按修改时间排序，旧的在前
    entities.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

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
