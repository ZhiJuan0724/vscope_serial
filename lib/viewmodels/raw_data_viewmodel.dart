import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/retention_usage.dart';
import '../services/data_connection_service.dart';
import 'base_viewmodel.dart';
import 'settings_drafts.dart';

/// 数据收发页面 ViewModel
class RawDataViewModel extends BaseViewModel {
  RawDataViewModel(super.connectionService);

  List<String> get receivedLines => connectionService.receivedLines;
  int get displayRevision => connectionService.displayRevision;
  int get displayTrimRevision => connectionService.displayTrimRevision;
  List<String> get lastTrimmedDisplayLines =>
      connectionService.lastTrimmedDisplayLines;
  bool get isConnected => connectionService.isConnected;
  bool get receiveHex => connectionService.receiveHex;
  bool get showTimestamp => connectionService.showTimestamp;
  bool get autoLineBreak => connectionService.autoLineBreak;
  bool get autoScroll => connectionService.autoScroll;
  bool get sendHex => connectionService.sendHex;
  bool get keepSendText => connectionService.keepSendText;
  bool get appendLineEnding => connectionService.appendLineEnding;
  String get lineEnding => connectionService.lineEnding;
  bool get enableCrc => connectionService.enableCrc;
  CrcByteOrder get crcByteOrder => connectionService.crcByteOrder;
  CrcType get crcType => connectionService.crcType;
  String get crcPolyName => connectionService.crcPolyName;
  bool get useRandomSource => connectionService.useRandomSource;
  bool get isRawReceiving => connectionService.isRawReceiving;
  bool get hasRawData => connectionService.hasRawData;
  RetentionUsage get rawRetentionUsage => connectionService.rawRetentionUsage;
  int get autoLineBreakIntervalMs => connectionService.autoLineBreakIntervalMs;
  int get displayLineLimit => connectionService.displayLineLimit;
  String get textEncoding => connectionService.textEncoding;

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
    if (connectionService.useRandomSource == value) return;
    connectionService.setUseRandomSource(value);
    AppLogger().info('数据收发页随机源${value ? '启用' : '关闭'}', category: 'DATA');
  }

  /// 开始接收原始数据
  void startReceiving() => connectionService.startRawReceiving();

  /// 停止接收原始数据
  void stopReceiving() => connectionService.stopRawReceiving();

  void setReceiveHex(bool value) {
    connectionService.setReceiveHex(value);
  }

  void setTextEncoding(String encoding) {
    connectionService.setTextEncoding(encoding);
  }

  void setShowTimestamp(bool value) {
    connectionService.setShowTimestamp(value);
  }

  void setAutoLineBreak(bool value) {
    connectionService.setAutoLineBreak(value);
  }

  void setAutoScroll(bool value) {
    if (connectionService.autoScroll == value) return;
    connectionService.setAutoScroll(value);
    AppLogger().info('接收区自动滚动${value ? '启用' : '关闭'}', category: 'DATA');
  }

  void setSendHex(bool value) {
    if (connectionService.sendHex == value) return;
    connectionService.setSendHex(value);
    AppLogger().info(
      '发送格式切换为${value ? 'HEX' : '文本'}${value ? '' : '，CRC已关闭'}',
      category: 'DATA',
    );
  }

  void setKeepSendText(bool value) {
    if (connectionService.keepSendText == value) return;
    connectionService.setKeepSendText(value);
    AppLogger().info('发送后${value ? '保留' : '清空'}输入内容', category: 'DATA');
  }

  void setAppendLineEnding(bool value) {
    if (connectionService.appendLineEnding == value) return;
    connectionService.setAppendLineEnding(value);
    AppLogger().info('发送行尾追加${value ? '启用' : '关闭'}', category: 'DATA');
  }

  void setLineEnding(String value) {
    if (connectionService.lineEnding == value) return;
    connectionService.setLineEnding(value);
    AppLogger().info(
      '发送行尾设置为 ${value.replaceAll('\r', r'\r').replaceAll('\n', r'\n')}',
      category: 'DATA',
    );
  }

  void setEnableCrc(bool value) {
    if (connectionService.enableCrc == value) return;
    connectionService.setEnableCrc(value);
    AppLogger().info('发送CRC${value ? '启用' : '关闭'}', category: 'DATA');
  }

  void setCrcByteOrder(CrcByteOrder value) {
    if (connectionService.crcByteOrder == value) return;
    connectionService.setCrcByteOrder(value);
    AppLogger().info('CRC字节序设置为 ${value.label}', category: 'DATA');
  }

  void setCrcType(CrcType type) {
    if (connectionService.crcType == type) return;
    connectionService.setCrcType(type);
    AppLogger().info(
      'CRC类型设置为 ${type.name}，多项式=${connectionService.crcPolyName}',
      category: 'DATA',
    );
  }

  void setCrcPolyName(String name) {
    if (connectionService.crcPolyName == name) return;
    connectionService.setCrcPolyName(name);
    AppLogger().info('CRC多项式设置为 $name', category: 'DATA');
  }

  void setAutoLineBreakIntervalMs(int milliseconds) {
    connectionService.setAutoLineBreakIntervalMs(milliseconds);
  }

  void setDisplayLineLimit(int value) {
    connectionService.setDisplayLineLimit(value);
  }

  Future<void> applyDisplaySettings(RawDisplaySettingsDraft draft) =>
      connectionService.applyRawDisplaySettings(
        encoding: draft.encoding,
        autoLineBreakIntervalMs: draft.autoLineBreakIntervalMs,
        displayLineLimit: draft.displayLineLimit,
      );

  void clearData() {
    AppLogger().info('用户清空数据收发接收区', category: 'DATA');
    connectionService.clearReceivedData();
  }

  Uint8List? prepareSendData(String text) =>
      connectionService.prepareSendData(text);
  Uint8List? prepareMultiSendData(String text, {required bool isHex}) =>
      connectionService.prepareMultiSendData(text, isHex: isHex);
  Future<void> send(Uint8List data) {
    if (!isRawReceiving) {
      throw StateError('请先开始数据接收');
    }
    AppLogger().info('用户手动发送数据 ${data.length} bytes', category: 'DATA');
    return connectionService.send(data);
  }

  Future<String?> exportAsText({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) => connectionService.exportAsText(
    outputDirectory: outputDirectory,
    onProgress: onProgress,
  );
  Future<String?> exportAsRawBytes({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) => connectionService.exportAsRawBytes(
    outputDirectory: outputDirectory,
    onProgress: onProgress,
  );
  Map<String, String> get dataStats => connectionService.dataStats;
}
