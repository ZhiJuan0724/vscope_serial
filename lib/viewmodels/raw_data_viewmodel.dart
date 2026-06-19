import 'dart:io';
import 'dart:typed_data';

import '../core/utils/crc.dart';
import '../services/serial_service.dart';
import '../services/ymodem_service.dart';
import 'base_viewmodel.dart';

/// 数据收发页面 ViewModel
class RawDataViewModel extends BaseViewModel {
  RawDataViewModel(super.serialService);

  List<String> get receivedLines => serialService.receivedLines;
  bool get isConnected => serialService.isConnected;
  bool get receiveHex => serialService.receiveHex;
  bool get showTimestamp => serialService.showTimestamp;
  bool get autoScroll => serialService.autoScroll;
  bool get shellMode => serialService.rawDataShellMode;
  bool get shellEnabled => serialService.rawDataShellEnabled;
  RawShellInputMode get shellInputMode => serialService.rawShellInputMode;
  double get terminalFontSize => serialService.rawDataTerminalFontSize;
  String get terminalFontFamily => serialService.rawDataTerminalFontFamily;
  RawShellThemeMode get shellThemeMode => serialService.rawShellThemeMode;
  RawShellCursorMode get shellCursorMode => serialService.rawShellCursorMode;
  bool get sendHex => serialService.sendHex;
  bool get keepSendText => serialService.keepSendText;
  bool get appendLineEnding => serialService.appendLineEnding;
  String get lineEnding => serialService.lineEnding;
  bool get enableCrc => serialService.enableCrc;
  CrcByteOrder get crcByteOrder => serialService.crcByteOrder;
  CrcType get crcType => serialService.crcType;
  String get crcPolyName => serialService.crcPolyName;
  bool get useRandomSource => serialService.useRandomSource;
  bool get isRawReceiving => serialService.isRawReceiving;
  int get timeWindowUs => serialService.timeWindowUs;
  int get displayLineLimit => serialService.displayLineLimit;
  Stream<Uint8List> get shellDataStream => serialService.shellDataStream;
  Stream<YmodemTransferStatus> get ymodemStatusStream =>
      serialService.ymodemService.statusStream;
  YmodemTransferStatus get ymodemStatus => serialService.ymodemService.status;
  bool get isYmodemActive => ymodemStatus.isActive;
  String get receiveEncoding => serialService.receiveEncoding;

  /// 可选的文本解码方式（用于非 HEX 显示模式）
  static const List<Map<String, String>> availableEncodings = [
    {'id': 'UTF-8', 'name': 'UTF-8'},
    {'id': 'GBK', 'name': 'GBK (简体中文)'},
    {'id': 'BIG5', 'name': 'BIG5 (繁体中文)'},
    {'id': 'Shift_JIS', 'name': 'Shift_JIS (日文)'},
    {'id': 'EUC-KR', 'name': 'EUC-KR (韩文)'},
    {'id': 'Latin-1', 'name': 'Latin-1 (西欧)'},
    {'id': 'ASCII', 'name': 'ASCII'},
  ];

  /// 设置随机数据源开关
  /// 当启用随机数据源且未开始绘图时，随机数据会显示在数据收发页面
  void setUseRandomSource(bool value) {
    serialService.useRandomSource = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  /// 开始接收原始数据
  void startReceiving() => serialService.startRawReceiving();

  /// 停止接收原始数据
  void stopReceiving() => serialService.stopRawReceiving();

  void setReceiveHex(bool value) {
    serialService.setReceiveHex(value);
  }

  void setReceiveEncoding(String encoding) {
    serialService.setReceiveEncoding(encoding);
  }

  void setShowTimestamp(bool value) {
    serialService.setShowTimestamp(value);
  }

  void setAutoScroll(bool value) {
    serialService.autoScroll = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setShellMode(bool value) {
    serialService.setRawDataShellMode(value);
  }

  void setShellEnabled(bool value) {
    serialService.setRawDataShellEnabled(value);
  }

  void setShellInputMode(RawShellInputMode value) {
    serialService.setRawShellInputMode(value);
  }

  void setTerminalFontSize(double value) {
    serialService.setRawDataTerminalFontSize(value);
  }

  void setTerminalFontFamily(String value) {
    serialService.setRawDataTerminalFontFamily(value);
  }

  void setShellThemeMode(RawShellThemeMode value) {
    serialService.setRawShellThemeMode(value);
  }

  void setShellCursorMode(RawShellCursorMode value) {
    serialService.setRawShellCursorMode(value);
  }

  void setSendHex(bool value) {
    serialService.sendHex = value;
    if (!value) serialService.enableCrc = false;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setKeepSendText(bool value) {
    serialService.keepSendText = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setAppendLineEnding(bool value) {
    serialService.appendLineEnding = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setLineEnding(String value) {
    serialService.lineEnding = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setEnableCrc(bool value) {
    serialService.enableCrc = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcByteOrder(CrcByteOrder value) {
    serialService.crcByteOrder = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcType(CrcType type) {
    serialService.crcType = type;
    final polys = getPolysByType(type);
    if (polys.isNotEmpty) {
      serialService.crcPolyName = polys.keys.first;
    }
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcPolyName(String name) {
    serialService.crcPolyName = name;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setTimeWindowUs(int us) {
    serialService.setTimeWindowUs(us);
  }

  void setDisplayLineLimit(int value) {
    serialService.setDisplayLineLimit(value);
  }

  void clearData() => serialService.clearReceivedData();

  Uint8List? prepareSendData(String text) =>
      serialService.prepareSendData(text);
  void send(Uint8List data) => serialService.send(data);
  Future<void> sendShellText(String text) async {
    if (text.isEmpty || isYmodemActive) return;
    serialService.sendRawBytes(serialService.prepareShellTextData(text));
  }

  Future<void> sendShellBytes(Uint8List data) async {
    if (data.isEmpty || isYmodemActive) return;
    await serialService.sendRawBytes(data);
  }

  Future<void> sendYmodemFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) => serialService.ymodemService.sendFile(
    file,
    packetSizeMode: packetSizeMode,
  );
  Future<File?> receiveYmodemFile() => serialService.receiveYmodemFile();
  Future<void> cancelYmodem() => serialService.ymodemService.cancel();

  Future<String?> exportAsText() => serialService.exportAsText();
  Future<String?> exportAsRawBytes() => serialService.exportAsRawBytes();
  Map<String, String> get dataStats => serialService.dataStats;
}
