/// 绘图页面、视口和数据模型之间共用的配置。
abstract final class PlotConfiguration {
  // 通道面板布局。

  /// 常规协议下通道面板允许缩放到的最小宽度。
  static const double channelPanelMinWidth = 260;

  /// 地址内容较短时通道面板允许使用的紧凑宽度。
  static const double channelPanelCompactWidth = 212;

  /// 通道面板允许用户拖动到的最大宽度。
  static const double channelPanelMaxWidth = 400;

  /// 通道面板首次显示时使用的宽度。
  static const double channelPanelDefaultWidth = channelPanelMinWidth;

  /// 通道面板折叠后保留的窄条宽度。
  static const double channelPanelCollapsedWidth = 26;

  /// R 协议地址输入框的常规宽度。
  static const double rProtocolAddressWidth = 108;

  /// R 协议地址输入框根据内容伸缩时的最小宽度。
  static const double rProtocolAddressMinWidth = 54;

  /// R 协议地址输入框根据内容伸缩时的最大宽度。
  static const double rProtocolAddressMaxWidth = 112;

  /// 固定帧配置弹窗左侧字段标签的统一宽度。
  static const double fixedFrameConfigLabelWidth = 72;

  /// 通道和固定帧配置中数据类型下拉框的统一宽度。
  static const double dataTypeDropdownWidth = 148;

  /// 通道面板内容的水平内边距。
  static const double channelPanelHorizontalPadding = 6;

  /// 通道列表为滚动条预留的右侧内边距。
  static const double channelPanelListRightPadding = 12;

  /// 绘图区底部定位条展开后的固定高度。
  static const double locatorBarHeight = 44;

  // 绘图视口默认值和边界。

  /// 默认视口为左侧 Y 轴刻度预留的宽度。
  static const double viewportMarginLeft = 60;

  /// 没有偏置轴时绘图区右侧保留的基础边距。
  static const double viewportMarginRight = 20;

  /// 偏置 Y 轴刻度列在无需扩宽时使用的最小宽度。
  static const double offsetAxisColumnMinWidth = 42;

  /// 绘图区顶部边距。
  static const double viewportMarginTop = 20;

  /// 绘图区底部为 X 轴刻度预留的边距。
  static const double viewportMarginBottom = 40;

  /// 新建或重置视口时的 X 轴起点。
  static const double viewportDefaultXMin = 0;

  /// 新建或重置视口时的 X 轴终点。
  static const double viewportDefaultXMax = 1000;

  /// 新建或重置视口时的 Y 轴起点。
  static const double viewportDefaultYMin = randomSourceDefaultMin;

  /// 新建或重置视口时的 Y 轴终点。
  static const double viewportDefaultYMax = randomSourceDefaultMax;

  /// X 轴允许放大的最小数据范围。
  static const double viewportMinXRange = 10;

  /// X 轴允许缩小的最大数据范围，与可保留点数上限一致。
  static const double viewportMaxXRange = maxVisiblePointCount * 1.0;

  /// Y 轴允许放大的最小数值范围。
  static const double viewportMinYRange = 1;

  /// Y 轴允许缩小的最大数值范围。
  static const double viewportMaxYRange = 1000000000;

  // 通道、历史和用户配置限制。

  /// 协议解析和原始数据历史支持的普通通道上限。
  static const int rawChannelCount = 16;

  /// 用户可配置的数学通道数量。
  static const int mathChannelCount = 4;

  /// 导入导出和观察值数组支持的总通道数量。
  static const int totalChannelCount = rawChannelCount + mathChannelCount;

  /// 用户可创建的观察点数量上限。
  static const int maxObservationCount = 100;

  /// 用户可导航范围允许配置的最小点数。
  static const int minVisiblePointCount = 1000000;

  /// 用户可导航范围默认保留的点数。
  static const int defaultVisiblePointCount = minVisiblePointCount;

  /// 用户可导航范围允许配置的最大点数。
  static const int maxVisiblePointCount = 10000000;

  /// Flutter 层同时物化的精确 PlotDataPoint 对象上限。
  static const int maxMaterializedPointCount = 250000;

  /// 开始绘图时允许丢弃的前置有效数据包上限。
  static const int maxDiscardInitialPacketCount = 10000;

  /// 均衡和质量优先模式允许使用精确像素桶绘制的数据密度上限。
  ///
  /// 该限制让精确扫描量继续受绘图区宽度约束，避免大范围视口拖慢绘制。
  static const double lodQualityExactMaxPointsPerPixel = 32;

  /// 均衡模式查询大范围历史时相对性能优先细化的 LOD 层数。
  static const int lodBalancedFinerLevelCount = 1;

  /// 质量优先模式查询大范围历史时相对性能优先细化的 LOD 层数。
  static const int lodQualityFinerLevelCount = 2;

  /// 内置随机源生成数值时使用的默认下限。
  static const double randomSourceDefaultMin = 0;

  /// 内置随机源生成数值时使用的默认上限。
  static const double randomSourceDefaultMax = 32768;
}
