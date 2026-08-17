import '../constants/plot_configuration.dart';

/// 集中管理固定 UI 文本。
///
/// 这里使用普通 Dart 注册表而不是 XML，便于保持类型安全和重构便利。
/// 用户可见的固定界面文本应尽量放在这里；运行时数据、协议名称、
/// 日志消息和文件格式常量在完整多语言支持前可以继续靠近各自逻辑。
abstract final class AppStrings {
  static const appName = 'SerialTools';

  static const nav = _NavStrings();
  static const common = _CommonStrings();
  static const status = _StatusStrings();
  static const serial = _SerialStrings();
  static const plot = _PlotStrings();
  static const raw = _RawDataStrings();
  static const update = _UpdateStrings();
  static const appInfo = _AppInfoStrings();
  static const profile = _ProfileStrings();
  static const rtt = _RttStrings();
  static const shell = _ShellStrings();
  static const modbus = _ModbusStrings();
  static const flash = _FlashStrings();
  static const probe = _ProbeStrings();
  static const connection = _ConnectionStrings();
  static const multiSend = _MultiSendStrings();
}

final class _NavStrings {
  const _NavStrings();

  String get rawData => '数据收发';
  String get shell => 'Shell';
  String get plot => '绘图';
  String get rtt => 'RTT Viewer';
  String get protocol => '协议';
  String get protocolComingSoon => '后续版本实现';
}

final class _CommonStrings {
  const _CommonStrings();

  String get cancel => '取消';
  String get confirm => '确定';
  String get close => '关闭';
  String get save => '保存';
  String get delete => '删除';
  String get reset => '重置';
  String get apply => '应用';
  String get refresh => '刷新';
  String get advancedSettings => '高级设置';
  String get shellSettings => 'Shell设置';
  String get settingsAppearance => '外观';
  String get settingsPerformance => '性能';
  String get settingsText => '文字';
  String get settingsViewport => '视口';
  String get settingsToolbar => '工具栏';
  String get settingsInteraction => '交互';
  String get settingsData => '数据';
  String get settingsNotifications => '通知';
  String get settingsDiagnostics => '诊断';
  String get settingsShortcuts => '快捷键';
  String get settingsPages => '页面';
  String get settingsProbeBackend => '探针后端';
  String get settingsVersionRollback => '版本回退';
  String get settingsReset => '重置设置';
  String get settingsTextEncoding => '文本编码';
  String get settingsAutoLineBreak => '自动换行时间';
  String get settingsDisplayLines => '显示行数';
  String get settingsInputAndEncoding => '输入与编码';
  String get settingsTerminalFont => '终端字体';
  String get settingsAppearanceAndCursor => '外观与光标';
  String get settingsHistory => '历史记录';
  String get settingsDisplay => '显示';
  String get settingsNotSaved => '设置尚未保存';
  String get unsavedChangesMessage => '已有修改，是否在退出前保存？';
  String get discard => '放弃';
  String get more => '更多';
  String get noBackgroundColor => '无背景色';
  String get customColor => '自定义颜色';
}

final class _StatusStrings {
  const _StatusStrings();

  String get connected => '已连接';
  String get connecting => '连接中...';
  String get disconnected => '未连接';
  String get reconnecting => '重连中...';
  String get randomSource => '随机源';
  String get appInfo => '应用信息';
  String get flashProgrammingSession => 'Flash编程会话';
  String get serialNetwork => '串口/网络';
}

final class _SerialStrings {
  const _SerialStrings();

  String get connectionTitle => '连接配置';
  String get showPortDetails => '显示详细信息';
  String get selectPortHint => '选择串口';
  String get port => '串口';
  String portUnavailable(String port) => '$port（当前不存在）';
  String get baudRate => '波特率';
  String get dataBits => '数据位';
  String get stopBits => '停止位';
  String get parity => '校验位';
  String get noParity => '无校验';
  String get oddParity => '奇校验';
  String get evenParity => '偶校验';
  String get connect => '连接';
  String get disconnect => '断开';
}

final class _PlotStrings {
  const _PlotStrings();

  String get cursor => '光标';
  String get start => '开始';
  String get starting => '正在启动';
  String get stop => '停止';
  String get stopping => '停止中';
  String get randomSource => '随机源';
  String randomSourceFrequencyTooltip(double hz) {
    return '设置随机源频率: ${hz.round()} Hz';
  }

  String get receiveProtocolHint => '接收协议';
  String get parserConfig => '解析器配置';
  String get sendProtocolHint => '发送协议';
  String get sendProtocolConfig => '发送协议配置';
  String get noSendProtocolConfig => '当前发送协议暂无可配置项';
  String get rProtocolLooseChannelSettings => '宽松通道设置';
  String get rProtocolLooseChannelSettingsHelp =>
      '开始绘图时自动移除地址中间或前面的空白槽位，将非空地址压紧到 Ch0 开始发送；如果全部为空仍会报错。';
  String get invalidRProtocolAddress =>
      'R 协议地址仅支持十进制数字或带 0x 前缀的十六进制，范围 0~4294967295';
  String get createConfig => '新建配置';
  String get editConfig => '编辑配置';
  String get createRProtocolConfig => '新建 r 协议配置';
  String get editRProtocolConfig => '编辑 r 协议配置';
  String get noConfig => '不使用配置';
  String get verticalCursor => '左键开关垂直光标；右键输入 X 跳转';
  String get addObservation => '左键添加观察；右键管理观察；观察标签右键删除';
  String get observationManage => '管理观察';
  String get placeObservation => '移动鼠标定位观察，左键固定；右键管理观察';
  String get observation => '观察';
  String get trigger => '触发';
  String get triggerConfig => '触发配置';
  String get triggerTooltip => '左键启停触发；右键配置触发条件和触发行为';
  String get triggerObservationLimitHelp =>
      '观察最多支持 100 条；触发次数可以超过 100，但超出后不会继续新增观察。';
  String get measureXx => 'X测量';
  String get measureXxTooltip => '左键开关测量；右键配置';
  String get measureYy => 'Y测量';
  String get measureYyTooltip => '左键开关测量；右键配置';
  String get measureXSettings => 'Delta X 设置';
  String get measureYSettings => 'Delta Y 设置';
  String get measurementLineColor => '线条颜色';
  String get measurementLineOpacity => '不透明度';
  String get measurementSnap => '吸附到波形';
  String get measurementSnapHelp => '拖动 Y1/Y2 时吸附到当前窗口内最近的可见波形点';
  String get multiMeasurement => '允许多组测量';
  String get multiMeasurementHelp => '开启后按住绘图功能键并左键点击测量按钮，可追加测量组，最多 10 组';
  String get stats => '统计';
  String get statsTooltip => '统计测量（Max/Min/Avg）';
  String get statsRange => '范围';
  String get statsRangeTooltip => '统计范围';
  String get follow => '跟随';
  String get followTooltip => '最新点跟随在设定位置';
  String get followPosition => '跟随位置';
  String get followPositionHelp => '最新点在 X 轴可视宽度中的位置';
  String get yFitDisplayRatio => 'Y自适应占比';
  String get yFitDisplayRatioHelp => 'Y 自适应后数据占绘图区高度的比例';
  String get legend => '图例';
  String get liveValues => '实时值';
  String get undoZoom => '撤回缩放';
  String get boxZoom => '框选放大';
  String get zoomXIn => 'X 轴放大';
  String get zoomXOut => 'X 轴缩小';
  String get zoomYIn => 'Y 轴放大';
  String get zoomYOut => 'Y 轴缩小';
  String get importDataTooltip => '导入 CSV/BIN/旧版 DAT';
  String get exportDataTooltip => '导出 CSV/BIN';
  String get fileOperationDisabledWhilePlotting => '请先停止绘图，再导入或导出数据';
  String get inputConfigurationDisabledWhilePlotting =>
      '请先停止绘图，再修改随机源、解析器、发送协议或配置文件';
  String get fitYTooltip => 'Y轴自适应';
  String get fitY => 'Y自适应';
  String get fitXTooltip => 'X轴自适应';
  String get fitX => 'X自适应';
  String get fitAll => '全自适应';
  String get clearData => '清空数据';
  String get collapseChannelPanel => '收起通道面板';
  String get expandChannelPanel => '展开通道面板';
  String get channel => '通道';
  String get offsetToggle => '偏置功能开关';
  String get offset => '偏置';
  String get scale => '缩放';
  String get plotVisible => '绘图';
  String get hideAllChannels => '点击隐藏全部';
  String get showAllChannels => '点击显示全部';
  String get noData => '暂无数据';
  String get startPlotHint => '点击"开始"按钮开始绘图';
  String get randomSourceFrequency => '随机源频率';
  String get frequencyHz => '频率 (Hz)';
  String currentFrequency(double hz) => '当前: ${hz.round()} Hz';
  String get csvText => 'CSV 文本';
  String get binBinary => 'BIN 二进制';
  String get legacyDat => '旧版虚拟示波器 DAT';
  String get chooseExportFormat => '选择导出格式';
  String get saveCsvFile => '保存 CSV 文件';
  String get saveBinFile => '保存 BIN 文件';
  String get exportCsvTitle => '导出 CSV';
  String get exportBinTitle => '导出 BIN';
  String get exportPreparing => '准备导出';
  String get exportFailed => '导出失败';
  String get exportedPrefix => '已导出';
  String get chooseImportFormat => '选择导入格式';
  String get chooseCsvFile => '选择 CSV 文件';
  String get chooseBinFile => '选择 BIN 文件';
  String get chooseLegacyDatFile => '选择旧版虚拟示波器 DAT 文件';
  String get importCsvTitle => '导入 CSV';
  String get importBinTitle => '导入 BIN';
  String get importLegacyDatTitle => '导入旧版 DAT';
  String get importPreparing => '准备导入';
  String get importCsvSuccess => 'CSV 导入成功';
  String get importBinSuccess => 'BIN 导入成功';
  String get importLegacyDatSuccess => '旧版 DAT 导入成功';
  String importFailed(String error) => '导入失败: $error';
  String get selectConfigFirst => '请先选择一个配置文件';
  String get selectRProtocolConfigFirst => '请先选择一个 r 协议配置文件';
  String get advancedSettings => '绘图设置';
  String get showGrid => '显示网格';
  String get gridDensity => '网格密度';
  String get plotBackground => '绘图背景';
  String get plotBackgroundDark => '暗色';
  String get plotBackgroundLight => '亮色';
  String get floatingPanelOpacity => '悬浮窗透明度';
  String get observationClickToPlace => '点击定位观察';
  String get observationClickToPlaceHelp => '开启后点击工具栏“观察”会先显示跟随鼠标的观察线，左键固定位置。';
  String get showPlotSendDataInRaw => '打印绘图发送数据';
  String get showPlotSendDataInRawHelp => '在数据收发界面打印发送的数据。';
  String get axisZoomModifier => '功能键选择';
  String get axisZoomModifierHelp => '用于功能键 + 滚轮，功能键 + 拖动的 X/Y 轴缩放。';
  String get densitySparse => '稀疏';
  String get densityNormal => '普通';
  String get densityDense => '密集';
  String get refreshFps => '绘图刷新帧率';
  String get renderEngine => '绘图引擎';
  String get renderEngineCanvas => 'Canvas';
  String get renderEngineD3d11 => 'D3D11';
  String get renderEngineHelp => 'D3D11仅加速Windows曲线数据层；不可用时自动回退Canvas。';
  String get lodQuality => '绘图质量';
  String get lodQualityPerformance => '性能优先';
  String get lodQualityBalanced => '均衡';
  String get lodQualityQuality => '质量优先';
  String get lodQualityHelp =>
      '性能优先最多合并相邻两个物理像素列；均衡和质量优先按单个物理像素列保留峰谷，质量优先在放大后更早恢复完整原始点。';
  String get receiveAggregation => '绘图高频接收合并';
  String get receiveAggregationHelp =>
      '仅绘图接收时短暂合并连续小块数据，降低高频大量数据的处理开销；可能轻微增加绘图显示延迟。';
  String get plotFontSize => '绘图字体大小';
  String get plotFontBold => '加粗绘图字体';
  String get defaultValue => '默认';
  String get fontPreview => '参考字体';
  String get statsFeatureToggle => '显示测量统计工具';
  String get statsFeatureHelp => '开启后在工具栏添加测量统计入口，点击工具栏按钮后才启用统计';
  String get preview => '定位条';
  String get previewTooltip => '显示快速定位条';
  String get previewFeatureToggle => '显示定位条';
  String get previewFeatureHelp => '开启后在工具栏添加定位条入口，可快速定位长数据中的显示窗口';
  String get triggerFeatureToggle => '显示触发工具';
  String get triggerFeatureHelp => '开启后在工具栏添加触发入口，左键启停触发，右键配置触发条件';
  String get keepPlotOnRestart => '保持绘图';
  String get keepPlotOnRestartHelp =>
      '仅续接同一接收协议且通道数一致的数据流；切换协议、自动识别通道数变化或导入数据后会清空旧数据。';
  String get snapHighlight => '吸附点高亮';
  String get snapHighlightColorMode => '吸附点颜色';
  String get snapHighlightColorCursor => '跟随光标线';
  String get snapHighlightColorChannel => '跟随各自通道';
  String get plotHistoryMemoryLimit => '绘图历史内存上限';
  String get plotWindowLimit => '绘图窗口上限';
  String get droppedPackets => '丢弃包数';
  String get unitFps => 'fps';
  String get unitPixel => 'px';
  String get unitPacket => '包';
  String get unitGiB => 'GiB';

  String get refreshFpsHelp =>
      '范围: 30~120 fps，默认 60 fps\n这是绘图数据层的目标更新上限；实际帧率还受显示刷新率、输入频率和渲染性能限制';
  String get plotFontSizeHelp => '范围: -3~+6，影响绘图区坐标轴及所有悬浮窗字体大小';
  String get snapHighlightHelp => '范围: 6~12 px，默认 8 px。仅显示当前窗口内的吸附点';
  String get plotHistoryMemoryLimitHelp =>
      '范围: ${PlotConfiguration.minHistoryMemoryLimitGiB}~${PlotConfiguration.maxHistoryMemoryLimitGiB} GiB，'
      '默认 ${PlotConfiguration.defaultHistoryMemoryLimitGiB} GiB。达到 80% 时预警，'
      '达到上限时停止绘图并保留已有历史。';

  String plotWindowLimitHelp({
    required String min,
    required String max,
    required String defaultValue,
    required String current,
  }) {
    return '范围: $min~$max 包，默认 $defaultValue 包。当前可见范围: $current 包。'
        '可输入 1M、1.5M、10M；超过 250K 点时自动使用 LOD。';
  }

  String droppedPacketsHelp({required String max}) {
    return '范围: 0~$max 包，默认 0 包。可输入 500、1K、10K。每次开始绘图时丢弃前 N 个成功解析的数据包，不影响文件导入。';
  }

  String get closeOffset => '关闭偏置';
  String get openOffset => '开启偏置';
  String get hideChannel => '点击隐藏通道';
  String get showChannel => '点击显示通道';
  String get editChannel => '编辑通道';
  String get channelActions => '通道功能';
  String get noChannelAction => '暂无可用操作';
  String get addMathChannel => '添加数学通道';
  String get resetAllChannels => '重置全部通道';
  String get resetAllChannelsTitle => '重置全部通道';
  String get resetAllChannelsMessage =>
      '将重置当前所有通道的地址、名称、显示、颜色、偏置、数据类型等通道设置，并清空数学通道。已保存的配置文件不会删除。';
  String get resetAllChannelsStoppedOnly => '请停止绘图后再重置全部通道';
  String get deleteMathChannel => '删除数学通道';
  String get editMathChannel => '编辑数学通道';
  String get offsetBinding => '绑定偏置';
  String get offsetBindingTitle => '绑定偏置';
  String get offsetBindingHelp => '绑定通道将共用同一个偏置位置、缩放倍率和右侧 Y 轴。';
  String get offsetBindingNoCandidates => '没有其他已开启偏置的通道';
  String get closeOffsetBinding => '解除绑定';
  String get resetMathChannel => '重置数学通道';
  String get mathExpression => '表达式';
  String get mathExpressionHint => '例如: CH0-CH1';
  String get mathExpressionHelp =>
      '支持 CH0~CH15、CHn[偏移]，支持 +、-、*、/、括号、负数和 abs()。';
  String get noAvailableMathChannel => '没有可用的数学通道';
  String get selectAddress => '选择地址';
  String editChannelTitle(int index) => '编辑 Ch$index';
  String get color => '颜色';
  String get alias => '别名';
  String get aliasHint => '输入通道别名';
  String get showLine => '连线显示';
  String get lineWidth => '线宽';
  String get pointRadius => '点半径';
  String get showOffset => '偏移显示';
  String get offsetHint => '提示：开启后可在绘图区拖动通道标签调整偏移位置';
  String get dataType => '数据类型';
  String get zobowDataTypeHelp => '仅在众邦电控协议停止绘图后可修改';
  String get fixedFrameDataTypeHelp => '固定帧类型不一致时，按当前通道类型解析';
  String get typeHint => '类型';
  String get customColor => '自定义颜色';
  String get customColorPreview => '调色盘';
  String get redChannel => 'R';
  String get greenChannel => 'G';
  String get blueChannel => 'B';
  String get hexColor => 'HEX';
  String get hexColorHint => '例如 #33AAFF';
  String get colorInputInvalid => '请输入有效的 RGB 或 HEX 颜色';
  String get selectAddressSearchClear => '清空搜索';
  String get switchToGrid => '切换为平铺';
  String get switchToList => '切换为列表';
  String selectAddressTitle(String name) => '选择地址 - $name';
  String get searchNameOrAddress => '搜索名称或地址';
  String get noMatchingAddress => '没有匹配的地址';

  String get parserConfigTitle => '解析器配置';
  String get channelCount => '通道数';
  String get channelCountHint => '通道数';
  String get autoDetectHint => '(0=自动识别)';
  String get zobowConfig => '众邦电控配置';
  String zobowFrameDescription(int dataBytes) =>
      '$dataBytes字节数据 + 2字节CRC16(MODBUS)';
  String get zobowChannelPanelHelp => '通道号和数据类型请在通道面板中设置';
  String get frameHeaderSettings => '帧头设置';
  String get enableFrameHeader => '启用帧头';
  String get frameHeaderBytes => '帧头字节';
  String get frameHeaderExample => '例如: AA 55';
  String get dataSettings => '数据设置';
  String get channelType => '通道类型:';
  String get channelTypeModeHint => '通道类型模式';
  String get uniform => '统一';
  String get nonUniform => '不一致';
  String get selectDataTypeInChannelList => '请在通道列表的通道设置中分别选择数据类型';
  String get frameTailSettings => '帧尾设置';
  String get enableFrameTail => '启用帧尾';
  String get frameTailBytes => '帧尾字节';
  String get frameTailExample => '例如: 0D 0A';
  String get crcSettings => 'CRC 设置';
  String get enableCrc => '启用 CRC';
  String get crcType => 'CRC 类型';
  String get crcPolynomial => 'CRC 多项式';
  String get crcPosition => 'CRC 位置';
  String crcPositionLabel(String label) => 'CRC 位于$label';
  String get crcEndian => 'CRC 字节序';
  String crcEndianLabel(String label) => 'CRC $label';

  // 清空确认 / 空态
  String get clearDataConfirmMessage => '确定清空当前绘图数据和历史吗？此操作不可撤销。';
  String get noDisplayChannel => '无显示通道';
  String get boxZoomTooltip => '$boxZoom（左键单次，右键连续）';
  String get plotSettingsRangeError => '请检查绘图设置中的数值范围';

  // 导出范围与通道
  String get exportRangeAndChannelsTitle => '导出范围与通道';
  String exportRangeHint(int maxIndex) =>
      '可导出范围: 0-$maxIndex，导出文件内 X 将从 0 重新编号。';
  String get exportStartPoint => '起始点';
  String get exportEndPoint => '结束点';
  String get exportChannels => '导出通道';
  String exportSelectedCount(int selected, int total) => '已选 $selected/$total';
  String get exportMathChannelNote => '数学通道导出表达式计算后的实际值。';
  String get exportUseCurrentViewport => '使用当前视口';
  String get exportContinue => '继续';
  String get exportInvalidRange => '请输入整数起始点和结束点';
  String exportRangeError(int maxIndex) => '范围应满足 0 <= 起始点 <= 结束点 <= $maxIndex';
  String get exportSelectAtLeastOneChannel => '请至少选择 1 个通道';
  String exportMaxChannelCount(int count) => '最多可同时导出 $count 个通道';
  String get exportCancelled => '导出已取消';

  // 触发配置
  String get enableTrigger => '启用触发';
  String get noTriggerChannelAvailable => '当前没有可用的普通或数学通道，无法选择触发通道。';
  String get triggerCondition => '条件';
  String get triggerTargetValue => '目标值';
  String get triggerMathChannelNote =>
      '数学通道按表达式原始值触发；包含 CHn[...] 数据偏移的数学通道暂不支持。';
  String get triggerHitThreshold => '累计命中次数';
  String get triggerLimit => '触发次数';
  String get triggerCountHelp => '累计命中次数表示命中 N 次算一次触发；触发次数表示 N 次触发后执行触发行为。';
  String get triggerAction => '触发行为';
  String get triggerPostPackets => '继续接收包数';
  String get triggerObservationMark => '观察标记';
  String get triggerNoteSystemTime => '备注记录触发系统时间';

  // 观察管理
  String get noObservation => '暂无观察';
  String get observationNote => '备注';
  String get observationAction => '操作';
  String get observationLock => '锁定';
  String get observationUnlock => '解除锁定';
  String get jump => '跳转';

  // 光标跳转
  String get jumpToXTitle => '跳转到 X';
  String get jumpXInvalid => '请输入整数 X';
  String jumpXRangeError(int maxX) => 'X 范围应为 0-$maxX';
  String jumpXHelper(int maxX) => '范围: 0-$maxX';

  // 通道编辑校验
  String get lineWidthRangeHint => '0.5 ~ 8';
  String get pointRadiusRangeHint => '0.5 ~ 12';
  String get scaleRangeHint => '0.001 ~ 1000';
  String get lineWidthRangeError => '范围 0.5 ~ 8';
  String get pointRadiusRangeError => '范围 0.5 ~ 12';
  String get scaleRangeError => '范围 0.001 ~ 1000';
  String get offsetInvalidValue => '请输入有效数值';
  String get reinterpretZobowDataStage => '准备重新解释众邦数据';
  String get updateChannelDataTypeTitle => '更新通道数据类型';

  // 解析器格式说明
  String get fireWaterFormatLabel => 'FireWater 格式:';
  String get fireWaterCommaSeparated => '以 "," 分割数据';
  String get fireWaterDoubleType => '所有数据默认 double 类型';
  String get fireWaterNewlineEnding => '以 "\\n" 结尾';
  String get justFloatFormatLabel => 'JustFloat 格式:';
  String get justFloatLittleEndian => '小端 float32 数组';
  String get justFloatTail => '帧尾: 00 00 80 7F';
  String channelCountOption(int count) => '$count 通道';
}

final class _RawDataStrings {
  const _RawDataStrings();

  String get normalIo => '普通收发';
  String get startReceive => '开始接收';
  String get stopReceive => '停止接收';
  String get clearScreen => '清屏';
  String get shellSettings => 'Shell 设置';
  String get commandLine => '命令行';
  String get keyByKey => '逐键';
  String get moreOptions => '更多选项';
  String get inputMode => '输入模式';
  String get moreFeatures => '更多功能';
  String get fileTransfer => '文件发送/接收';
  String get send => '发送';
  String get receive => '接收';
  String get wait => '等待';
  String get transferProtocol => '传输协议';
  String get packetSize => '发送长度';
  String get noFileSelected => '未选择文件';
  String get choose => '选择';
  String get receiveFileSaveHint => '接收文件将保存到应用目录 exports/ymodem。';
  String get cancelTransfer => '取消传输';
  String get sendCompleted => '发送完成';
  String get noFileReceived => '未接收文件';
  String receiveCompleted(String path) => '接收完成: $path';
  String get waitingForTransfer => '等待开始传输';
  String get clear => '清空';
  String get timestamp => '时间戳';
  String get autoLineBreak => '自动换行';
  String get hexDisplay => 'HEX显示';
  String get autoScroll => '自动滚动';
  String get commandInputHint => '输入命令后按 Enter 发送';
  String get sendData => '发送数据';
  String get keepAfterSend => '发送后保留';
  String get appendLineEnding => '末尾回车';
  String get lineEndingHint => '回车';
  String get sendHex => 'HEX发送';
  String get crcTypeHint => '类型';
  String get crcPolynomialHint => '多项式';
  String get byteOrderHint => '字节序';
  String get sendHexHint => '输入十六进制 (如: 01 02 03)';
  String get sendTextHint => '输入要发送的数据';
  String get saveDataTitle => '保存数据';
  String get chooseSaveFormat => '选择保存格式：';
  String get chooseExportDirectory => '选择导出文件夹';
  String get savedTextPrefix => '已保存为文本';
  String get savedRawPrefix => '已保存为原始字节';
  String get textFileFormat => '文本 (.txt)';
  String get rawBytesFormat => '原始字节 (.bin)';
  String get exportingData => '正在导出数据';
  String get preparingExport => '正在准备原始数据';
  String get decodingExportText => '正在按文本编码解析数据';
  String get buildingRawExport => '正在计算校验并生成 BIN 数据';
  String get writingExportFile => '正在写入文件';
  String exportProgressPercent(double progress) =>
      '${(progress * 100).round()}%';
  String get rawSettingsTitle => '数据收发设置';
  String get textEncoding => '文本编码方式:';
  String get encodingHint => '编码';
  String get textEncodingHelp => '非 HEX 模式下，发送文本按选定编码转换为字节，接收字节按同一编码解码。';
  String get autoLineBreakTime => '自动换行时间 (ms):';
  String get autoLineBreakTimeHelp =>
      '相邻两包数据超过该时间未继续接收时自动换行；连续数据不换行，文本中的换行符仍正常生效。';
  String get displayLineLimit => '接收区最大显示行数:';
  String get displayLineLimitHelp => '默认 100000 行。降低上限后会立即移除最早的显示内容，不影响原始字节导出。';
  String get enableShellEntry => '显示 Shell 页面';
  String get enableShellEntryHelp => '开启后在主窗口显示独立 Shell 标签。';
  String get autoLineBreakTimeInvalid => '自动换行时间请输入 1 ~ 10000 ms';
  String get displayLineLimitInvalid => '显示行数请输入 100 ~ 100000 之间的数值';
  String advancedSettingsSaved(int lines) => '高级设置已保存，接收区最多显示 $lines 行';
  String get terminalFontSize => '终端字号:';
  String get terminalFontFamily => '终端字体:';
  String get terminalTheme => '终端主题:';
  String get cursorStyle => '光标样式:';
  String get terminalFontSizeInvalid => '终端字号: 10 - 24';
  String get shellSettingsSaved => 'Shell 设置已保存';
  String get displayOptions => '显示选项';
  String get actions => '操作';
  String get extension => '扩展';
  String get start => '开始';
  String get stop => '停止';
  String get clearDataConfirm => '确定清空当前接收数据和完整字节记录吗？此操作不可撤销。';
  String get invalidSettings => '请修正无效设置';
  String get connectBeforeReceive => '请先点击左下角状态栏连接串口或网络，再点击“开始”接收';
  String get capacityWarning => ' [容量预警]';
  String get capacityLimitReached => ' [容量上限停止，请导出并清空]';
  String statsSummary({
    required bool hexDisplay,
    required String encoding,
    required String rawData,
    required String rawCapacity,
    required String lineCount,
    required String textCache,
    required String retentionStatus,
  }) =>
      hexDisplay
          ? '接收: $rawData | 容量: $rawCapacity$retentionStatus | 行数: $lineCount | 缓存: $textCache'
          : '编码: $encoding | 原始容量: $rawCapacity$retentionStatus | 行数: $lineCount | 缓存: $textCache';
}

final class _UpdateStrings {
  const _UpdateStrings();

  String get updateFound => '发现新版本';
  String get later => '稍后';
  String get cancelDownload => '取消下载';
  String get openReleasePage => '打开发布页';
  String get downloadAndInstall => '下载并安装';
  String get restartAndInstall => '立即重启并安装';
  String get startingUpdater => '正在启动更新器...';
}

final class _AppInfoStrings {
  const _AppInfoStrings();

  String get title => '应用信息';
  String get updateFound => '发现新版本';
  String currentVersion(String version) => '当前版本: $version';
  String latestVersion(String version) => '最新版本: $version';
  String updateChannel(String channel) => '更新通道: $channel';
  String source(String source) => '来源: $source';
  String get changelog => '更新内容:';
  String get preparingDownload => '正在准备下载...';
  String get updateReady => '更新包已下载并通过校验，可以重启安装。';
  String get debugInstallUnsupported => 'Debug/Profile 构建仅支持检查更新，不支持覆盖安装。';
  String get cancelingDownload => '正在取消下载...';
  String get downloadCanceled => '下载已取消';
  String get multipleInstancesUpdateTitle => '关闭其他窗口并更新';
  String get multipleInstancesUpdateMessage =>
      '检测到已打开多个 Vscope Serial 窗口。升级过程会关闭所有实例。如有未导出或未保存的数据，请先取消并保存。是否继续？';
  String get multipleInstancesCloseTimeout =>
      '其他 Vscope Serial 窗口未能及时关闭，请手动关闭后重试。';
  String get closeOtherInstancesAndContinue => '关闭并继续';
  String get appName => '应用名称';
  String get version => '版本';
  String get buildTime => '构建时间';
  String get loading => '读取中...';
  String get unknown => '未知';
  String get releaseNotes => '版本说明';
  String get autoCheckUpdates => '启动时自动检查更新';
  String get autoCheckUpdatesHelp => '开启后每次打开应用会按更新来源设置检查更新';
  String get updateChannelTitle => '更新通道';
  String get updateChannelAndSourceTitle => '更新通道和来源';
  String get betaChannelHelp => '只检查预发布版本';
  String get stableChannelHelp => '只检查稳定版本';
  String get updateSourceTitle => '更新来源';
  String get updateSourceAutoHelp => '自动模式会优先访问 GitHub，失败后尝试 Gitee';
  String updateSourceLockedHelp(String source) => '只访问 $source，不自动切换到其他来源';
  String get checking => '检查中...';
  String get manualCheckUpdates => '手动检查更新';
  String openReleasePage(String source) => '打开 $source 发布页';
  String get rollback => '版本回退';
  String get loadingRollback => '正在读取回退版本...';
  String rollbackVersion(String channel, String? tagName) {
    return '$channel: ${tagName ?? '暂无可回退版本'}';
  }

  String get rollbackAction => '回退';
  String get resetSettings => '恢复默认设置';
  String get resetSettingsHelp =>
      '重置串口、绘图、数据收发、Shell、更新等应用设置；不会删除绘图配置功能保存的 JSON 配置文件。';
  String get disableNotifications => '关闭提示信息';
  String get disableNotificationsHelp => '开启后不再显示应用内临时提示';
  String get diagnosticLogging => '调试模式';
  String get diagnosticLoggingHelp => '记录串口连接等详细诊断信息并立即写入日志；仅排查问题时开启，日志量会明显增加。';
  String get crashDump => '原生崩溃转储';
  String get crashDumpHelp =>
      '发生无法由应用捕获的 Windows 原生崩溃时保存小型转储，最多保留 10 份；文件可能包含少量运行时内存，仅在用户主动提供时用于排查。';
  String get crashDumpDetectedTitle => '检测到上次原生崩溃';
  String crashDumpDetectedMessage(
    int count,
    String time,
    String exceptionCode,
  ) =>
      '发现 $count 份尚未查看的崩溃记录。\n'
      '最近一次：$time\n'
      '异常代码：$exceptionCode\n\n'
      '转储和对应日志保存在程序目录中，可在反馈问题时一并提供。';
  String get openCrashDumpDirectory => '打开转储目录';
  String get triggerTestCrash => '触发测试崩溃';
  String get triggerTestCrashHelp => '仅 Debug 构建提供，用于验证原生崩溃转储链路。';
  String get triggerTestCrashTitle => '确认触发原生崩溃';
  String get triggerTestCrashMessage =>
      '应用将立即发生真实的原生访问冲突并退出，不会执行正常断开和数据保存流程。'
      '请先停止串口、探针及其他重要任务；重新启动后应看到崩溃转储提示。';
  String get jlinkExecutablePath => 'JLinkGDBServerCL.exe 路径';
  String get jlinkExecutablePathHelp => '留空时从 SEGGER 安装目录和 PATH 自动查找';
  String get externalOpenOcdPath => '外置 openocd.exe 路径';
  String get externalOpenOcdPathHelp => '留空时从 PATH 查找；仅影响外置 OpenOCD';
  String get externalPyOcdPythonPath => '外置 pyOCD Python 路径';
  String get externalPyOcdPythonPathHelp =>
      '指向能够 import pyocd 的 python.exe；当前仅支持 pyOCD 0.45.x';
  String get detectingProbeBackends => '正在检测探针后端...';
  String get backendNotDetected => '未检测到';
  String get backendDetectedUnknownVersion => '已检测到（版本未知）';
  String probeBackendState(String name, String state) => '$name: $state';
  String get redetect => '重新检测';
  String get enableConnectionShortcuts => '启用连接快捷键';
  String get enableConnectionShortcutsHelp =>
      'F1 打开连接配置，F2 快捷连接，F3 快捷断开，F5 快捷重连；关闭后全部不响应。';
  String get enableNetworkConnections => '启用网络连接';
  String get enableNetworkConnectionsHelp =>
      '允许数据收发、绘图和Modbus使用TCP/UDP，并允许Shell选择SSH。';
  String get separateSerialProfiles => '按页面独立保存串口参数';
  String get separateSerialProfilesHelp => '关闭时数据收发、Shell和绘图共用原全局参数；开启后分别保存。';
  String get invalidPlotHistoryLimit => '请检查绘图历史内存上限';
  String get connectionBusySettingsError => '数据连接活动期间不能修改网络或串口配置记录方式';
  String get preparingBundledOpenOcd => '正在准备内置 OpenOCD';
  String get bundledOpenOcdPreparationHelp => '运行文件将解压到程序目录，完成后会自动继续。';
  String get memoryLimits => '内存上限';
  String get plotHistoryMemoryLimit => '绘图历史';
  String get plotHistoryMemoryLimitSummary => '达到上限后停止绘图并保留已有历史';
  String get plotEmergencyRssLimit => '应用进程 RSS 紧急保护线';
  String get plotEmergencyRssLimitSummary =>
      '占用包含 Flutter 和全部功能；绘图追加数据时检查，达到保护线后停止绘图';
  String get rawRetentionMemoryLimit => '数据收发完整记录';
  String get rawRetentionMemoryLimitSummary => '达到上限后停止接收并保留已有数据';
  String get rawTextCacheMemoryLimit => '数据收发文本显示缓存';
  String get rawTextCacheMemoryLimitSummary => '超出后移除最早的显示文本';
  String get shellQueueMemoryLimit => 'Shell 待处理接收队列';
  String get shellQueueMemoryLimitSummary => '超出后丢弃最早的完整数据块';
  String get ymodemQueueMemoryLimit => 'YMODEM 输入队列';
  String get ymodemQueueMemoryLimitSummary => '超出后取消当前文件传输';
  String get rttQueueMemoryLimit => 'RTT 待处理接收队列';
  String get rttQueueMemoryLimitSummary => '超出后丢弃最早的完整 RTT 数据块并重新同步解码';
  String get rttRawHistoryMemoryLimit => 'RTT 原始重建历史';
  String get rttRawHistoryMemoryLimitSummary => '用于切换编码、文本或 HEX 显示以及导出当前保留范围';
  String memoryUsage(String used, String limit, String percent) =>
      '当前占用: $used / $limit ($percent)';
  String get confirmResetSettingsTitle => '确认恢复默认设置';
  String get resetSettingsWarning => '此操作会重置串口、绘图、数据收发、Shell、更新等应用设置，操作不可撤销。';
  String get resetSettingsKeepsProfiles => '绘图配置功能保存的 JSON 配置文件不会被删除。';
  String enterResetCode(String code) => '请输入四位验证码 $code 以继续：';
  String get confirmReset => '确认恢复';
  String get resetSettingsDone => '已恢复默认设置，建议重启应用以确保所有界面完全生效。';
  String get noVersionInfo => '未获取到版本信息';
  String updateAvailable(String channel, String tagName, String source) {
    return '发现$channel新版本 $tagName（$source）';
  }

  String noUpdate({
    required String currentVersion,
    required String channel,
    required String tagName,
    required String source,
  }) {
    return '未发现更新（当前版本: $currentVersion；$channel最新发布版本: $tagName，$source）';
  }
}

final class _ShellStrings {
  const _ShellStrings();

  // 工具栏
  String get start => '开始';
  String get stop => '停止';
  String get startShell => '开始 Shell';
  String get stopShell => '停止 Shell';
  String get disconnectSsh => '断开 SSH';
  String get normal => '普通';
  String get ssh => 'SSH';
  String get commandLineMode => '命令行模式';
  String get keyMode => '逐键模式';
  String get clearCurrentScreen => '清除当前屏幕';
  String get clearHistory => '清除历史';
  String get clearScreenAndHistory => '清除屏幕和历史';
  String get fileTransfer => '文件传输';
  String get exportTerminalText => '导出终端文本';

  // 粘贴多行确认
  String get sendMultilineTitle => '发送多行内容';
  String get sendMultilineMessage => '剪贴板包含多行内容，确定直接发送到设备吗？';

  // 连接模式切换确认
  String get switchConnectionModeTitle => '切换 Shell 连接模式';
  String get switchConnectionModeDisconnectMessage =>
      '切换普通终端与 SSH 前必须断开当前连接，并清空终端显示、滚动历史和命令历史。是否继续？';
  String get switchConnectionModeMessage =>
      '切换普通终端与 SSH 会清空终端显示、滚动历史和命令历史。是否继续？';
  String get disconnectAndSwitch => '断开并切换';
  String get clearAndSwitch => '清空并切换';

  // 清屏确认
  String get clearConfirmMessage => '此操作不可撤销，确定继续吗？';

  // 状态栏
  String get running => '运行中';
  String get stopped => '已停止';
  String get scrollLock => '滚动锁定';
  String receivedBytes(String bytes) => '接收 $bytes';
  String droppedBytes(String bytes) => '丢弃 $bytes';
  String newOutput(String bytes) => '新输出 $bytes';

  // 导出
  String get chooseTerminalExportDirectory => '选择终端文本导出目录';

  // 设置弹窗
  String get commandLineEnding => '命令行行尾';
  String get selectCommandLineEnding => '选择命令行行尾';
  String get commandLineEndingHelp => '命令行模式发送时会在内容末尾追加所选行尾。';
  String get localEcho => '命令行本地回显';
  String get fontPreviewText =>
      'SerialTools Shell  中文终端\nAa Bb 0123456789  > _';
  String get terminalTheme => '终端主题';
  String get light => '浅色';
  String get dark => '深色';
  String get cursorStyle => '光标样式';
  String get selectCursorStyle => '选择光标样式';
  String get selectHistoryLines => '选择历史行数';
  String historyLinesOption(int lines) => '$lines 行';
  String get enableSshKeepalive => '启用 SSH Keepalive';
  String get sshKeepaliveHelp =>
      '默认每 10 秒发送一次 OpenSSH keepalive 请求；不兼容的嵌入式 SSH 服务端可关闭，下次连接生效。';

  // YMODEM 文件传输
  String get ymodemFileTransfer => 'YMODEM 文件传输';
  String get noSendFileSelected => '未选择发送文件';
  String get sendPacket => '发送分包';
  String get auto => '自动';
  String get packet128 => '128 字节';
  String get packet1024 => '1024 字节';
}

final class _RttStrings {
  const _RttStrings();

  String get probe => '探针';
  String get settings => 'RTT Viewer 设置';
  String get showPage => '显示探针功能';
  String get showPageHelp => '显示 RTT Viewer 和探针绘图标签';
  String get connect => '探针连接';
  String get waitingData => '等待 RTT Up 0 数据';
  String get connectHint => '点击左下角连接 J-Link 或 CMSIS-DAP';

  // 工具栏 / 状态栏
  String get start => '开始';
  String get stop => '停止';
  String get starting => '启动中';
  String get stopping => '停止中';
  String get stoppingAndReconnecting => '正在停止并重新连接';
  String get startingViewer => '正在启动 RTT Viewer';
  String get stopViewer => '停止 RTT Viewer';
  String get startViewer => '开始 RTT Viewer';
  String get resume => '继续';
  String get pause => '暂停';
  String get resumeDisplay => '继续显示';
  String get pauseDisplay => '暂停显示';
  String get timestamp => '时间戳';
  String get hexDisplay => 'HEX显示';
  String get autoScroll => '自动滚动';
  String get clear => '清空';
  String get clearConfirmMessage => '确定清空 RTT 终端显示内容吗？此操作不可撤销。';
  String get export => '导出';
  String get exportText => '导出文本';
  String get exportRawBin => '导出原始 BIN';
  String get exportTextDialogTitle => '导出 RTT 文本';
  String get exportRawDialogTitle => '导出 RTT 原始数据';
  String get receiveConfig => 'RTT 接收配置';
  String get receiveConfigTitle => 'RTT Viewer 接收配置';
  String get clickStartToRead => '点击“开始”读取 RTT 数据';
  String get running => '运行中';
  String get connected => '已连接';
  String get stopped => '已停止';
  String get allTerminals => 'All Terminals';
  String terminalStatus(int terminal) => 'Terminal $terminal';
  String receivedBytes(String bytes) => '接收 $bytes';
  String droppedBytes(String bytes) => '丢弃 $bytes';
  String pausedBytes(String bytes) => '暂停新增 $bytes';

  // 终端面板
  String get expandTerminal => '展开终端';
  String get collapseTerminal => '收起终端';
  String get virtualTerminal => '虚拟终端';

  // 终端标注设置
  String get terminalLabelEmptyError => '方括号内的标注不能为空';
  String get terminalLabelTooLongError => '标注最多 32 个字符';
  String terminalAppearanceTitle(int terminal) => 'Terminal $terminal 标注设置';
  String get bracketLabelText => '方括号内文字';
  String get bracketLabelHint => '例如 电机状态';
  String get labelColor => '标识颜色';
  String colorOption(int number) => '颜色 $number';

  // 输入栏
  String get hexInputHint => '输入 HEX 字节';
  String get textInputHint => '输入发送到 Down 0 的文本';
  String get noDown0Hint => '当前后端没有可用的 Down 0';
  String get lineEnding => '行尾';
  String get none => '无';
  String get sendToDown0 => '发送到 RTT Down 0';
}

final class _ProfileStrings {
  const _ProfileStrings();

  String get defaultConfigName => '新配置';
  String get createProfile => '新建配置文件';
  String get editProfile => '编辑配置文件';
  String get nameLabel => '名称:';
  String get searchNameOrAddress => '搜索名称或地址';
  String get clearSearch => '清除搜索';
  String get noSearchResult => '无匹配项';
  String get nameColumn => '名称';
  String get addressColumn => '地址';
  String get add => '添加';
  String presetCount(int count) => '$count 个预设';
  String get deleteProfile => '删除配置';
  String get exportProfile => '导出配置';
  String get importExternal => '导入配置';
  String get importConflictHandling => '相同地址处理';
  String get overwriteSameAddress => '覆盖同地址原项';
  String get keepSameAddress => '保留同地址项';
  String get importConflictHelp => '仅编辑已有配置时生效；未冲突的原有地址项会保留。';
  String deleteProfileTitle(String name) => '删除配置文件';
  String deleteProfileMessage(String name) => '确定删除“$name”吗？此操作无法撤销。';
  String get ignoreComments => '忽略注释';
  String get ignoreCommentsHelp => 'C 导入时全部使用变量名';
  String get importJson => '导入 JSON';
  String get importCsv => '导入 CSV';
  String get importCFile => '导入 C 文件';
  String get pasteCCode => '粘贴 C 代码';
  String get importZobowProfileDialogTitle => '导入众邦配置文件';
  String get importAddressCsvDialogTitle => '导入地址配置 CSV';
  String get importZobowCDialogTitle => '导入 Zobow C 配置';
  String get exportProfileDialogTitle => '导出配置文件';
  String get exportingProfile => '正在导出配置';
  String get exportProfileWriting => '正在写入配置文件...';
  String get invalidProfileFormat => '配置文件格式不正确';
  String get emptyProfilePresets => '配置文件没有可导入的地址预设';
  String invalidPresetAddress(String name) => '“$name”的地址格式无效';
  String importProfileFailed(String error) => '导入配置失败: $error';
  String exportProfileFailed(String error) => '导出配置失败: $error';
  String exportProfileCompleted(String path) => '已导出配置: $path';
  String importCsvFailed(String error) => '导入 CSV 配置失败: $error';
  String importCFailed(String error) => '导入 C 配置失败: $error';
  String get pasteCCodeHint => '粘贴包含 ChxValueTable 的 C 代码';
  String get importAction => '导入';
  String get editSequence => '编辑序号';
  String get sequence => '序号';
  String sequenceRangeHelp(int maximum) => '请输入 1～$maximum；超出范围会自动调整。';
  String get noCProfileSwitchFound => '未找到 ChxValueTable 内可导入的 switch 配置';
  String importedPresetCount(int count) => '已导入 $count 个地址预设';
  String presetName(int index) => '预设$index';
  String get rProtocolAddressHint => '1 或 0x1';
}

final class _ModbusStrings {
  const _ModbusStrings();

  // 通用操作
  String get add => '添加';
  String get send => '发送';
  String get start => '开始';
  String get stop => '停止';

  // 工具栏
  String get advancedSettings => 'Modbus高级设置';
  String get startDataProcessing => '开始Modbus数据处理';
  String get stopDataProcessing => '停止Modbus数据处理';
  String get protocol => '协议';
  String get defaultProfile => '默认配置';
  String get loadingProfiles => '加载配置…';
  String get editProfile => '编辑Modbus配置';
  String get toggleManualSend => '显示/隐藏手动发送';
  String get showManualSend => '显示手动发送';
  String get togglePollingPage => '显示/隐藏轮询页面';
  String get showPollingPage => '显示轮询页面';
  String get toggleLogs => '显示/隐藏日志';
  String get showLogs => '显示日志';

  // 高级设置弹窗
  String get registerSection => '寄存器';
  String get logSection => '日志';
  String get responseTimeout => '响应超时（100～60000 ms）';
  String get registerLayout => '寄存器排列';
  String get multiRegisterLayout => '多寄存器数据排列（全局）';
  String get byteOrder => '字节序';
  String get wordOrder => '字序';
  String currentLayout(String preview) => '当前排列：$preview';
  String logMaxLines(int min, int max) => '日志上限（$min～$max 行）';
  String get responseTimeoutInvalid => '响应超时必须在100～60000 ms之间';
  String get logMaxLinesInvalid => '日志上限必须在100～100000行之间';
  String get enableNetworkFirst => '请先在高级设置中启用网络连接';

  // 寄存器页面
  String get addPageTitle => '添加寄存器页面';
  String get unitId => '从机 ID（0～255）';
  String get registerArea => '寄存器区';
  String get addRegisterTitle => '添加寄存器';
  String get startAddress => '起始地址（0基）';
  String get addCount => '添加数量';
  String get variableType => '变量类型';

  // 行右键菜单
  String get quickSend => '快速发送';
  String get configureRegister => '配置寄存器';
  String get switchToHexDisplay => '切换为十六进制显示';
  String get switchToDecimalDisplay => '切换为十进制显示';
  String get deleteRegister => '删除寄存器';

  // 一次性发送
  String oneShotSendTitle(int address, String type) => '$address[$type] 一次性发送';
  String get oneShotValueHint => '值（十进制或0x十六进制）';
  String get valueLabel => '值';

  // 行配置
  String rowConfigTitle(int address, String type) => '$address[$type] 行配置';
  String configureRegisterTitle(int address, String type) =>
      '$address[$type] 配置寄存器';
  String get basicInfoSection => '基本信息';
  String get pollingAndSendSection => '轮询与发送';
  String get appearanceSection => '外观';
  String get registerNote => '寄存器备注';
  String get pollQuery => '轮询查询';
  String pollInterval(int min, int max) => '查询周期（$min～$max ms）';
  String get readRetries => '读取重试（0～3）';
  String get periodicSend => '周期发送';
  String get periodicSendMode => '周期发送模式';
  String get periodicSendValue => '周期发送值';
  String get incrementDecrementStep => '自增/自减步长';
  String sendInterval(int min, int max) => '发送周期（$min～$max ms）';

  // 配置文件管理
  String get exportProfileDialogTitle => '导出 Modbus 配置';
  String get importProfileDialogTitle => '导入 Modbus 配置';
  String get profileName => '配置名称';
  String get createProfileTitle => '新建Modbus配置';
  String get renameProfileTitle => '重命名Modbus配置';
  String get deleteProfileTitle => '删除Modbus配置';
  String deleteProfileMessage(String name) => '确定删除“$name”吗？';
  String get profileManagerTitle => 'Modbus配置管理';
  String get profileDirectoryHint => '本地目录：config/modbus';
  String get createProfile => '新建配置';
  String get importProfile => '导入配置';
  String get renameProfile => '重命名配置';
  String get exportProfile => '导出配置';
  String get deleteProfile => '删除配置';

  // 确认删除/关闭
  String deleteRegisterConfirmMessage(int address) =>
      '确定删除地址 $address 的寄存器吗？其变量类型、备注、背景色和轮询配置将一并删除。';
  String get closePageConfirmMessage => '确定关闭该寄存器页面吗？';

  // 手动发送面板
  String get manualSend => '手动发送';
  String get unitIdField => '从机 ID';
  String get pduAddressField => 'PDU地址（0基）';
  String referenceNumber(int ref) => '参考号：$ref';
  String get selectFunctionHint => '选择功能码';
  String get functionCode => '功能码';
  String get quantity => '数量';
  String get writeValuesHint => '写入值（逗号或空格分隔）';
  String get sendOnce => '发送一次';
  String get recentResponse => '最近响应';
  String get noResponse => '暂无响应';

  // 轮询面板 / 页面工具栏
  String get registerPage => '寄存器页面';
  String get addPage => '添加页面';
  String get noRegisterPage => '请添加一个寄存器页面';
  String get stopPagePollingAndSending => '停止此页面轮询和周期发送';
  String get startPagePollingAndSending => '开始此页面轮询和周期发送';
  String get startModbusFirst => '请先开始Modbus并至少开启一个寄存器轮询';
  String get batchAddRegisters => '批量添加寄存器';
  String get hideVariableType => '隐藏变量类型（u16）';
  String get showVariableType => '显示变量类型（u16）';
  String get openInDetachedWindow => '在独立窗口打开页面';
  String get closePage => '关闭页面';
  String get openInDetached => '在独立窗口打开';
  String get addSingleRegister => '添加单个寄存器';
  String get configurePagePolling => '一键配置整页轮询';

  // 批量轮询配置
  String get batchPollConfigTitle => '批量配置寄存器轮询';
  String get enablePollingForRegisters => '启用这些寄存器的轮询功能';
  String get applyToAllRegisters => '应用到所有寄存器';

  // 日志
  String get modbusLog => 'Modbus日志';
  String get clearModbusLog => '清空Modbus日志';
  String get noOutput => '暂无输出';

  // 空态
  String get openAreaFromToolbar => '请从工具栏打开一个区域';

  // 独立窗口
  String get closeDetachedWindow => '关闭独立窗口';

  // 网格单元提示
  String get pollingAndSendingEnabled => '开启轮询查询和定时发送';
  String get pollingEnabled => '开启轮询查询';
  String get sendingEnabled => '开启定时发送';

  // 旧版右键菜单
  String get cancelPollQuery => '取消轮询查询';
  String get setPollQuery => '设置轮询查询';
  String get cancelPeriodicSend => '取消周期发送';
  String get setPeriodicSend => '设置周期发送';
  String get editValueAndSendOnce => '编辑值并发送一次';
  String get toggleRadixDisplay => '切换十进制/十六进制显示';
  String get editNote => '编辑备注';
  String get changeBackgroundColor => '修改背景颜色';
  String get changeVariableType => '修改变量类型';
  String get deleteRegisterRow => '删除寄存器行';
  String get selectColor => '选择颜色';
}

final class _FlashStrings {
  const _FlashStrings();

  // 工具栏
  String get openFileTooltip => '打开ELF、HEX或BIN文件';
  String get hexViewerTooltip => 'HEX显示工具';
  String get toolOutput => '工具输出';
  String get forceTerminate => '强制终止Flash后端';

  // 通用确认弹窗
  String get confirm => '确认';
  String get operationRiskWarning =>
      '高权限操作可能停核、复位、擦除或改写目标。请确认目标硬件已处于允许编程的安全状态。';
  String get dismissRiskWarning => '以后不再显示此高权限提示';

  // 打开文件 / BIN 基地址
  String get chooseProgramFile => '选择烧写文件';
  String get setBinBaseAddress => '设置BIN基地址';
  String get binBaseAddressLabel => '基地址（32位）';
  String get open => '打开';
  String baseAddress(int address) =>
      '基地址：0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  // 烧写
  String get programSection => '烧写';
  String get programDataLabel => '烧写数据';
  String get programDataHint => '选择HEX显示中的数据';
  String get eraseBeforeProgram => '烧写前擦除';
  String get verifyAfterProgram => '烧写后校验';
  String get resetAfterProgram => '完成后复位';
  String get programVerify => '擦除、烧写并校验';
  String get confirmProgramTitle => '确认烧写Flash';
  String programConfirmMessage({
    required String? chip,
    required String? backend,
    required String documentName,
    required bool erase,
  }) =>
      '芯片：$chip\n后端：$backend\n'
      'HEX文档：$documentName\n'
      '${erase ? '将先擦除相关Flash。' : '不执行预擦除。'}\n'
      '此操作可能导致现有固件和数据不可恢复。';

  // 擦除
  String get eraseSection => '擦除';
  String get startAddress => '起始地址';
  String get length => '长度';
  String get rangeErase => '范围擦除';
  String get chipErase => '全片擦除';
  String get wholeChip => '全片';
  String get confirmEraseTitle => '确认不可恢复的擦除操作';
  String eraseConfirmMessage({
    required String? chip,
    required String? backend,
    required String range,
  }) =>
      '芯片：$chip\n后端：$backend\n'
      '范围：$range\n\n擦除内容无法恢复，成功后目标将保持停止。';

  // 读取
  String get readSection => '读取';
  String get read => '读取';
  String get confirmReadTitle => '确认读取Flash';
  String readConfirmMessage({
    required String? chip,
    required String? backend,
    required String address,
    required String length,
  }) =>
      '芯片：$chip\n后端：$backend\n'
      '地址：$address\n长度：$length\n\n'
      '读取过程中后端可能短暂停止目标，完成后将尝试恢复原运行状态。';

  // 保存
  String get saveFlashData => '保存Flash数据';

  // HEX 显示
  String get hexDisplay => 'HEX显示';
  String get hexDisplaySettings => 'HEX显示设置';
  String get bytesPerRow => '每行字节数';
  String get bytesPerRowHelper => '支持十进制或0x开头的十六进制，默认0x10';
  String get bytesPerRowInvalid => '每行字节数必须为合并字节数的整数倍，范围1～0x100';
  String get groupDisplay => '合并显示';
  String get groupBitsHint => '选择合并位宽';
  String get group8 => '8位：FF';
  String get group16 => '16位：FFFF';
  String get group32 => '32位：FFFFFFFF';
  String get autoExpandRows => '宽度足够时自动扩展为每行0x20字节';
  String get exportDataTooltip => '导出当前数据为BIN或HEX';

  // 工具输出
  String get clearToolOutput => '清空工具输出';
  String get noToolOutput => '暂无工具输出';

  // 空态
  String get openFileOrReadData => '请从工具栏打开文件，或从芯片读取数据';

  // 强制终止
  String get forceTerminateMessage =>
      '强制终止后目标状态将标记为未知，程序不会自动发送reset或resume补救命令。是否继续？';
}

final class _ProbeStrings {
  const _ProbeStrings();

  // 工具栏 / 状态栏
  String get starting => '启动中';
  String get running => '运行中';
  String get stopped => '已停止';
  String get pointCountLabel => '点数';
  String get actualRateLabel => '实际';
  String get memoryLabel => '内存';
  String get retentionLimitReached => '已达上限';
  String get plotSettings => '探针绘图设置';
  String dataConfigTitle(String mode) => '$mode 数据配置';
  String boxZoomTooltip(String boxZoomLabel) => '$boxZoomLabel（左键单次，右键连续）';

  // 空态 / 清空 / 模式切换
  String get noSamplingData => '暂无探针采样数据';
  String get clearDataConfirmMessage => '确定清空当前探针采样数据和历史吗？此操作不可撤销。';
  String get switchModeTitle => '切换探针绘图模式';
  String switchModeMessage(String from, String to) =>
      '从 $from 切换到 $to 将清空当前绘图数据，是否继续？';
  String get clearAndSwitch => '清空并切换';

  // 通道重命名
  String get renameChannel => '重命名通道';
  String get channelNameLabel => '通道名称';

  // 观察
  String get noObservation => '暂无观察';
  String get noteHint => '备注';
  String get locate => '定位';
  String get lock => '锁定';
  String get unlock => '解除锁定';
  String get selectColor => '选择颜色';

  // 绘图设置
  String get plotSettingsRangeError => '请检查绘图设置中的数值范围';
  String historyMemoryLimitHelp({
    required int min,
    required int max,
    required String currentBytes,
  }) =>
      '范围：$min~$max MiB；当前估算占用 $currentBytes。'
      '达到上限时停止采集并保留已有图像。';
  String get windowPointLimitLabel => '精确窗口点数上限';
  String get pointUnit => '点';
  String windowPointLimitHelp({required int min, required int max}) =>
      '范围：$min~$max 点；仅限制主图保留的精确点窗口，LOD 历史继续保留。';

  // RTT 数据配置
  String get rttDataConfigTitle => 'RTT 数据配置';
  String get controlBlockPositioning => 'RTT 控制块定位';
  String get controlBlockPositioningHint => '控制块定位';
  String get controlBlockAddressLabel => 'RTT 控制块地址';
  String get controlBlockAddressHint => '例如 0x20000410';
  String get rangeStartLabel => '搜索起始地址';
  String get rangeEndLabel => '搜索结束地址';
  String get pollingIntervalLabel => 'RTT 轮询间隔';
  String get rttPollingIntervalHelp => '仅 OpenOCD RTT 绘图使用；HSS 不使用此参数。';
  String get controlBlockPollingIntervalHelp => '仅 OpenOCD 后端使用；J-Link 不传递此参数。';
  String get invalidControlBlockAddress => '请输入有效的 RTT 控制块地址';
  String get rangeEndMustExceedStart => '搜索结束地址必须大于起始地址';
  String pollingIntervalRange({required int min, required int max}) =>
      'RTT 轮询间隔必须为 $min～$max ms';
  String get rttUpChannel => 'RTT Up 通道';
  String get refreshRttUpChannels => '重新识别 RTT Up 通道';
  String get rttUpChannelName => 'RTT Up 通道名称';
  String get jScopeDataFormat => 'J-Scope 数据格式';
  String get jScopeDataFormatHelp => '通道名含 JScope_i4u4 时自动识别；普通名称请手动输入 i4u4';

  // 光标跳转
  String get jumpToPacketIndexTitle => '跳转到包序号 X';
  String get packetIndexLabel => 'X（包序号）';
  String get invalidPacketIndex => '请输入整数包序号';
  String packetIndexRange({required int min, required int max}) =>
      '包序号范围应为 $min-$max';
  String packetIndexHelper({required int min, required int max}) =>
      '范围: $min-$max';
  String get jump => '跳转';

  // HSS 配置
  String get hssIntro => 'HSS 使用 OpenOCD 运行态只读内存采样，不会暂停或复位目标。';
  String get noProgramFile => '未选择程序文件';
  String get chooseProgramFile => '选择 ELF/AXF/OUT';
  String get samplingRateLabel => '采样率（1～5000 Hz）';
  String get searchElfVariables => '搜索 ELF 变量';
  String get clearSearch => '清空搜索';
  String recognizedSymbolsCount(int count) => '已识别 $count 个数据变量，单击即可加入 HSS 通道';
  String get noMatchingVariable => '没有匹配的变量';
  String get manualAddAddress => '手动添加地址';
  String get variableName => '变量名称';
  String get addressHex => '地址（HEX）';
  String get addVariable => '添加变量';
  String get removeVariable => '移除变量';

  // 探针连接弹窗
  String get clockRangeError => '调试时钟范围为 100~50000 kHz';
  String saveConfigFailed(String error) => '保存连接配置失败：$error';
  String get autoSelectedSuffix => '（自动选择）';
  String probeUnavailable(String id) => '$id（当前不存在）';
  String chooseConfigFile(String name) => '选择$name文件';
  String get connectHighPrivilegeFlashTitle => '连接高权限Flash会话';
  String flashConnectionConfirmMessage({
    required String target,
    required String backendLabel,
  }) =>
      'Flash连接可能复位或停止目标芯片。\n\n'
      '目标：$target\n'
      '后端：$backendLabel\n\n'
      '请确认目标硬件已处于允许编程的安全状态。';
  String get confirmConnect => '确认连接';
  String get selectOrInputTargetChip => '请选择或输入目标芯片';
  String get openOcdRequiresConfigs => 'OpenOCD 需要接口配置和目标配置';
  String get selectBackendHint => '选择后端';
  String get probeKind => '探针类型';
  String get autoSelect => '自动选择';
  String get probeFieldLabel => '调试探针';
  String get scanUsbDevices => '扫描 USB 设备';
  String get refreshProbes => '刷新探针';
  String get expectedBackendTooltip =>
      '仅按当前设置和工具可用性预测；探针占用、目标错误或工具启动失败仍可能导致连接失败';
  String get expectedBackendChecking => '预计使用后端：检测中…';
  String expectedBackendUnavailable(String error) => '预计使用后端：不可用（$error）';
  String expectedBackendResolved(String name) => '预计使用后端：$name';
  String get selectCmsisDapVersionHint => '选择 CMSIS-DAP 版本';
  String get cmsisDapVersionLabel => 'CMSIS-DAP 版本';
  String get openOcdInterfaceConfig => 'OpenOCD 接口配置';
  String get openOcdInterfaceHint => '例如 interface/cmsis-dap.cfg';
  String get openOcdTargetConfig => 'OpenOCD 目标配置';
  String get openOcdTargetHint => '例如 target/stm32f4x.cfg';
  String get openOcdConfigHelp =>
      '可直接输入 OpenOCD scripts 相对配置名，也可从右侧按钮选择 .cfg 文件。';
  String get targetChipLabel => '目标芯片';
  String get targetChipHint => '输入芯片型号';
  String get searchSupportedChips => '检索支持的芯片';
  String get autoDetect => '自动识别';
  String get interfaceHint => '接口';
  String get debugInterfaceLabel => '调试接口';
  String get debugClockLabel => '调试时钟';
  String get cancelling => '正在取消...';
  String get cancelConnect => '取消连接';
  String get selectTargetChipTitle => '选择目标芯片';
  String get targetSearchHint => '输入型号、厂商或来源进行模糊搜索';
  String loadTargetListFailed(String error) => '加载支持列表失败：$error';
  String get retry => '重试';
  String get noMatchingTargetChip => '没有匹配的目标芯片';
  String matchedTargetCount(int count) => '匹配 $count 项';

  // RTT 设置弹窗
  String historyLineRange({required int min, required int max}) =>
      '历史行数范围为 $min~$max';
  String get invalidSettingsError => '请修正无效设置';
  String get selectTextEncodingHint => '选择文本编码';
  String get selectTerminalFontHint => '选择终端字体';
  String get fontSizeLabel => '字号';
  String get fontPreviewLabel => '字体示例';
  String get fontPreviewText => 'SerialTools RTT  中文终端\nAa Bb 0123456789  > _';
  String get historyLinesLabel => '历史行数';
  String historyLinesHelp({
    required int min,
    required int max,
    required String currentMiB,
  }) => '范围 $min~$max 行，当前原始历史 $currentMiB MiB';
}

final class _ConnectionStrings {
  const _ConnectionStrings();

  // 数据连接弹窗
  String get connectionType => '连接类型';
  String get listenAddress => '监听地址';
  String get remoteAddress => '远端地址';
  String get listenAddressHelp => '默认监听全部本机网络接口';
  String get listenPort => '监听端口';
  String get remotePort => '远端端口';
  String get localPortOptional => '本地端口（可选）';

  // SSH 连接弹窗
  String get sshConnectionConfigTitle => 'SSH 连接配置';
  String get sshHost => '主机';
  String get sshPort => '端口';
  String get sshUsername => '用户名';
  String get sshAuthenticationMode => '认证方式';
  String get sshPassword => '密码';
  String get sshSavePassword => '保存密码（使用 Windows 凭据管理器）';
  String get sshPrivateKeyFile => 'PEM 私钥文件';
  String get sshChoosePrivateKey => '选择私钥文件';
  String get sshChoosePrivateKeyDialogTitle => '选择 SSH 私钥文件';
  String get sshPrivateKeyPassphrase => '私钥口令（可选，不会保存）';
  String get sshDisconnecting => '断开中';
  String get sshConnecting => '连接中';
  String get sshHostKeyChangedTitle => 'SSH 主机密钥已变化';
  String get sshHostKeyConfirmTitle => '确认 SSH 主机密钥';
  String get sshHostKeyChangedMessage => '已保存的主机密钥与本次连接不一致。确认服务器身份后才能替换。';
  String get sshHostKeyFirstConnectMessage => '首次连接该主机，请核对服务器显示的指纹。';
  String sshHostKeyMessage({
    required bool changed,
    required String algorithm,
    required String fingerprint,
  }) {
    final intro =
        changed ? sshHostKeyChangedMessage : sshHostKeyFirstConnectMessage;
    return '$intro\n\n算法：$algorithm\n指纹：$fingerprint';
  }

  String get sshReplaceAndConnect => '替换并连接';
  String get sshTrustAndConnect => '信任并连接';
  String get sshHostKeyConfirmationCancelled => '用户取消了 SSH 主机密钥确认';
  String sshReadPasswordFailed(String error) => '无法读取已保存的 SSH 密码：$error';
  String get sshInvalidConfig => '请填写有效的主机、端口、用户名和认证参数';
  String sshSaveConfigFailed(String error) => '保存 SSH 配置失败：$error';
  String get sshEmptyPassword => '密码为空，无法保存密码';
  String sshDisconnectFailed(String error) => 'SSH 断开失败：$error';
}

final class _MultiSendStrings {
  const _MultiSendStrings();

  String get multiSend => '多条发送';
  String get collapseMultiSend => '收起多条发送';
  String get selectSendProfile => '选择发送配置';
  String get createProfile => '新建配置';
  String get profileActions => '配置操作';
  String get renameProfile => '重命名配置';
  String get importProfile => '导入配置';
  String get exportProfile => '导出配置';
  String get deleteProfile => '删除配置';
  String get addEntry => '添加条目';
  String sendingStatus({int? round}) =>
      round == null ? '正在发送' : '正在发送 第$round轮';
  String get stopSending => '停止发送';
  String get runOnce => '执行一轮';
  String get runLoop => '持续循环';
  String get enableAtLeastOneEntry => '请先启用至少一个条目';
  String get exportProfileDialogTitle => '导出多条发送配置';
  String deleteProfileMessage(String name) => '确定删除“$name”吗？';
  String get createProfileDialogTitle => '新建发送配置';
  String get profileName => '配置名称';
  String get sendEntry => '发送此条';
  String get moreActions => '更多操作';
  String get edit => '编辑';
  String defaultEntryName(int index) => '条目$index';
  String get nameAndContentRequired => '名称和内容不能为空';
  String intervalError({required int min, required int max}) =>
      '间隔请输入 $min ~ $max ms';
  String get invalidHexData => '请输入偶数字节的 HEX 数据';
  String get addEntryTitle => '添加发送条目';
  String get editEntryTitle => '编辑发送条目';
  String get name => '名称';
  String get textLineEnding => '文本行尾';
  String get noAppend => '不追加';
  String get textMode => '文本';
  String get hexMode => 'HEX';
  String get hexContent => 'HEX 内容';
  String get sendContent => '发送内容';
  String get sendIntervalLabel => '发送后间隔 (ms)';
  String get loopEnabled => '循环启用';
  String get noProfile => '还没有发送配置';
  String get noEntries => '此配置还没有发送条目';
}
