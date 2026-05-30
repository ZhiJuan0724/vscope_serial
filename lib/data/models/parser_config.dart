import 'channel_config.dart';

/// 解析器类型
enum ParserType {
  fireWater('FireWater'),
  fixedFrame('固定帧头'),
  zobow('众邦电控'),
  justFloat('JustFloat');

  final String label;

  const ParserType(this.label);
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

/// 解析器配置模型
class ParserConfig {
  static const int minZobowChannelCount = 4;
  static const int maxZobowChannelCount = 8;

  /// 解析器类型
  ParserType type;

  // ========== FireWater 参数 ==========
  /// FireWater 通道数（0=自动识别）
  int fireWaterChannelCount;

  // ========== 固定帧头参数 ==========
  /// 帧头长度 1-4 字节
  int frameHeaderLength;

  /// 帧头字节值
  List<int> frameHeader;

  /// 数据类型
  DataType dataType;

  /// 通道数。JustFloat 使用 0 表示自动识别，其它固定长度协议使用 1-16。
  int channelCount;

  /// 是否有校验
  bool hasChecksum;

  /// 校验类型
  ChecksumType checksumType;

  /// 校验字节数
  int checksumBytes;

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
    this.frameHeaderLength = 2,
    List<int>? frameHeader,
    this.dataType = DataType.uint16,
    this.channelCount = 4,
    this.fireWaterChannelCount = 0,
    this.hasChecksum = false,
    this.checksumType = ChecksumType.none,
    this.checksumBytes = 1,
    this.hasFrameTail = false,
    this.frameTail,
    List<int>? zobowChannelIds,
    List<DataType>? zobowChannelTypes,
  }) : frameHeader = frameHeader ?? [0xAA, 0x55],
       zobowChannelIds = _normalizeZobowChannelIds(zobowChannelIds),
       zobowChannelTypes = _normalizeZobowChannelTypes(zobowChannelTypes);

  /// 计算单帧数据长度（不含帧头、校验、帧尾）
  int get dataBytesPerFrame => dataType.byteSize * channelCount;

  int get zobowChannelCount =>
      channelCount >= maxZobowChannelCount
          ? maxZobowChannelCount
          : minZobowChannelCount;

  /// 计算完整帧长度
  int get totalFrameLength {
    int len = frameHeaderLength + dataBytesPerFrame;
    if (hasChecksum) len += checksumBytes;
    if (hasFrameTail && frameTail != null) len += frameTail!.length;
    return len;
  }

  ParserConfig copyWith({
    ParserType? type,
    int? frameHeaderLength,
    List<int>? frameHeader,
    DataType? dataType,
    int? channelCount,
    bool? hasChecksum,
    ChecksumType? checksumType,
    int? checksumBytes,
    bool? hasFrameTail,
    List<int>? frameTail,
    List<int>? zobowChannelIds,
    List<DataType>? zobowChannelTypes,
  }) {
    return ParserConfig(
      type: type ?? this.type,
      frameHeaderLength: frameHeaderLength ?? this.frameHeaderLength,
      frameHeader: frameHeader ?? List.from(this.frameHeader),
      dataType: dataType ?? this.dataType,
      channelCount: channelCount ?? this.channelCount,
      fireWaterChannelCount: fireWaterChannelCount,
      hasChecksum: hasChecksum ?? this.hasChecksum,
      checksumType: checksumType ?? this.checksumType,
      checksumBytes: checksumBytes ?? this.checksumBytes,
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

  /// 创建默认固定帧头配置
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
