import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/retention_usage.dart';
import '../services/serial_service.dart';
import 'base_viewmodel.dart';

/// 数据收发页面 ViewModel
class RawDataViewModel extends BaseViewModel {
  RawDataViewModel(super.serialService);

  List<String> get receivedLines => serialService.receivedLines;
  int get displayRevision => serialService.displayRevision;
  int get displayTrimRevision => serialService.displayTrimRevision;
  List<String> get lastTrimmedDisplayLines =>
      serialService.lastTrimmedDisplayLines;
  bool get isConnected => serialService.isConnected;
  bool get receiveHex => serialService.receiveHex;
  bool get showTimestamp => serialService.showTimestamp;
  bool get autoLineBreak => serialService.autoLineBreak;
  bool get autoScroll => serialService.autoScroll;
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
  bool get hasRawData => serialService.hasRawData;
  RetentionUsage get rawRetentionUsage => serialService.rawRetentionUsage;
  int get autoLineBreakIntervalMs => serialService.autoLineBreakIntervalMs;
  int get displayLineLimit => serialService.displayLineLimit;
  String get textEncoding => serialService.textEncoding;

  /// 非 HEX 模式可选的文本收发编码。
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

  void setTextEncoding(String encoding) {
    serialService.setTextEncoding(encoding);
  }

  void setShowTimestamp(bool value) {
    serialService.setShowTimestamp(value);
  }

  void setAutoLineBreak(bool value) {
    serialService.setAutoLineBreak(value);
  }

  void setAutoScroll(bool value) {
    if (serialService.autoScroll == value) return;
    serialService.autoScroll = value;
    AppLogger().info('接收区自动滚动${value ? '启用' : '关闭'}', category: 'DATA');
    Future.microtask(() => serialService.notifyListeners());
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

  void setAutoLineBreakIntervalMs(int milliseconds) {
    serialService.setAutoLineBreakIntervalMs(milliseconds);
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
  Uint8List? prepareMultiSendData(String text, {required bool isHex}) =>
      serialService.prepareMultiSendData(text, isHex: isHex);
  Future<void> send(Uint8List data) {
    if (!isRawReceiving) {
      throw StateError('请先开始数据接收');
    }
    AppLogger().info('用户手动发送数据 ${data.length} bytes', category: 'DATA');
    return serialService.send(data);
  }

  Future<String?> exportAsText({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) => serialService.exportAsText(
    outputDirectory: outputDirectory,
    onProgress: onProgress,
  );
  Future<String?> exportAsRawBytes({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) => serialService.exportAsRawBytes(
    outputDirectory: outputDirectory,
    onProgress: onProgress,
  );
  Map<String, String> get dataStats => serialService.dataStats;
}
