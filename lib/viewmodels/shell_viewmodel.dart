import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/data_connection_config.dart';
import '../data/models/ssh_connection_config.dart';
import '../services/app_settings.dart';
import '../services/shell_session.dart';
import '../services/shell_stream_decoder.dart';
import '../services/ssh_connection_service.dart';
import '../services/ymodem_service.dart';
import 'base_viewmodel.dart';

/// 独立 Shell 页面的状态与串口操作入口。
class ShellViewModel extends BaseViewModel {
  ShellViewModel(super.connectionService, [SshConnectionService? sshService])
    : sshService = sshService ?? SshConnectionService(),
      _ownsSshService = sshService == null {
    this.sshService.addListener(_onSshChanged);
    _normalSubscription = connectionService.shellDataStream.listen((data) {
      if (connectionMode == ShellConnectionMode.normal) {
        _dataController.add(data);
      }
    });
    _sshSubscription = this.sshService.dataStream.listen((data) {
      if (connectionMode == ShellConnectionMode.ssh) _dataController.add(data);
    });
  }

  final SshConnectionService sshService;
  final bool _ownsSshService;
  final StreamController<Uint8List> _dataController =
      StreamController.broadcast(sync: true);
  late final StreamSubscription<Uint8List> _normalSubscription;
  late final StreamSubscription<Uint8List> _sshSubscription;

  ShellConnectionMode get connectionMode =>
      ShellConnectionMode.fromString(AppSettings().shellConnectionMode);
  bool get isSshMode => connectionMode == ShellConnectionMode.ssh;

  bool get isConnected =>
      isSshMode ? sshService.isConnected : connectionService.isConnected;
  bool get isRunning =>
      isSshMode ? sshService.isRunning : connectionService.isShellReceiving;
  bool get isYmodemActive =>
      !isSshMode &&
      connectionService.activeConnectionType == DataConnectionType.serial &&
      connectionService.ymodemService.isActive;
  bool get canUseYmodem =>
      !isSshMode &&
      connectionService.activeConnectionType == DataConnectionType.serial;
  Stream<Uint8List> get dataStream => _dataController.stream;
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

  Future<bool> start() async {
    if (isSshMode) {
      await sshService.startShell();
      return true;
    }
    return connectionService.startShellReceiving();
  }

  Future<void> stop() =>
      isSshMode
          ? sshService.stopShell()
          : connectionService.stopShellReceiving();

  Future<void> sendText(String text) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    final data = connectionService.prepareShellTextData(text);
    if (isSshMode) {
      await sshService.write(data);
    } else {
      await connectionService.sendRawBytes(data);
    }
  }

  Future<void> sendBytes(Uint8List data) async {
    if (!isRunning) throw StateError('Shell 尚未开始接收');
    if (isSshMode) {
      await sshService.write(data);
    } else {
      await connectionService.sendRawBytes(data);
    }
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

  Future<void> setConnectionMode(ShellConnectionMode value) async {
    if (value == connectionMode) return;
    if (isSshMode) {
      await sshService.disconnect();
    } else {
      await connectionService.disconnect();
    }
    AppSettings().shellConnectionMode = value.value;
    await AppSettings().save();
    notifyListeners();
  }

  void resizeSshTerminal(int columns, int rows) {
    if (isSshMode) sshService.resizeTerminal(columns, rows);
  }

  void updatePendingReceiveBytes(int value) {
    if (!isSshMode) connectionService.updateShellPendingReceiveBytes(value);
  }

  void _onSshChanged() => notifyListeners();

  @override
  void dispose() {
    sshService.removeListener(_onSshChanged);
    unawaited(_normalSubscription.cancel());
    unawaited(_sshSubscription.cancel());
    unawaited(_dataController.close());
    if (_ownsSshService) sshService.dispose();
    super.dispose();
  }
}
