import '../services/serial_service.dart';
import 'base_viewmodel.dart';

/// 连接页面 ViewModel
class ConnectViewModel extends BaseViewModel {
  ConnectViewModel(super.serialService);

  List<String> get availablePorts => serialService.availablePorts;
  String? get selectedPort => serialService.config.port;
  int get baudRate => serialService.config.baudRate;
  int get dataBits => serialService.config.dataBits;
  int get stopBits => serialService.config.stopBits;
  int get parity => serialService.config.parity;
  bool get rts => serialService.config.rts;
  bool get dtr => serialService.config.dtr;
  bool get isConnected => serialService.isConnected;
  bool get isConnecting => serialService.isConnecting;

  /// 是否使用随机数据源（用于绘图）
  bool get useRandomSource => serialService.useRandomSource;

  void selectPort(String? port) {
    serialService.config = serialService.config.copyWith(port: port);
    serialService.notifyListeners();
  }

  void setBaudRate(int rate) {
    serialService.config = serialService.config.copyWith(baudRate: rate);
    serialService.notifyListeners();
  }

  void setDataBits(int bits) {
    serialService.config = serialService.config.copyWith(dataBits: bits);
    serialService.notifyListeners();
  }

  void setStopBits(int bits) {
    serialService.config = serialService.config.copyWith(stopBits: bits);
    serialService.notifyListeners();
  }

  void setParity(int p) {
    serialService.config = serialService.config.copyWith(parity: p);
    serialService.notifyListeners();
  }

  void setRts(bool value) => serialService.updateRts(value);
  void setDtr(bool value) => serialService.updateDtr(value);

  void setUseRandomSource(bool value) {
    serialService.useRandomSource = value;
    serialService.notifyListeners();
  }

  void refreshPorts() => serialService.refreshPorts();
  Future<void> connect() => serialService.connect();
  void disconnect() => serialService.disconnect();
}
