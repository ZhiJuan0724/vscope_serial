import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../services/shell_session.dart';
import '../services/shell_stream_decoder.dart';
import '../services/ymodem_service.dart';
import 'base_viewmodel.dart';

/// 独立 Shell 页面的状态与串口操作入口。
class ShellViewModel extends BaseViewModel {
  ShellViewModel(super.connectionService);

  bool get isConnected => connectionService.isConnected;
  bool get isRunning => connectionService.isShellReceiving;
  bool get isYmodemActive => connectionService.ymodemService.isActive;
  Stream<Uint8List> get dataStream => connectionService.shellDataStream;
  Stream<YmodemTransferStatus> get ymodemStatusStream =>
      connectionService.ymodemService.statusStream;
  YmodemTransferStatus get ymodemStatus =>
      connectionService.ymodemService.status;
  RawShellInputMode get inputMode => connectionService.rawShellInputMode;
  RawShellThemeMode get themeMode => connectionService.rawShellThemeMode;
  RawShellCursorMode get cursorMode => connectionService.rawShellCursorMode;
  String get encoding => connectionService.shellEncoding;
  String get lineEnding => connectionService.shellLineEnding;
  bool get localEcho => connectionService.shellLocalEcho;
  double get fontSize => connectionService.rawDataTerminalFontSize;
  String get fontFamily => connectionService.rawDataTerminalFontFamily;
  int get scrollbackLines => connectionService.shellScrollbackLines;
  static const availableEncodings = shellTextEncodings;

  bool start() => connectionService.startShellReceiving();
  Future<void> stop() => connectionService.stopShellReceiving();

  Future<void> sendText(String text) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    await connectionService.sendRawBytes(
      connectionService.prepareShellTextData(text),
    );
  }

  Future<void> sendBytes(Uint8List data) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    await connectionService.sendRawBytes(data);
  }

  Uint8List encodeText(String text) => connectionService.encodeShellText(text);

  void setInputMode(RawShellInputMode value) =>
      connectionService.setRawShellInputMode(value);
  void setEncoding(String value) => connectionService.setShellEncoding(value);
  void setLineEnding(String value) =>
      connectionService.setShellLineEnding(value);
  void setLocalEcho(bool value) => connectionService.setShellLocalEcho(value);
  void setFontSize(double value) =>
      connectionService.setRawDataTerminalFontSize(value);
  void setFontFamily(String value) =>
      connectionService.setRawDataTerminalFontFamily(value);
  void setThemeMode(RawShellThemeMode value) =>
      connectionService.setRawShellThemeMode(value);
  void setCursorMode(RawShellCursorMode value) =>
      connectionService.setRawShellCursorMode(value);
  void setScrollbackLines(int value) =>
      connectionService.setShellScrollbackLines(value);

  Future<void> sendYmodemFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    AppLogger().info('Shell 开始 YMODEM 发送: ${file.path}', category: 'SHELL');
    return connectionService.ymodemService.sendFile(
      file,
      packetSizeMode: packetSizeMode,
    );
  }

  Future<File?> receiveYmodemFile() {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    return connectionService.receiveYmodemFile();
  }

  Future<void> cancelYmodem() => connectionService.ymodemService.cancel();
}
