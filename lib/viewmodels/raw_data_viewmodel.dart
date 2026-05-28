import 'dart:typed_data';

import '../core/utils/crc.dart';
import 'base_viewmodel.dart';

/// 数据收发页面 ViewModel
class RawDataViewModel extends BaseViewModel {
  RawDataViewModel(super.serialService);

  List<String> get receivedLines => serialService.receivedLines;
  bool get isConnected => serialService.isConnected;
  bool get receiveHex => serialService.receiveHex;
  bool get showTimestamp => serialService.showTimestamp;
  bool get autoScroll => serialService.autoScroll;
  bool get sendHex => serialService.sendHex;
  bool get enableCrc => serialService.enableCrc;
  bool get crcReverseBytes => serialService.crcReverseBytes;
  CrcType get crcType => serialService.crcType;
  String get crcPolyName => serialService.crcPolyName;
  bool get useRandomSource => serialService.useRandomSource;
  bool get isRawReceiving => serialService.isRawReceiving;
  int get timeWindowUs => serialService.timeWindowUs;

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

  void setShowTimestamp(bool value) {
    serialService.setShowTimestamp(value);
  }

  void setAutoScroll(bool value) {
    serialService.autoScroll = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setSendHex(bool value) {
    serialService.sendHex = value;
    if (!value) serialService.enableCrc = false;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setEnableCrc(bool value) {
    serialService.enableCrc = value;
    Future.microtask(() => serialService.notifyListeners());
  }

  void setCrcReverseBytes(bool value) {
    serialService.crcReverseBytes = value;
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

  void clearData() => serialService.clearReceivedData();

  Uint8List? prepareSendData(String text) =>
      serialService.prepareSendData(text);
  void send(Uint8List data) => serialService.send(data);

  Future<String?> exportAsText() => serialService.exportAsText();
  Future<String?> exportAsRawBytes() => serialService.exportAsRawBytes();
  Map<String, String> get dataStats => serialService.dataStats;
}
