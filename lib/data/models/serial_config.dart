/// 串口配置模型
class SerialConfig {
  String? port;
  int baudRate;
  int dataBits;
  int stopBits;
  int parity;
  bool rts;
  bool dtr;

  SerialConfig({
    this.port,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 0, // SerialPortParity.none
    this.rts = false,
    this.dtr = false,
  });

  SerialConfig copyWith({
    String? port,
    int? baudRate,
    int? dataBits,
    int? stopBits,
    int? parity,
    bool? rts,
    bool? dtr,
  }) {
    return SerialConfig(
      port: port ?? this.port,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      stopBits: stopBits ?? this.stopBits,
      parity: parity ?? this.parity,
      rts: rts ?? this.rts,
      dtr: dtr ?? this.dtr,
    );
  }
}
