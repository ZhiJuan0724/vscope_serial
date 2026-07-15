import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../services/serial_service.dart';
import '../services/shell_stream_decoder.dart';
import '../services/ymodem_service.dart';
import 'base_viewmodel.dart';

/// 独立 Shell 页面的状态与串口操作入口。
class ShellViewModel extends BaseViewModel {
  ShellViewModel(super.serialService);

  bool get isConnected => serialService.isConnected;
  bool get isRunning => serialService.isShellReceiving;
  bool get isYmodemActive => serialService.ymodemService.isActive;
  Stream<Uint8List> get dataStream => serialService.shellDataStream;
  Stream<YmodemTransferStatus> get ymodemStatusStream =>
      serialService.ymodemService.statusStream;
  YmodemTransferStatus get ymodemStatus => serialService.ymodemService.status;
  RawShellInputMode get inputMode => serialService.rawShellInputMode;
  RawShellThemeMode get themeMode => serialService.rawShellThemeMode;
  RawShellCursorMode get cursorMode => serialService.rawShellCursorMode;
  String get encoding => serialService.shellEncoding;
  String get lineEnding => serialService.shellLineEnding;
  bool get localEcho => serialService.shellLocalEcho;
  double get fontSize => serialService.rawDataTerminalFontSize;
  String get fontFamily => serialService.rawDataTerminalFontFamily;
  int get scrollbackLines => serialService.shellScrollbackLines;
  static const availableEncodings = shellTextEncodings;

  bool start() => serialService.startShellReceiving();
  Future<void> stop() => serialService.stopShellReceiving();

  Future<void> sendText(String text) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    await serialService.sendRawBytes(serialService.prepareShellTextData(text));
  }

  Future<void> sendBytes(Uint8List data) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    await serialService.sendRawBytes(data);
  }

  Uint8List encodeText(String text) => serialService.encodeShellText(text);

  void setInputMode(RawShellInputMode value) =>
      serialService.setRawShellInputMode(value);
  void setEncoding(String value) => serialService.setShellEncoding(value);
  void setLineEnding(String value) => serialService.setShellLineEnding(value);
  void setLocalEcho(bool value) => serialService.setShellLocalEcho(value);
  void setFontSize(double value) =>
      serialService.setRawDataTerminalFontSize(value);
  void setFontFamily(String value) =>
      serialService.setRawDataTerminalFontFamily(value);
  void setThemeMode(RawShellThemeMode value) =>
      serialService.setRawShellThemeMode(value);
  void setCursorMode(RawShellCursorMode value) =>
      serialService.setRawShellCursorMode(value);
  void setScrollbackLines(int value) =>
      serialService.setShellScrollbackLines(value);

  Future<void> sendYmodemFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    AppLogger().info('Shell 开始 YMODEM 发送: ${file.path}', category: 'SHELL');
    return serialService.ymodemService.sendFile(
      file,
      packetSizeMode: packetSizeMode,
    );
  }

  Future<File?> receiveYmodemFile() {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    return serialService.receiveYmodemFile();
  }

  Future<void> cancelYmodem() => serialService.ymodemService.cancel();
}
