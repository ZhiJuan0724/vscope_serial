enum ProgrammingBackendSelection {
  automatic('automatic', '自动'),
  externalJlink('external-jlink', '外部 J-Link'),
  externalOpenocd('external-openocd', '外置 OpenOCD'),
  bundledOpenocd('bundled-openocd', '内置 OpenOCD');

  const ProgrammingBackendSelection(this.value, this.label);
  final String value;
  final String label;

  static ProgrammingBackendSelection fromString(String? value) =>
      values.firstWhere((item) => item.value == value, orElse: () => automatic);
}

enum FlashProbeKind {
  jlink('jlink', 'J-Link'),
  cmsisDap('cmsis-dap', 'CMSIS-DAP');

  const FlashProbeKind(this.value, this.label);
  final String value;
  final String label;

  static FlashProbeKind fromString(String? value) =>
      value == cmsisDap.value ? cmsisDap : jlink;
}

enum FlashWireProtocol {
  swd('swd', 'SWD'),
  jtag('jtag', 'JTAG');

  const FlashWireProtocol(this.value, this.label);
  final String value;
  final String label;

  static FlashWireProtocol fromString(String? value) =>
      value == jtag.value ? jtag : swd;
}

enum FlashOperationState {
  disconnected,
  connecting,
  connected,
  erasing,
  programming,
  verifying,
  reading,
  disconnecting,
  unknown,
}

class FlashConnectionConfig {
  const FlashConnectionConfig({
    this.backend = ProgrammingBackendSelection.automatic,
    this.probeKind = FlashProbeKind.jlink,
    this.probeId = '',
    this.target = '',
    this.wireProtocol = FlashWireProtocol.swd,
    this.clockKhz = 4000,
    this.jlinkExecutablePath = '',
    this.openocdExecutablePath = '',
    this.openOcdInterfaceConfig = '',
    this.openOcdTargetConfig = '',
  });

  final ProgrammingBackendSelection backend;
  final FlashProbeKind probeKind;
  final String probeId;
  final String target;
  final FlashWireProtocol wireProtocol;
  final int clockKhz;
  final String jlinkExecutablePath;
  final String openocdExecutablePath;
  final String openOcdInterfaceConfig;
  final String openOcdTargetConfig;

  Map<String, Object?> toJson() => {
    'backend': backend.value,
    'probeKind': probeKind.value,
    'probeId': probeId,
    'target': target,
    'wireProtocol': wireProtocol.value,
    'clockKhz': clockKhz,
    'jlinkExecutablePath': jlinkExecutablePath,
    'openocdExecutablePath': openocdExecutablePath,
    'openOcdInterfaceConfig': openOcdInterfaceConfig,
    'openOcdTargetConfig': openOcdTargetConfig,
  };

  factory FlashConnectionConfig.fromJson(Object? value) {
    final json = value is Map ? value : const <Object?, Object?>{};
    return FlashConnectionConfig(
      backend: ProgrammingBackendSelection.fromString(
        json['backend'] as String?,
      ),
      probeKind: FlashProbeKind.fromString(json['probeKind'] as String?),
      probeId: json['probeId'] as String? ?? '',
      target: json['target'] as String? ?? '',
      wireProtocol: FlashWireProtocol.fromString(
        json['wireProtocol'] as String?,
      ),
      clockKhz: ((json['clockKhz'] as num?)?.toInt() ?? 4000).clamp(1, 50000),
      jlinkExecutablePath: json['jlinkExecutablePath'] as String? ?? '',
      openocdExecutablePath: json['openocdExecutablePath'] as String? ?? '',
      openOcdInterfaceConfig: json['openOcdInterfaceConfig'] as String? ?? '',
      openOcdTargetConfig: json['openOcdTargetConfig'] as String? ?? '',
    );
  }

  FlashConnectionConfig copyWith({
    ProgrammingBackendSelection? backend,
    FlashProbeKind? probeKind,
    String? probeId,
    String? target,
    FlashWireProtocol? wireProtocol,
    int? clockKhz,
    String? jlinkExecutablePath,
    String? openocdExecutablePath,
    String? openOcdInterfaceConfig,
    String? openOcdTargetConfig,
  }) => FlashConnectionConfig(
    backend: backend ?? this.backend,
    probeKind: probeKind ?? this.probeKind,
    probeId: probeId ?? this.probeId,
    target: target ?? this.target,
    wireProtocol: wireProtocol ?? this.wireProtocol,
    clockKhz: clockKhz ?? this.clockKhz,
    jlinkExecutablePath: jlinkExecutablePath ?? this.jlinkExecutablePath,
    openocdExecutablePath: openocdExecutablePath ?? this.openocdExecutablePath,
    openOcdInterfaceConfig:
        openOcdInterfaceConfig ?? this.openOcdInterfaceConfig,
    openOcdTargetConfig: openOcdTargetConfig ?? this.openOcdTargetConfig,
  );
}

class FlashProgramRequest {
  const FlashProgramRequest({
    required this.filePath,
    this.binAddress,
    this.erase = true,
    this.verify = true,
    this.keepHalted = false,
  });

  final String filePath;
  final int? binAddress;
  final bool erase;
  final bool verify;
  final bool keepHalted;

  bool get isBinary => filePath.toLowerCase().endsWith('.bin');

  void validate() {
    final extension = filePath.toLowerCase();
    if (!extension.endsWith('.bin') &&
        !extension.endsWith('.elf') &&
        !extension.endsWith('.hex')) {
      throw const FormatException('仅支持 ELF、HEX 和 BIN 文件');
    }
    if (isBinary &&
        (binAddress == null || binAddress! < 0 || binAddress! > 0xFFFFFFFF)) {
      throw const FormatException('BIN文件必须填写有效的32位基地址');
    }
  }
}

class FlashEraseRequest {
  const FlashEraseRequest.chip() : address = null, length = null;
  const FlashEraseRequest.range({required this.address, required this.length});

  final int? address;
  final int? length;
  bool get wholeChip => address == null;
}

class FlashReadRequest {
  const FlashReadRequest({
    required this.address,
    required this.length,
    required this.outputPath,
  });

  final int address;
  final int length;
  final String outputPath;
}
