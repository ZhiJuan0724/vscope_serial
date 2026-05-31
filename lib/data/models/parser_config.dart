import 'channel_config.dart';

/// 解析器类型
enum ParserType {
  fireWater('FireWater'),
  justFloat('JustFloat'),
  fixedFrame('固定帧协议'),
  zobow('众邦电控');

  final String label;

  const ParserType(this.label);
}

/// 绘图开始时使用的发送协议。
enum SendProtocolType {
  none('无'),
  rProtocol('r协议'),
  zobowBuiltIn('众邦内置');

  final String label;

  const SendProtocolType(this.label);
}

/// 协议来源。预留给后续 Lua 扩展。
enum ProtocolSource { builtIn, lua }

/// 发送协议配置。
class SendProtocolConfig {
  static const int maxChannelCount = 16;

  SendProtocolType type;
  ProtocolSource source;
  String? customProtocolId;
  List<String> rChannelAddresses;

  SendProtocolConfig({
    this.type = SendProtocolType.none,
    this.source = ProtocolSource.builtIn,
    this.customProtocolId,
    List<String>? rChannelAddresses,
  }) : rChannelAddresses = _normalizeAddresses(rChannelAddresses);

  static List<String> _normalizeAddresses(List<String>? values) {
    final result = List<String>.from(values ?? const []);
    while (result.length < maxChannelCount) {
      result.add('');
    }
    return result.take(maxChannelCount).map((value) => value.trim()).toList();
  }
}

/// 校验类型
enum ChecksumType {
  none('无校验'),
  sum8('SUM8'),
  sum16('SUM16'),
  crc8('CRC-8'),
  crc16('CRC-16'),
  crc32('CRC-32');

  final String label;

  const ChecksumType(this.label);
}

enum ChecksumPosition {
  beforeFrameTail('帧尾前'),
  afterFrameTail('帧尾后');

  final String label;

  const ChecksumPosition(this.label);
}

enum ChecksumEndian {
  big('大端'),
  little('小端');

  final String label;

  const ChecksumEndian(this.label);
}

/// 解析器配置模型
class ParserConfig {
  static const int minZobowChannelCount = 4;
  static const int maxZobowChannelCount = 8;

  /// 解析器类型
  ParserType type;
  ProtocolSource source;
  String? customProtocolId;

  // ========== FireWater 参数 ==========
  /// FireWater 通道数（0=自动识别）
  int fireWaterChannelCount;

  // ========== 固定帧参数 ==========
  /// 是否有帧头
  bool hasFrameHeader;

  /// 帧头长度 1-4 字节
  int frameHeaderLength;

  /// 帧头字节值
  List<int> frameHeader;

  /// 数据类型
  DataType dataType;

  /// 固定帧通道是否使用统一数据类型
  bool fixedFrameUniformDataType;

  /// 固定帧逐通道数据类型
  List<DataType> fixedFrameChannelTypes;

  /// 通道数。JustFloat 使用 0 表示自动识别，其它固定长度协议使用 1-16。
  int channelCount;

  /// 是否有校验
  bool hasChecksum;

  /// 校验类型
  ChecksumType checksumType;

  /// 校验字节数
  int checksumBytes;

  /// 校验位于帧尾前或帧尾后
  ChecksumPosition checksumPosition;

  /// CRC 多项式名称
  String crcPolynomialName;

  /// CRC 字节序
  ChecksumEndian checksumEndian;

  /// 是否有帧尾
  bool hasFrameTail;

  /// 帧尾字节
  List<int>? frameTail;

  // ========== 众邦电控参数 ==========
  /// 众邦电控通道号（4字节16进制），支持4或8通道。
  List<int> zobowChannelIds;

  /// 众邦电控通道数据类型（可单独设置uint16/int16）。
  List<DataType> zobowChannelTypes;

  ParserConfig({
    this.type = ParserType.fireWater,
    this.source = ProtocolSource.builtIn,
    this.customProtocolId,
    this.hasFrameHeader = true,
    this.frameHeaderLength = 2,
    List<int>? frameHeader,
    this.dataType = DataType.uint16,
    this.fixedFrameUniformDataType = true,
    List<DataType>? fixedFrameChannelTypes,
    this.channelCount = 4,
    this.fireWaterChannelCount = 0,
    this.hasChecksum = false,
    this.checksumType = ChecksumType.none,
    this.checksumBytes = 1,
    this.checksumPosition = ChecksumPosition.beforeFrameTail,
    this.crcPolynomialName = 'CRC-16/MODBUS',
    this.checksumEndian = ChecksumEndian.big,
    this.hasFrameTail = false,
    this.frameTail,
    List<int>? zobowChannelIds,
    List<DataType>? zobowChannelTypes,
  }) : frameHeader = frameHeader ?? [0xAA, 0x55],
       fixedFrameChannelTypes = _normalizeFixedFrameChannelTypes(
         fixedFrameChannelTypes,
       ),
       zobowChannelIds = _normalizeZobowChannelIds(zobowChannelIds),
       zobowChannelTypes = _normalizeZobowChannelTypes(zobowChannelTypes);

  /// 计算单帧数据长度（不含帧头、校验、帧尾）
  int get dataBytesPerFrame =>
      fixedFrameUniformDataType
          ? dataType.byteSize * channelCount
          : fixedFrameChannelTypes
              .take(channelCount)
              .fold(0, (sum, type) => sum + type.byteSize);

  DataType fixedFrameChannelTypeAt(int index) =>
      fixedFrameUniformDataType ? dataType : fixedFrameChannelTypes[index];

  int get zobowChannelCount =>
      channelCount >= maxZobowChannelCount
          ? maxZobowChannelCount
          : minZobowChannelCount;

  /// 计算完整帧长度
  int get totalFrameLength {
    int len = (hasFrameHeader ? frameHeaderLength : 0) + dataBytesPerFrame;
    if (hasChecksum) len += effectiveChecksumBytes;
    if (hasFrameTail && frameTail != null) len += frameTail!.length;
    return len;
  }

  int get effectiveChecksumBytes {
    return switch (checksumType) {
      ChecksumType.none => 0,
      ChecksumType.sum8 || ChecksumType.crc8 => 1,
      ChecksumType.sum16 || ChecksumType.crc16 => 2,
      ChecksumType.crc32 => 4,
    };
  }

  String? get fixedFrameValidationError {
    if (channelCount < 1 || channelCount > 16) {
      return '固定帧协议通道数必须为 1~16';
    }
    final tail = hasFrameTail ? (frameTail ?? const <int>[]) : const <int>[];
    final headerIsZero =
        !hasFrameHeader ||
        frameHeader.take(frameHeaderLength).every((b) => b == 0);
    final tailIsZero = tail.isEmpty || tail.every((b) => b == 0);
    if (headerIsZero && tailIsZero) {
      return '固定帧协议的帧头和帧尾不能同时全部为 0';
    }
    if (hasFrameTail && tail.isEmpty) {
      return '启用帧尾后至少需要填写一个字节';
    }
    return null;
  }

  ParserConfig copyWith({
    ParserType? type,
    ProtocolSource? source,
    String? customProtocolId,
    bool? hasFrameHeader,
    int? frameHeaderLength,
    List<int>? frameHeader,
    DataType? dataType,
    bool? fixedFrameUniformDataType,
    List<DataType>? fixedFrameChannelTypes,
    int? channelCount,
    bool? hasChecksum,
    ChecksumType? checksumType,
    int? checksumBytes,
    ChecksumPosition? checksumPosition,
    String? crcPolynomialName,
    ChecksumEndian? checksumEndian,
    bool? hasFrameTail,
    List<int>? frameTail,
    List<int>? zobowChannelIds,
    List<DataType>? zobowChannelTypes,
  }) {
    return ParserConfig(
      type: type ?? this.type,
      source: source ?? this.source,
      customProtocolId: customProtocolId ?? this.customProtocolId,
      hasFrameHeader: hasFrameHeader ?? this.hasFrameHeader,
      frameHeaderLength: frameHeaderLength ?? this.frameHeaderLength,
      frameHeader: frameHeader ?? List.from(this.frameHeader),
      dataType: dataType ?? this.dataType,
      fixedFrameUniformDataType:
          fixedFrameUniformDataType ?? this.fixedFrameUniformDataType,
      fixedFrameChannelTypes:
          fixedFrameChannelTypes ?? List.from(this.fixedFrameChannelTypes),
      channelCount: channelCount ?? this.channelCount,
      fireWaterChannelCount: fireWaterChannelCount,
      hasChecksum: hasChecksum ?? this.hasChecksum,
      checksumType: checksumType ?? this.checksumType,
      checksumBytes: checksumBytes ?? this.checksumBytes,
      checksumPosition: checksumPosition ?? this.checksumPosition,
      crcPolynomialName: crcPolynomialName ?? this.crcPolynomialName,
      checksumEndian: checksumEndian ?? this.checksumEndian,
      hasFrameTail: hasFrameTail ?? this.hasFrameTail,
      frameTail:
          frameTail ??
          (this.frameTail != null ? List.from(this.frameTail!) : null),
      zobowChannelIds: zobowChannelIds ?? List.from(this.zobowChannelIds),
      zobowChannelTypes: zobowChannelTypes ?? List.from(this.zobowChannelTypes),
    );
  }

  /// 创建默认 FireWater 配置
  factory ParserConfig.fireWaterDefault() {
    return ParserConfig(type: ParserType.fireWater, fireWaterChannelCount: 0);
  }

  /// 创建默认固定帧配置
  factory ParserConfig.fixedFrameDefault() {
    return ParserConfig(
      type: ParserType.fixedFrame,
      frameHeaderLength: 2,
      frameHeader: [0xAA, 0x55],
      dataType: DataType.uint16,
      channelCount: 4,
    );
  }

  /// 创建默认 众邦电控配置
  factory ParserConfig.zobowDefault() {
    return ParserConfig(
      type: ParserType.zobow,
      channelCount: minZobowChannelCount,
      zobowChannelIds: List.generate(maxZobowChannelCount, (i) => i + 1),
      zobowChannelTypes: List.filled(maxZobowChannelCount, DataType.uint16),
    );
  }

  /// 创建默认 VOFA JustFloat 配置
  factory ParserConfig.justFloatDefault() {
    return ParserConfig(type: ParserType.justFloat, channelCount: 0);
  }

  static List<int> _normalizeZobowChannelIds(List<int>? ids) {
    final values = List<int>.from(
      ids ?? List.generate(maxZobowChannelCount, (i) => i + 1),
    );
    while (values.length < maxZobowChannelCount) {
      values.add(values.length + 1);
    }
    return values.take(maxZobowChannelCount).toList();
  }

  static List<DataType> _normalizeFixedFrameChannelTypes(
    List<DataType>? types,
  ) {
    final values = List<DataType>.from(
      types ?? List.filled(SendProtocolConfig.maxChannelCount, DataType.uint16),
    );
    while (values.length < SendProtocolConfig.maxChannelCount) {
      values.add(DataType.uint16);
    }
    return values.take(SendProtocolConfig.maxChannelCount).toList();
  }

  static List<DataType> _normalizeZobowChannelTypes(List<DataType>? types) {
    final values = List<DataType>.from(
      types ?? List.filled(maxZobowChannelCount, DataType.uint16),
    );
    while (values.length < maxZobowChannelCount) {
      values.add(DataType.uint16);
    }
    return values.take(maxZobowChannelCount).toList();
  }
}
