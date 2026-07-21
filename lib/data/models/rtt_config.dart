import 'dart:typed_data';

enum RttBackendMode {
  automatic('automatic', '自动'),
  external('external', '外部'),
  builtin('builtin', '内置');

  const RttBackendMode(this.value, this.label);
  final String value;
  final String label;

  static RttBackendMode fromString(String? value) => switch (value) {
    'external' => external,
    'builtin' => builtin,
    _ => automatic,
  };
}

enum RttProbeKind {
  jlink('jlink', 'J-Link'),
  cmsisDap('cmsisDap', 'CMSIS-DAP');

  const RttProbeKind(this.value, this.label);
  final String value;
  final String label;

  static RttProbeKind fromString(String? value) =>
      value == 'cmsisDap' ? cmsisDap : jlink;
}

enum RttWireProtocol {
  swd('swd', 'SWD'),
  jtag('jtag', 'JTAG');

  const RttWireProtocol(this.value, this.label);
  final String value;
  final String label;

  static RttWireProtocol fromString(String? value) =>
      value == 'jtag' ? jtag : swd;
}

/// RTT 控制块的定位方式。
enum RttControlBlockMode {
  automatic(
    'automatic',
    'Auto',
    '扫描目标定义的 RAM；若当前后端版本不支持或无法找到控制块，请改用指定地址或指定范围。',
  ),
  address('address', '指定地址', '只在给定地址附着 RTT 控制块。'),
  range('range', '指定范围', '仅在给定的起始地址到结束地址之间扫描 RTT 控制块。');

  const RttControlBlockMode(this.value, this.label, this.description);
  final String value;
  final String label;
  final String description;

  static RttControlBlockMode fromString(String? value) => switch (value) {
    'address' => address,
    'range' => range,
    _ => automatic,
  };
}

enum RttDisplayMode {
  text('text', '文本'),
  hex('hex', 'HEX');

  const RttDisplayMode(this.value, this.label);
  final String value;
  final String label;

  static RttDisplayMode fromString(String? value) =>
      value == 'hex' ? hex : text;
}

enum RttConnectionState { disconnected, discovering, connecting, connected }

class RttProbeInfo {
  const RttProbeInfo({
    required this.id,
    required this.name,
    required this.kind,
    this.available = true,
  });

  final String id;
  final String name;
  final RttProbeKind kind;
  final bool available;
}

class RttTargetInfo {
  const RttTargetInfo({required this.name, this.vendor = '', this.source = ''});

  final String name;
  final String vendor;
  final String source;
}

/// 后端无关的 RTT 连接参数。
class RttConnectionConfig {
  const RttConnectionConfig({
    required this.probeKind,
    required this.target,
    this.probeId = '',
    this.autoDetectTarget = false,
    this.wireProtocol = RttWireProtocol.swd,
    this.clockKhz = 4000,
    this.controlBlockMode = RttControlBlockMode.automatic,
    this.controlBlockAddress,
    this.controlBlockRangeStart,
    this.controlBlockRangeEnd,
  });

  final RttProbeKind probeKind;
  final String probeId;
  final String target;
  final bool autoDetectTarget;
  final RttWireProtocol wireProtocol;
  final int clockKhz;
  final RttControlBlockMode controlBlockMode;
  final int? controlBlockAddress;
  final int? controlBlockRangeStart;
  final int? controlBlockRangeEnd;
}

/// RTT 后端交付给页面的数据块；首版只消费 channel=0。
class RttDataChunk {
  const RttDataChunk({
    required this.channel,
    required this.data,
    required this.monotonicUs,
    required this.wallClockUs,
  });

  final int channel;
  final Uint8List data;
  final int monotonicUs;
  final int wallClockUs;
}
