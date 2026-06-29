import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
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
    if (serialService.useRandomSource == value) return;
    serialService.useRandomSource = value;
    AppLogger().info('数据收发页随机源${value ? '启用' : '关闭'}', category: 'DATA');
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
    if (serialService.autoScroll == value) return;
    serialService.autoScroll = value;
    AppLogger().info('接收区自动滚动${value ? '启用' : '关闭'}', category: 'DATA');
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
    if (serialService.sendHex == value) return;
    serialService.sendHex = value;
    if (!value) serialService.enableCrc = false;
    AppLogger().info(
      '发送格式切换为${value ? 'HEX' : '文本'}${value ? '' : '，CRC已关闭'}',
      category: 'DATA',
    );
    Future.microtask(() => serialService.notifyListeners());
  }

  void setKeepSendText(bool value) {
    if (serialService.keepSendText == value) return;
    serialService.keepSendText = value;
    AppLogger().info('发送后${value ? '保留' : '清空'}输入内容', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
  }

  void setAppendLineEnding(bool value) {
    if (serialService.appendLineEnding == value) return;
    serialService.appendLineEnding = value;
    AppLogger().info('发送行尾追加${value ? '启用' : '关闭'}', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
  }

  void setLineEnding(String value) {
    if (serialService.lineEnding == value) return;
    serialService.lineEnding = value;
    AppLogger().info(
      '发送行尾设置为 ${value.replaceAll('\r', r'\r').replaceAll('\n', r'\n')}',
      category: 'DATA',
    );
    Future.microtask(() => serialService.notifyListeners());
  }

  void setEnableCrc(bool value) {
    if (serialService.enableCrc == value) return;
    serialService.enableCrc = value;
    AppLogger().info('发送CRC${value ? '启用' : '关闭'}', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcByteOrder(CrcByteOrder value) {
    if (serialService.crcByteOrder == value) return;
    serialService.crcByteOrder = value;
    AppLogger().info('CRC字节序设置为 ${value.label}', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcType(CrcType type) {
    if (serialService.crcType == type) return;
    serialService.crcType = type;
    final polys = getPolysByType(type);
    if (polys.isNotEmpty) {
      serialService.crcPolyName = polys.keys.first;
    }
    AppLogger().info(
      'CRC类型设置为 ${type.name}，多项式=${serialService.crcPolyName}',
      category: 'DATA',
    );
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcPolyName(String name) {
    if (serialService.crcPolyName == name) return;
    serialService.crcPolyName = name;
    AppLogger().info('CRC多项式设置为 $name', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
  }

  void setTimeWindowUs(int us) {
    serialService.setTimeWindowUs(us);
  }

  void setDisplayLineLimit(int value) {
    serialService.setDisplayLineLimit(value);
  }

  void clearData() {
    AppLogger().info('用户清空数据收发接收区', category: 'DATA');
    serialService.clearReceivedData();
  }

  Uint8List? prepareSendData(String text) =>
      serialService.prepareSendData(text);
  void send(Uint8List data) {
    AppLogger().info('用户手动发送数据 ${data.length} bytes', category: 'DATA');
    serialService.send(data);
  }

  Future<void> sendShellText(String text) async {
    if (text.isEmpty || isYmodemActive) return;
    AppLogger().info('Shell命令行发送 ${text.length} 字符', category: 'DATA');
    serialService.sendRawBytes(serialService.prepareShellTextData(text));
  }

  Future<void> sendShellBytes(Uint8List data) async {
    if (data.isEmpty || isYmodemActive) return;
    AppLogger().info('Shell逐键发送 ${data.length} bytes', category: 'DATA');
    await serialService.sendRawBytes(data);
  }

  Future<void> sendYmodemFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) {
    AppLogger().info(
      '开始YMODEM发送：${file.path}，分包=${packetSizeMode.name}',
      category: 'DATA',
    );
    return serialService.ymodemService.sendFile(
      file,
      packetSizeMode: packetSizeMode,
    );
  }

  Future<File?> receiveYmodemFile() {
    AppLogger().info('开始YMODEM接收', category: 'DATA');
    return serialService.receiveYmodemFile();
  }

  Future<void> cancelYmodem() {
    AppLogger().info('用户取消YMODEM传输', category: 'DATA');
    return serialService.ymodemService.cancel();
  }

  Future<String?> exportAsText() => serialService.exportAsText();
  Future<String?> exportAsRawBytes() => serialService.exportAsRawBytes();
  Map<String, String> get dataStats => serialService.dataStats;
}
