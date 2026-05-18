/// 数据源配置模型
class DataSourceConfig {
  /// 使用串口数据源
  bool useSerial;

  /// 使用内部随机数据源
  bool useRandom;

  /// 随机数据源通道数
  int randomChannelCount;

  /// 随机数据源数值最小值
  double randomMinValue;

  /// 随机数据源数值最大值
  double randomMaxValue;

  /// 随机数据源生成间隔（毫秒）
  int randomIntervalMs;

  DataSourceConfig({
    this.useSerial = true,
    this.useRandom = false,
    this.randomChannelCount = 4,
    this.randomMinValue = 0.0,
    this.randomMaxValue = 32768.0,
    this.randomIntervalMs = 100,
  });

  DataSourceConfig copyWith({
    bool? useSerial,
    bool? useRandom,
    int? randomChannelCount,
    double? randomMinValue,
    double? randomMaxValue,
    int? randomIntervalMs,
  }) {
    return DataSourceConfig(
      useSerial: useSerial ?? this.useSerial,
      useRandom: useRandom ?? this.useRandom,
      randomChannelCount: randomChannelCount ?? this.randomChannelCount,
      randomMinValue: randomMinValue ?? this.randomMinValue,
      randomMaxValue: randomMaxValue ?? this.randomMaxValue,
      randomIntervalMs: randomIntervalMs ?? this.randomIntervalMs,
    );
  }

  /// 是否有有效数据源
  bool get hasActiveSource => useSerial || useRandom;
}
