import 'dart:typed_data';

/// 连接窗口中明确选择的探针后端。
///
/// `automatic` 只在工具缺失时回退，不会在目标连接失败后偷偷切换后端。
enum RttBackendSelection {
  automatic('automatic', '自动'),
  externalJlink('external-jlink', '外部 J-Link'),
  bundledOpenocd('bundled-openocd', '内置 OpenOCD'),
  externalOpenocd('external-openocd', '外置 OpenOCD'),
  externalPyocd('external-pyocd', '外置 pyOCD');

  const RttBackendSelection(this.value, this.label);
  final String value;
  final String label;

  static RttBackendSelection fromString(String? value) => switch (value) {
    'external-jlink' => externalJlink,
    'bundled-openocd' => bundledOpenocd,
    'external-openocd' => externalOpenocd,
    'external-pyocd' => externalPyocd,
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

/// 外置 pyOCD 枚举 CMSIS-DAP 时允许使用的 USB 传输版本。
///
/// 显式选择 v1 或 v2 时不得触碰另一条枚举路径，避免慢设备拖累连接。
enum PyOcdCmsisDapVersion {
  automatic('automatic', '自动'),
  v1('v1', '仅 v1'),
  v2('v2', '仅 v2');

  const PyOcdCmsisDapVersion(this.value, this.label);
  final String value;
  final String label;

  static PyOcdCmsisDapVersion fromString(String? value) => switch (value) {
    'v1' => v1,
    'v2' => v2,
    _ => automatic,
  };
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

enum RttConnectionState {
  disconnected,
  discovering,
  connecting,
  reconnecting,
  connected,
}

/// 当前占用探针会话的数据功能。
///
/// 探针连接本身不代表功能已经开始。空闲连接允许在两个探针页面间切换，
/// 功能开始后则由主框架锁定到对应页面。
enum ProbeActivityOwner { none, rttViewer, probePlot }

/// RTT 后端向上层声明的可选能力。
enum RttBackendCapability {
  /// 能够向 RTT Down 0 写入数据。
  downChannel0,

  /// 能够在保持探针连接的情况下启动和停止 RTT 数据流。
  independentActivity,

  /// 能够执行通用后台内存采样。
  memorySampling,

  /// 能够读取 RTT 通道名称和元数据。
  channelMetadata,
}

class RttProbeInfo {
  const RttProbeInfo({
    required this.id,
    required this.name,
    required this.kind,
    this.available = true,
    this.usbVendorId,
    this.usbProductId,
  });

  final String id;
  final String name;
  final RttProbeKind kind;
  final bool available;

  /// 轻量 USB 刷新得到的设备标识；存在时连接后端应优先定向检查该设备。
  final int? usbVendorId;
  final int? usbProductId;
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
    this.backend = RttBackendSelection.automatic,
    this.probeId = '',
    this.usbVendorId,
    this.usbProductId,
    this.autoDetectTarget = false,
    this.wireProtocol = RttWireProtocol.swd,
    this.clockKhz = 4000,
    this.controlBlockMode = RttControlBlockMode.automatic,
    this.controlBlockAddress,
    this.controlBlockRangeStart,
    this.controlBlockRangeEnd,
    this.pollingIntervalMs = 10,
    this.openOcdInterfaceConfig = '',
    this.openOcdTargetConfig = '',
    this.pyOcdCmsisDapVersion = PyOcdCmsisDapVersion.automatic,
  });

  final RttBackendSelection backend;
  final RttProbeKind probeKind;
  final String probeId;

  /// 用户显式选择 USB 设备时保存；为空表示由后端自动发现探针。
  final int? usbVendorId;
  final int? usbProductId;
  final String target;
  final bool autoDetectTarget;
  final RttWireProtocol wireProtocol;
  final int clockKhz;
  final RttControlBlockMode controlBlockMode;
  final int? controlBlockAddress;
  final int? controlBlockRangeStart;
  final int? controlBlockRangeEnd;
  final int pollingIntervalMs;
  final String openOcdInterfaceConfig;
  final String openOcdTargetConfig;
  final PyOcdCmsisDapVersion pyOcdCmsisDapVersion;

  RttConnectionConfig copyWithControlBlock(RttControlBlockConfig value) {
    return RttConnectionConfig(
      backend: backend,
      probeKind: probeKind,
      probeId: probeId,
      usbVendorId: usbVendorId,
      usbProductId: usbProductId,
      target: target,
      autoDetectTarget: autoDetectTarget,
      wireProtocol: wireProtocol,
      clockKhz: clockKhz,
      controlBlockMode: value.mode,
      controlBlockAddress: value.address,
      controlBlockRangeStart: value.rangeStart,
      controlBlockRangeEnd: value.rangeEnd,
      pollingIntervalMs: value.pollingIntervalMs,
      openOcdInterfaceConfig: openOcdInterfaceConfig,
      openOcdTargetConfig: openOcdTargetConfig,
      pyOcdCmsisDapVersion: pyOcdCmsisDapVersion,
    );
  }
}

/// 仅在 RTT Viewer 或 RTT 绘图开始时使用的 RTT 接收参数。
class RttControlBlockConfig {
  const RttControlBlockConfig({
    required this.mode,
    this.address,
    this.rangeStart,
    this.rangeEnd,
    this.pollingIntervalMs = 10,
  });

  final RttControlBlockMode mode;
  final int? address;
  final int? rangeStart;
  final int? rangeEnd;
  final int pollingIntervalMs;
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
