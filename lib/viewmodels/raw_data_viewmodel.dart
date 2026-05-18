import 'dart:typed_data';

import '../core/utils/crc.dart';
import '../services/serial_service.dart';
import 'base_viewmodel.dart';

/// 原始数据页面 ViewModel
class RawDataViewModel extends BaseViewModel {
  RawDataViewModel(super.serialService);

  List<String> get receivedLines => serialService.receivedLines;
  bool get isConnected => serialService.isConnected;
  bool get receiveHex => serialService.receiveHex;
  bool get showTimestamp => serialService.showTimestamp;
  bool get autoScroll => serialService.autoScroll;
  bool get sendHex => serialService.sendHex;
  bool get enableCrc => serialService.enableCrc;
  CrcType get crcType => serialService.crcType;
  String get crcPolyName => serialService.crcPolyName;

  void setReceiveHex(bool value) {
    serialService.receiveHex = value;
    serialService.notifyListeners();
  }

  void setShowTimestamp(bool value) {
    serialService.showTimestamp = value;
    serialService.notifyListeners();
  }

  void setAutoScroll(bool value) {
    serialService.autoScroll = value;
    serialService.notifyListeners();
  }

  void setSendHex(bool value) {
    serialService.sendHex = value;
    if (!value) serialService.enableCrc = false;
    serialService.notifyListeners();
  }

  void setEnableCrc(bool value) {
    serialService.enableCrc = value;
    serialService.notifyListeners();
  }

  void setCrcType(CrcType type) {
    serialService.crcType = type;
    final polys = getPolysByType(type);
    if (polys.isNotEmpty) {
      serialService.crcPolyName = polys.keys.first;
    }
    serialService.notifyListeners();
  }

  void setCrcPolyName(String name) {
    serialService.crcPolyName = name;
    serialService.notifyListeners();
  }

  void clearData() => serialService.clearReceivedData();

  Uint8List? prepareSendData(String text) => serialService.prepareSendData(text);
  void send(Uint8List data) => serialService.send(data);

  Future<String?> exportAsText() => serialService.exportAsText();
  Future<String?> exportAsRawBytes() => serialService.exportAsRawBytes();
  Map<String, String> get dataStats => serialService.dataStats;
}


