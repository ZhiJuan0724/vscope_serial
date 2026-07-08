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
}

final class _NavStrings {
  const _NavStrings();

  String get rawData => '数据收发';
  String get plot => '绘图';
  String get protocol => '协议';
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
}

final class _StatusStrings {
  const _StatusStrings();

  String get connected => '已连接';
  String get connecting => '连接中...';
  String get disconnected => '未连接';
  String get randomSource => '随机源';
  String get appInfo => '应用信息';
}

final class _SerialStrings {
  const _SerialStrings();

  String get connectionTitle => '串口连接';
  String get showPortDetails => '显示详细信息';
  String get selectPortHint => '选择串口';
  String get port => '串口';
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
  String get placeObservation => '移动鼠标定位观察，左键固定';
  String get observation => '观察';
  String get trigger => '触发';
  String get triggerConfig => '触发配置';
  String get triggerTooltip => '左键启停触发；右键配置触发条件和触发行为';
  String get triggerObservationLimitHelp =>
      '观察最多支持 100 条；触发次数可以超过 100，但超出后不会继续新增观察。';
  String get measureXx => 'X测量';
  String get measureXxTooltip => 'Delta X 测量';
  String get measureYy => 'Y测量';
  String get measureYyTooltip => 'Delta Y 测量';
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
  String get advancedSettings => '高级设置';
  String get showGrid => '显示网格';
  String get gridDensity => '网格密度';
  String get plotBackground => '绘图背景';
  String get plotBackgroundDark => '暗色';
  String get plotBackgroundLight => '亮色';
  String get floatingPanelOpacity => '悬浮窗透明度';
  String get observationClickToPlace => '点击定位观察';
  String get observationClickToPlaceHelp => '开启后点击工具栏“观察”会先显示跟随鼠标的观察线，左键固定位置。';
  String get densitySparse => '稀疏';
  String get densityNormal => '普通';
  String get densityDense => '密集';
  String get refreshFps => '绘图刷新帧率';
  String get plotFontSize => '绘图字体大小';
  String get defaultValue => '默认';
  String get fontPreview => '参考字体';
  String get statsFeatureToggle => '显示测量统计工具';
  String get statsFeatureHelp => '开启后在工具栏添加测量统计入口，点击工具栏按钮后才启用统计';
  String get triggerFeatureToggle => '显示触发工具';
  String get triggerFeatureHelp => '开启后在工具栏添加触发入口，左键启停触发，右键配置触发条件';
  String get snapHighlight => '吸附点高亮';
  String get snapHighlightColorMode => '吸附点颜色';
  String get snapHighlightColorCursor => '跟随光标线';
  String get snapHighlightColorChannel => '跟随各自通道';
  String get plotWindowLimit => '绘图窗口上限';
  String get droppedPackets => '丢弃包数';
  String get unitFps => 'fps';
  String get unitPixel => 'px';
  String get unitPacket => '包';

  String get refreshFpsHelp => '范围: 30~60 fps，默认 60 fps\n值越高绘图越流畅，但可能降低数据接收速率';
  String get plotFontSizeHelp => '范围: -3~+6，基于默认字号调整，影响绘图区坐标轴、光标、观察、测量和统计文本';
  String get snapHighlightHelp => '范围: 6~12 px，默认 8 px。仅显示当前窗口内的吸附点';

  String plotWindowLimitHelp({
    required String min,
    required String max,
    required String defaultValue,
    required String current,
  }) {
    return '范围: $min~$max 包，默认 $defaultValue 包。当前窗口: $current 包。可输入 1M、1.5M、40M';
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
  String get rawSettingsTitle => '普通收发设置';
  String get textEncoding => '文本编码方式:';
  String get encodingHint => '编码';
  String get textEncodingHelp => '非 HEX 模式下，发送文本按选定编码转换为字节，接收字节按同一编码解码。';
  String get hexPacketTime => 'HEX分包时间 (μs):';
  String hexPacketTimeHelp(int timeWindowUs, String precisionText) {
    return '仅在 HEX显示 + 时间戳 开启时生效。当前: $timeWindowUsμs ($precisionText)';
  }

  String get microsecondTimestamp => '显示微秒级时间戳';
  String get millisecondTimestamp => '显示毫秒级时间戳';
  String get displayLineLimit => '接收区最大显示行数:';
  String get displayLineLimitHelp => '默认 100000 行。降低上限后会立即移除最早的显示内容，不影响原始字节导出。';
  String get enableShellEntry => '启用 Shell 模式入口';
  String get enableShellEntryHelp => '开启后普通收发工具栏显示 Shell 切换按钮。';
  String get timeWindowInvalid => '请输入 10 ~ 10000 之间的数值';
  String get displayLineLimitInvalid => '显示行数请输入 100 ~ 100000 之间的数值';
  String advancedSettingsSaved(int lines) => '高级设置已保存，接收区最多显示 $lines 行';
  String get terminalFontSize => '终端字号:';
  String get terminalFontFamily => '终端字体:';
  String get terminalTheme => '终端主题:';
  String get cursorStyle => '光标样式:';
  String get terminalFontSizeInvalid => '终端字号请输入 10 ~ 24 之间的数值';
  String get shellSettingsSaved => 'Shell 设置已保存';
  String get displayOptions => '显示选项';
  String get actions => '操作';
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
  String get autoCheckUpdatesHelp => '默认关闭；开启后每次打开应用会按更新来源设置检查更新';
  String get updateChannelTitle => '更新通道';
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
  String get confirmResetSettingsTitle => '确认恢复默认设置';
  String get resetSettingsWarning => '此操作会重置串口、绘图、数据收发、Shell、更新等应用设置，操作不可撤销。';
  String get resetSettingsKeepsProfiles => '绘图配置功能保存的 JSON 配置文件不会被删除。';
  String enterConfirmText(String text) => '请输入“$text”以继续：';
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
  String get noCProfileSwitchFound => '未找到 ChxValueTable 内可导入的 switch 配置';
  String importedPresetCount(int count) => '已导入 $count 个地址预设';
  String presetName(int index) => '预设$index';
}
