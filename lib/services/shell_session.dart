import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import 'app_settings.dart';
import 'text_encoding_codec.dart';
import 'ymodem_service.dart';

enum RawShellInputMode {
  line('line', '命令行'),
  key('key', '逐键');

  const RawShellInputMode(this.value, this.label);
  final String value;
  final String label;

  static RawShellInputMode fromString(String value) =>
      value == key.value ? key : line;
}

enum RawShellThemeMode {
  light('light', '浅色'),
  dark('dark', '深色');

  const RawShellThemeMode(this.value, this.label);
  final String value;
  final String label;

  static RawShellThemeMode fromString(String value) =>
      value == dark.value ? dark : light;
}

enum RawShellCursorMode {
  verticalBar('verticalBar', '竖线'),
  underline('underline', '下划线'),
  block('block', '方块');

  const RawShellCursorMode(this.value, this.label);
  final String value;
  final String label;

  static RawShellCursorMode fromString(String value) => switch (value) {
    'block' => block,
    'underline' => underline,
    _ => verticalBar,
  };
}

/// Shell终端配置、字节流和YMODEM生命周期。
class ShellSession {
  ShellSession({
    required Future<void> Function(Uint8List) sendBytes,
    required void Function() onChanged,
  }) : _onChanged = onChanged,
       ymodemService = YmodemService(sendBytes: sendBytes) {
    ymodemService.attach(dataStream);
  }

  final void Function() _onChanged;
  final _dataController = StreamController<Uint8List>.broadcast();
  final YmodemService ymodemService;

  Stream<Uint8List> get dataStream => _dataController.stream;
  int pendingReceiveBytes = 0;
  RawShellInputMode inputMode = RawShellInputMode.line;
  RawShellThemeMode themeMode = RawShellThemeMode.light;
  RawShellCursorMode cursorMode = RawShellCursorMode.verticalBar;
  String encoding = 'UTF-8';
  String lineEnding = '\r';
  bool localEcho = true;
  int scrollbackLines = 10000;
  double fontSize = 13.0;
  String fontFamily = 'Consolas';

  void loadSettings(AppSettings settings) {
    inputMode = RawShellInputMode.fromString(settings.rawDataShellInputMode);
    themeMode = RawShellThemeMode.fromString(settings.rawDataShellTheme);
    cursorMode = RawShellCursorMode.fromString(settings.rawDataShellCursor);
    encoding = settings.shellEncoding;
    lineEnding = settings.shellLineEnding;
    localEcho = settings.shellLocalEcho;
    scrollbackLines = settings.shellScrollbackLines;
    fontSize = settings.rawDataTerminalFontSize.clamp(10.0, 24.0);
    fontFamily = settings.rawDataTerminalFontFamily;
  }

  void addTerminalBytes(Uint8List data) => _dataController.add(data);
  void addYmodemBytes(Uint8List data) => ymodemService.addIncomingBytes(data);

  Uint8List prepareLine(String text) =>
      encodeTextBytes('$text$lineEnding', encoding);
  Uint8List encodeText(String text) => encodeTextBytes(text, encoding);
  String decodeText(Uint8List data) => decodeTextBytes(data, encoding);

  void updatePendingReceiveBytes(int value) {
    pendingReceiveBytes = value < 0 ? 0 : value;
  }

  void setInputMode(RawShellInputMode value) {
    if (inputMode == value) return;
    inputMode = value;
    _save((settings) => settings.rawDataShellInputMode = value.value);
    AppLogger().info('Shell输入模式切换为 ${value.label}', category: 'DATA');
  }

  void setEncoding(String value) {
    if (encoding == value) return;
    encoding = value;
    _save((settings) => settings.shellEncoding = value);
  }

  void setLineEnding(String value) {
    if (lineEnding == value) return;
    lineEnding = value;
    _save((settings) => settings.shellLineEnding = value);
  }

  void setLocalEcho(bool value) {
    if (localEcho == value) return;
    localEcho = value;
    _save((settings) => settings.shellLocalEcho = value);
  }

  void setScrollbackLines(int value) {
    final next = value.clamp(1000, 100000);
    if (scrollbackLines == next) return;
    scrollbackLines = next;
    _save((settings) => settings.shellScrollbackLines = next);
  }

  void setFontSize(double value) {
    final next = value.clamp(10.0, 24.0);
    if (fontSize == next) return;
    fontSize = next;
    _save((settings) => settings.rawDataTerminalFontSize = next);
  }

  void setFontFamily(String value) {
    final next = value.trim().isEmpty ? 'Consolas' : value.trim();
    if (fontFamily == next) return;
    fontFamily = next;
    _save((settings) => settings.rawDataTerminalFontFamily = next);
  }

  void setThemeMode(RawShellThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    _save((settings) => settings.rawDataShellTheme = value.value);
  }

  void setCursorMode(RawShellCursorMode value) {
    if (cursorMode == value) return;
    cursorMode = value;
    _save((settings) => settings.rawDataShellCursor = value.value);
  }

  /// 原子提交设置弹窗中的完整终端草稿。
  ///
  /// 先持久化，成功后再替换运行态，避免部分字段保存失败却已在页面生效。
  Future<void> applyTerminalSettings({
    required String encoding,
    required String lineEnding,
    required bool localEcho,
    required int scrollbackLines,
    required double fontSize,
    required String fontFamily,
    required RawShellThemeMode themeMode,
    required RawShellCursorMode cursorMode,
    required bool sshKeepAliveEnabled,
  }) async {
    final nextScrollback = scrollbackLines.clamp(1000, 100000);
    final nextFontSize = fontSize.clamp(10.0, 24.0);
    final nextFontFamily =
        fontFamily.trim().isEmpty ? 'Consolas' : fontFamily.trim();
    final settings = AppSettings();
    final previous = (
      encoding: settings.shellEncoding,
      lineEnding: settings.shellLineEnding,
      localEcho: settings.shellLocalEcho,
      scrollback: settings.shellScrollbackLines,
      fontSize: settings.rawDataTerminalFontSize,
      fontFamily: settings.rawDataTerminalFontFamily,
      theme: settings.rawDataShellTheme,
      cursor: settings.rawDataShellCursor,
      sshKeepAlive: settings.sshKeepAliveEnabled,
    );
    settings
      ..shellEncoding = encoding
      ..shellLineEnding = lineEnding
      ..shellLocalEcho = localEcho
      ..shellScrollbackLines = nextScrollback
      ..rawDataTerminalFontSize = nextFontSize
      ..rawDataTerminalFontFamily = nextFontFamily
      ..rawDataShellTheme = themeMode.value
      ..rawDataShellCursor = cursorMode.value
      ..sshKeepAliveEnabled = sshKeepAliveEnabled;
    try {
      await settings.save();
    } catch (_) {
      settings
        ..shellEncoding = previous.encoding
        ..shellLineEnding = previous.lineEnding
        ..shellLocalEcho = previous.localEcho
        ..shellScrollbackLines = previous.scrollback
        ..rawDataTerminalFontSize = previous.fontSize
        ..rawDataTerminalFontFamily = previous.fontFamily
        ..rawDataShellTheme = previous.theme
        ..rawDataShellCursor = previous.cursor
        ..sshKeepAliveEnabled = previous.sshKeepAlive;
      rethrow;
    }
    this.encoding = encoding;
    this.lineEnding = lineEnding;
    this.localEcho = localEcho;
    this.scrollbackLines = nextScrollback;
    this.fontSize = nextFontSize;
    this.fontFamily = nextFontFamily;
    this.themeMode = themeMode;
    this.cursorMode = cursorMode;
    _onChanged();
  }

  Future<File?> receiveYmodemFile() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return ymodemService.receiveFile(
      Directory('${exeDir.path}/exports/ymodem'),
    );
  }

  void abort(String reason) {
    if (ymodemService.isActive) ymodemService.abort(reason);
  }

  void _save(void Function(AppSettings) update) {
    final settings = AppSettings();
    update(settings);
    unawaited(settings.save());
    _onChanged();
  }

  Future<void> dispose() async {
    await ymodemService.dispose();
    await _dataController.close();
  }
}
