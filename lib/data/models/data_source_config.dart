import '../../core/constants/plot_configuration.dart';

/// 数据源配置模型
class DataSourceConfig {
  /// 使用串口数据源
  bool useConnection;

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

  /// 随机数据源目标频率（Hz）
  double randomFrequencyHz;

  DataSourceConfig({
    this.useConnection = true,
    this.useRandom = false,
    this.randomChannelCount = 4,
    this.randomMinValue = PlotConfiguration.randomSourceDefaultMin,
    this.randomMaxValue = PlotConfiguration.randomSourceDefaultMax,
    int? randomIntervalMs,
    double? randomFrequencyHz,
  }) : randomIntervalMs = randomIntervalMs ?? 100,
       randomFrequencyHz = (randomFrequencyHz ??
               (randomIntervalMs == null ? 10.0 : 1000.0 / randomIntervalMs))
           .clamp(1.0, 100000.0);

  DataSourceConfig copyWith({
    bool? useConnection,
    bool? useRandom,
    int? randomChannelCount,
    double? randomMinValue,
    double? randomMaxValue,
    int? randomIntervalMs,
    double? randomFrequencyHz,
  }) {
    return DataSourceConfig(
      useConnection: useConnection ?? this.useConnection,
      useRandom: useRandom ?? this.useRandom,
      randomChannelCount: randomChannelCount ?? this.randomChannelCount,
      randomMinValue: randomMinValue ?? this.randomMinValue,
      randomMaxValue: randomMaxValue ?? this.randomMaxValue,
      randomIntervalMs: randomIntervalMs ?? this.randomIntervalMs,
      randomFrequencyHz: randomFrequencyHz ?? this.randomFrequencyHz,
    );
  }

  /// 是否有有效数据源
  bool get hasActiveSource => useConnection || useRandom;
}
