import 'dart:io';

import '../core/constants/plot_configuration.dart';
import '../core/constants/rtt_configuration.dart';
import '../core/utils/app_logger.dart';
import '../data/models/address_config_profile.dart';
import '../data/models/channel_config.dart';
import '../data/models/math_channel_config.dart';
import '../data/models/parser_config.dart';
import '../data/models/serial_config.dart';
import '../data/models/data_connection_config.dart';
import '../data/models/flash_programming_models.dart';
import '../data/models/modbus_models.dart';
import '../data/models/ssh_connection_config.dart';
import 'settings_repository.dart';

/// 应用设置 - 全局单例，负责配置的持久化
///
/// 配置文件存储在软件目录下：
/// - Windows：`<exe_dir>\vscope_serial\settings.json`
///
/// 使用单例模式确保全局唯一实例，通过 [AppSettings()] 访问。
/// 首次使用前需调用 [init] 加载配置，修改后调用 [save] 持久化。
class AppSettings {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  /// 应用配置文件夹名称
  static const String _appDirName = 'settings';

  /// 配置文件名称
  static const String _settingsFileName = 'settings.json';

  /// 是否已完成初始化
  bool _initialized = false;

  late final SettingsRepository _repository = SettingsRepository(
    validator: _validateSettingsSnapshot,
  );
  String? _recoveryNotice;

  // ========== 串口设置 ==========
  /// 上次连接成功的串口名称（启动时自动连接）
  String? lastPort;

  /// 串口波特率（默认 115200）
  int baudRate = 115200;

  /// 数据位（默认 8）
  int dataBits = 8;

  /// 停止位（默认 1）
  int stopBits = 1;

  /// 校验位（默认 0=无校验）
  int parity = 0;

  /// RTS 流控开关
  bool rts = false;

  /// DTR 流控开关
  bool dtr = false;

  /// 是否按数据收发、Shell、绘图和Modbus分别保存串口连接参数。
  bool separateSerialProfiles = false;
  Map<String, SerialConfig> serialPageProfiles = {};

  /// 网络入口默认关闭；两个支持页面分别保存连接类型和网络参数。
  bool networkConnectionsEnabled = false;
  Map<String, NetworkConnectionConfig> networkPageProfiles = {};
  Map<String, String> dataPageConnectionTypes = {};

  /// Modbus页面协议参数、页面配置和全局表格布局。
  String modbusMode = ModbusMode.rtu.value;
  int modbusTimeoutMs = 1000;
  int modbusLayoutMode = ModbusRegisterLayoutMode.columnMajor.value;
  ModbusByteOrder modbusByteOrder = ModbusByteOrder.highByteFirst;
  ModbusWordOrder modbusWordOrder = ModbusWordOrder.highWordFirst;
  int modbusLogMaxLines = modbusDefaultLogMaxLines;
  String modbusProfileId = '';
  List<ModbusRegisterPage> modbusPages = const [];

  /// Flash编程配置完全独立于RTT探针配置。
  FlashConnectionConfig flashConnectionConfig = const FlashConnectionConfig();

  /// 用户是否已选择不再显示Flash操作的通用高权限风险说明。
  /// 擦除、烧写等具体操作的目标与范围确认仍然保留。
  bool flashOperationRiskWarningDismissed = false;

  /// 当前实际显示的主页面。新安装默认只显示数据收发和绘图。
  List<String> visibleMainPages = const ['rawData', 'plot'];

  // ========== 绘图设置 ==========
  /// UI 刷新帧率 (fps)，范围 30~120。
  int refreshFps = PlotConfiguration.defaultRefreshFps;

  /// 绘图界面字体大小偏移，基于默认字号调整，范围 -3~6
  int plotFontSizeDelta = 0;

  /// 绘图界面文本是否使用粗体。
  bool plotFontBold = false;

  /// 主窗口上次停留的页面。
  String lastMainPage = 'rawData';

  /// 当前开启页面的标签顺序；关闭页面不保留在此列表中。
  List<String> mainTabOrder = const ['rawData', 'plot'];

  /// 绘图可导航范围上限（持久化键保持兼容）。
  int maxVisiblePoints = PlotConfiguration.defaultVisiblePointCount;

  /// 单次绘图历史的内存上限，单位 GiB，范围 1~8。
  int plotHistoryMemoryLimitGiB =
      PlotConfiguration.defaultHistoryMemoryLimitGiB;

  /// 每次开始绘图时丢弃的前置有效数据包数量。
  int discardInitialPacketCount = 0;

  /// 开始新一轮绘图时是否保留上一轮绘图数据并继续追加。
  bool keepPlotOnRestart = false;

  bool snapHighlightEnabled = true;
  double snapHighlightDiameter = 8.0;
  String snapHighlightColorMode = 'cursor';

  /// Delta X/Y 测量线样式。颜色为空时跟随当前绘图背景默认配色。
  int? xMeasurementLine1Color;
  int? xMeasurementLine2Color;
  int? yMeasurementLine1Color;
  int? yMeasurementLine2Color;
  double xMeasurementLine1Opacity = 1.0;
  double xMeasurementLine2Opacity = 1.0;
  double yMeasurementLine1Opacity = 1.0;
  double yMeasurementLine2Opacity = 1.0;
  bool yMeasurementSnapEnabled = true;
  bool xMultiMeasurementEnabled = false;
  bool yMultiMeasurementEnabled = false;

  bool statsToolbarEnabled = false;
  bool triggerToolbarEnabled = false;
  bool previewToolbarEnabled = false;

  /// 绘图接收时是否在原生层短暂合并连续小块数据。
  ///
  /// 默认关闭。启用后只在 [DataActivityOwner.plot] 持有接收活动时生效，
  /// 数据收发、Shell 和 YMODEM 始终保持逐块即时交付。
  bool plotReceiveAggregationEnabled = false;

  /// 大范围绘图 LOD 策略：performance、balanced 或 qualityHigh。
  /// quality 是两档版本遗留值，加载时迁移为 balanced。
  String plotLodQuality = 'balanced';

  /// 串口绘图数据层后端：canvas 或 d3d11，新安装默认使用 D3D11。
  String plotRenderEngine = 'd3d11';

  /// 是否已应用过 D3D11 默认引擎迁移。
  ///
  /// 旧配置首次由支持该字段的版本加载时统一切换到 D3D11；标记写入后，
  /// 用户再手动选择 Canvas 或 D3D11 都会被长期保留，不再由升级覆盖。
  bool plotRenderEngineDefaultApplied = true;

  /// 是否显示网格
  bool showGrid = true;

  /// 网格密度: 'sparse'(稀疏), 'normal'(普通), 'dense'(密集)
  String gridDensity = 'normal';

  /// 绘图背景: 'dark'(黑底), 'light'(白底)
  String plotBackground = 'dark';

  /// 绘图区悬浮窗不透明度，范围 0.0~1.0。
  double floatingPanelOpacity = 0.85;
  double? plotLegendPanelRight;
  double? plotLegendPanelTop;
  double? plotLiveValuesPanelRight;
  double? plotLiveValuesPanelTop;

  /// 添加观察时是否先跟随鼠标，再由左键固定。
  bool observationClickToPlace = false;

  /// 串口绘图轴向缩放手势使用的修饰键：shift 或 control。
  String plotGestureModifier = 'shift';

  /// 是否在数据收发页面显示串口绘图发送的协议初始化数据。
  bool showPlotSendDataInRaw = true;

  /// 是否使用随机数据源（而非串口）
  bool useRandomSource = false;

  /// 随机数据源频率 (Hz)，范围 1~100000。
  double randomFrequency = 1000.0;

  /// 最新点跟随模式开关
  bool followEnabled = false;

  /// 最新点跟随位置比例，范围 0.50~0.95。
  double followPositionRatio = 0.9;

  // ========== 探针绘图设置 ==========
  /// 探针绘图同时保留的精确点窗口，范围 10000~250000。
  int probePlotWindowPointLimit = 100000;

  /// 探针绘图历史内存预算，单位 MiB，范围 64~2048。
  int probePlotHistoryMemoryLimitMiB = 256;

  String probePlotLodQuality = 'balanced';

  /// 探针绘图数据层后端：canvas 或 d3d11，新安装默认使用 D3D11。
  String probePlotRenderEngine = 'd3d11';

  bool probePlotShowGrid = true;
  String probePlotGridDensity = 'normal';
  String probePlotBackground = 'light';
  double probePlotFloatingPanelOpacity = 0.9;
  int probePlotFontSizeDelta = 0;
  bool probePlotFontBold = false;
  double probePlotFollowPositionRatio = 0.9;
  bool probePlotObservationClickToPlace = false;

  /// 探针绘图是否在工具栏显示定位条（预览）入口。
  bool probePlotPreviewToolbarEnabled = false;

  /// Y 轴自适应数据显示占比，范围 0.50~0.95。
  double yFitDisplayRatio = 0.8;

  /// 数学通道配置，固定 Math1~Math4。
  List<MathChannelConfig> mathChannels = MathChannelConfig.createDefaults();

  /// 解析器类型名称（'fireWater' / 'fixedFrame' / 'zobow' / 'justFloat'）
  String parserType = 'zobow';

  /// 发送协议名称（'none' / 'rProtocol'）。
  String sendProtocolType = 'none';

  /// 预留给后续 Lua 自定义收发协议。
  String receiveCustomProtocolId = '';
  String sendCustomProtocolId = '';

  /// r 协议通道地址文本。保留十进制或 0x 十六进制输入形式。
  List<String> rChannelAddresses = List.filled(
    PlotConfiguration.rawChannelCount,
    '',
  );

  /// r 协议宽松通道设置：启动时将非空地址压紧到前面的槽位。
  bool rProtocolLooseChannelSettings = false;

  /// JustFloat 通道数（0=自动识别）
  int justFloatChannelCount = 0;

  /// 众邦电控通道地址，重启后恢复通道面板中的手动设置。
  List<int> zobowChannelIds = List.generate(
    ParserConfig.maxZobowChannelCount,
    (i) => i + 1,
  );

  /// 众邦电控通道数据类型，默认 int16。
  List<DataType> zobowChannelTypes = List.filled(
    ParserConfig.maxZobowChannelCount,
    DataType.int16,
  );

  /// 地址预设带入的通道名称绑定，适用于 Zobow 和 r 协议。
  List<ChannelPresetBinding> channelPresetBindings = [];

  /// 固定帧逐通道数据类型。
  List<DataType> fixedFrameChannelTypes = List.filled(
    SendProtocolConfig.maxChannelCount,
    DataType.uint16,
  );

  /// 当前选中的众邦电控配置文件ID（空字符串表示不使用）
  String zobowProfileId = '';

  /// 当前选中的 r 协议配置文件ID（空字符串表示不使用）
  String rProfileId = '';

  /// 快捷地址选择窗口显示模式: 'grid'(平铺) / 'list'(列表)
  String zobowPresetViewMode = 'grid';

  // ========== 应用更新 ==========
  /// 启动时自动检查更新。默认关闭，避免启动时主动访问网络。
  bool autoUpdateCheckEnabled = false;

  /// 更新通道：stable / beta。默认稳定版，Beta 需要用户手动选择。
  String updateChannel = 'stable';

  /// 更新来源：auto / github / gitee。auto 表示 GitHub 优先，失败后尝试 Gitee。
  String updateSource = 'auto';

  // ========== 全局设置 ==========
  /// 强制关闭应用内临时提示信息。
  bool disableNotifications = false;

  /// 是否把高密度 TRACE/DEBUG 诊断信息写入日志历史。
  bool diagnosticLoggingEnabled = false;

  /// 是否响应主窗口连接快捷键 F1/F2/F3/F5。
  bool connectionShortcutsEnabled = true;

  /// Windows 原生未处理异常是否生成小型崩溃转储。
  bool crashDumpEnabled = true;

  // ========== 原始数据设置 ==========
  /// 数据收发页面保留的最大显示行数。
  int rawDataDisplayLineLimit = 100000;

  /// 数据收发自动换行时间，单位毫秒。
  int rawDataAutoLineBreakIntervalMs = 100;

  /// Shell 输入模式：line / key。
  String rawDataShellInputMode = 'line';

  /// Shell 终端字体大小。
  double rawDataTerminalFontSize = 13.0;

  /// Shell 终端字体族。默认使用 Windows 常见等宽字体 Consolas。
  String rawDataTerminalFontFamily = 'Consolas';

  /// Shell 终端主题：light / dark。
  String rawDataShellTheme = 'light';

  /// Shell 光标样式：verticalBar / underline / block。
  String rawDataShellCursor = 'verticalBar';

  /// Shell 独立文本编码；首次升级时从数据收发编码迁移。
  String shellEncoding = 'UTF-8';

  /// Shell 命令行发送后追加的行尾。
  String shellLineEnding = '\r';

  /// Shell 命令行模式是否在发送前显示本地输入。
  bool shellLocalEcho = false;

  /// Shell 终端保留的最大历史行数。
  int shellScrollbackLines = 10000;

  /// Shell 使用普通串口/TCP，或独立 SSH 会话。
  String shellConnectionMode = ShellConnectionMode.normal.value;
  SshConnectionConfig sshConnectionConfig = const SshConnectionConfig();
  Map<String, SshKnownHost> sshKnownHosts = {};
  bool sshKeepAliveEnabled = true;

  /// YMODEM 接收文件保存策略，当前固定为 exports。
  String ymodemSaveDirectoryPolicy = 'exports';

  /// 文本解码方式，默认 UTF-8。
  String rawDataEncoding = 'UTF-8';

  /// 当前选择的多条发送配置文件。
  String rawMultiSendProfileId = '';

  // ========== RTT 设置 ==========
  /// 上次在探针连接窗口选择的后端。
  String rttBackendSelection = 'automatic';
  String rttJlinkExecutablePath = '';
  String rttOpenocdExecutablePath = '';
  String rttPyocdPythonPath = '';
  String rttPyocdCmsisDapVersion = 'automatic';
  String rttBuiltinHelperPath = '';
  String rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg';
  String rttOpenocdTargetConfig = '';
  String rttProbeKind = 'jlink';
  String rttLastProbeId = '';
  String rttTarget = '';
  bool rttAutoDetectTarget = false;
  String rttWireProtocol = 'swd';
  int rttClockKhz = 4000;
  String rttControlBlockMode = 'automatic';
  int? rttControlBlockAddress;
  int? rttControlBlockRangeStart;
  int? rttControlBlockRangeEnd;
  int rttViewerPollingIntervalMs = RttConfiguration.defaultPollingIntervalMs;
  int probeRttPollingIntervalMs = RttConfiguration.defaultPollingIntervalMs;
  String rttEncoding = 'UTF-8';
  String rttDisplayMode = 'text';
  bool rttTimestampEnabled = false;
  bool rttAutoScroll = true;
  String rttFontFamily = 'Consolas';
  double rttFontSize = 13.0;
  int rttHistoryLineLimit = RttConfiguration.defaultHistoryLines;
  List<int> rttTerminalColors = List.of(RttConfiguration.defaultTerminalColors);
  List<String> rttTerminalLabels = List.of(
    RttConfiguration.defaultTerminalLabels,
  );

  // ========== 视口设置 ==========
  /// 视口 X 轴最小值
  double xMin = PlotConfiguration.viewportDefaultXMin;

  /// 视口 X 轴最大值
  double xMax = PlotConfiguration.viewportDefaultXMax;

  /// 视口 Y 轴最小值
  double yMin = PlotConfiguration.viewportDefaultYMin;

  /// 视口 Y 轴最大值
  double yMax = PlotConfiguration.viewportDefaultYMax;

  /// 初始化：创建配置目录并加载配置文件
  ///
  /// 幂等操作：已初始化则直接返回。
  Future<void> init() async {
    if (_initialized) return;

    final exeDir = File(Platform.resolvedExecutable).parent;
    final appDir = Directory('${exeDir.path}/$_appDirName');
    if (!appDir.existsSync()) {
      appDir.createSync(recursive: true);
    }
    await _repository.setPath('${appDir.path}/$_settingsFileName');

    await _load();
    _initialized = true;
  }

  /// 恢复所有应用设置为默认值并写回配置文件。
  ///
  /// 只重置集中保存在 `settings/settings.json` 中的应用设置，不删除
  /// Zobow/r 协议地址配置等独立 JSON 配置文件。
  Future<void> resetToDefaults() async {
    _applyDefaults();
    await save();
  }

  void _applyDefaults() {
    lastPort = null;
    baudRate = 115200;
    dataBits = 8;
    stopBits = 1;
    parity = 0;
    rts = false;
    dtr = false;
    separateSerialProfiles = false;
    serialPageProfiles = {};
    networkConnectionsEnabled = false;
    networkPageProfiles = {};
    dataPageConnectionTypes = {};
    modbusMode = ModbusMode.rtu.value;
    modbusTimeoutMs = 1000;
    modbusLayoutMode = ModbusRegisterLayoutMode.columnMajor.value;
    modbusByteOrder = ModbusByteOrder.highByteFirst;
    modbusWordOrder = ModbusWordOrder.highWordFirst;
    modbusLogMaxLines = modbusDefaultLogMaxLines;
    modbusProfileId = '';
    modbusPages = const [];
    flashConnectionConfig = const FlashConnectionConfig();
    flashOperationRiskWarningDismissed = false;
    visibleMainPages = const ['rawData', 'plot'];

    refreshFps = PlotConfiguration.defaultRefreshFps;
    plotFontSizeDelta = 0;
    plotFontBold = false;
    lastMainPage = 'rawData';
    mainTabOrder = const ['rawData', 'plot'];
    maxVisiblePoints = PlotConfiguration.defaultVisiblePointCount;
    plotHistoryMemoryLimitGiB = PlotConfiguration.defaultHistoryMemoryLimitGiB;
    discardInitialPacketCount = 0;
    keepPlotOnRestart = false;
    snapHighlightEnabled = true;
    snapHighlightDiameter = 8.0;
    snapHighlightColorMode = 'cursor';
    xMeasurementLine1Color = null;
    xMeasurementLine2Color = null;
    yMeasurementLine1Color = null;
    yMeasurementLine2Color = null;
    xMeasurementLine1Opacity = 1.0;
    xMeasurementLine2Opacity = 1.0;
    yMeasurementLine1Opacity = 1.0;
    yMeasurementLine2Opacity = 1.0;
    yMeasurementSnapEnabled = true;
    xMultiMeasurementEnabled = false;
    yMultiMeasurementEnabled = false;
    statsToolbarEnabled = false;
    triggerToolbarEnabled = false;
    previewToolbarEnabled = false;
    plotReceiveAggregationEnabled = false;
    plotLodQuality = 'balanced';
    plotRenderEngine = 'd3d11';
    plotRenderEngineDefaultApplied = true;
    showGrid = true;
    gridDensity = 'normal';
    plotBackground = 'dark';
    floatingPanelOpacity = 0.85;
    plotLegendPanelRight = null;
    plotLegendPanelTop = null;
    plotLiveValuesPanelRight = null;
    plotLiveValuesPanelTop = null;
    observationClickToPlace = false;
    plotGestureModifier = 'shift';
    showPlotSendDataInRaw = true;
    useRandomSource = false;
    randomFrequency = 1000.0;
    followEnabled = false;
    followPositionRatio = 0.9;
    probePlotWindowPointLimit = 100000;
    probePlotHistoryMemoryLimitMiB = 256;
    probePlotLodQuality = 'balanced';
    probePlotRenderEngine = 'd3d11';
    probePlotShowGrid = true;
    probePlotGridDensity = 'normal';
    probePlotBackground = 'light';
    probePlotFloatingPanelOpacity = 0.9;
    probePlotFontSizeDelta = 0;
    probePlotFontBold = false;
    probePlotFollowPositionRatio = 0.9;
    probePlotObservationClickToPlace = false;
    probePlotPreviewToolbarEnabled = false;
    yFitDisplayRatio = 0.8;
    mathChannels = MathChannelConfig.createDefaults();
    parserType = 'zobow';
    sendProtocolType = 'none';
    receiveCustomProtocolId = '';
    sendCustomProtocolId = '';
    rChannelAddresses = List.filled(PlotConfiguration.rawChannelCount, '');
    rProtocolLooseChannelSettings = false;
    justFloatChannelCount = 0;
    zobowChannelIds = List.generate(
      ParserConfig.maxZobowChannelCount,
      (i) => i + 1,
    );
    zobowChannelTypes = List.filled(
      ParserConfig.maxZobowChannelCount,
      DataType.int16,
    );
    channelPresetBindings = [];
    fixedFrameChannelTypes = List.filled(
      SendProtocolConfig.maxChannelCount,
      DataType.uint16,
    );
    zobowProfileId = '';
    rProfileId = '';
    zobowPresetViewMode = 'grid';

    autoUpdateCheckEnabled = false;
    updateChannel = 'stable';
    updateSource = 'auto';
    disableNotifications = false;
    diagnosticLoggingEnabled = false;
    connectionShortcutsEnabled = true;
    crashDumpEnabled = true;

    rawDataDisplayLineLimit = 100000;
    rawDataAutoLineBreakIntervalMs = 100;
    rawDataShellInputMode = 'line';
    rawDataTerminalFontSize = 13.0;
    rawDataTerminalFontFamily = 'Consolas';
    rawDataShellTheme = 'light';
    rawDataShellCursor = 'verticalBar';
    shellEncoding = 'UTF-8';
    shellLineEnding = '\r';
    shellLocalEcho = false;
    shellScrollbackLines = 10000;
    shellConnectionMode = ShellConnectionMode.normal.value;
    sshConnectionConfig = const SshConnectionConfig();
    sshKnownHosts = {};
    sshKeepAliveEnabled = true;
    ymodemSaveDirectoryPolicy = 'exports';
    rawDataEncoding = 'UTF-8';
    rawMultiSendProfileId = '';
    rttBackendSelection = 'automatic';
    rttJlinkExecutablePath = '';
    rttOpenocdExecutablePath = '';
    rttPyocdPythonPath = '';
    rttPyocdCmsisDapVersion = 'automatic';
    rttBuiltinHelperPath = '';
    rttOpenocdInterfaceConfig = 'interface/cmsis-dap.cfg';
    rttOpenocdTargetConfig = '';
    rttProbeKind = 'jlink';
    rttLastProbeId = '';
    rttTarget = '';
    rttAutoDetectTarget = false;
    rttWireProtocol = 'swd';
    rttClockKhz = 4000;
    rttControlBlockMode = 'automatic';
    rttControlBlockAddress = null;
    rttControlBlockRangeStart = null;
    rttControlBlockRangeEnd = null;
    rttViewerPollingIntervalMs = RttConfiguration.defaultPollingIntervalMs;
    probeRttPollingIntervalMs = RttConfiguration.defaultPollingIntervalMs;
    rttEncoding = 'UTF-8';
    rttDisplayMode = 'text';
    rttTimestampEnabled = false;
    rttAutoScroll = true;
    rttFontFamily = 'Consolas';
    rttFontSize = 13.0;
    rttHistoryLineLimit = RttConfiguration.defaultHistoryLines;
    rttTerminalColors = List.of(RttConfiguration.defaultTerminalColors);
    rttTerminalLabels = List.of(RttConfiguration.defaultTerminalLabels);

    xMin = PlotConfiguration.viewportDefaultXMin;
    xMax = PlotConfiguration.viewportDefaultXMax;
    yMin = PlotConfiguration.viewportDefaultYMin;
    yMax = PlotConfiguration.viewportDefaultYMax;
  }

  /// 从配置文件加载所有设置
  ///
  /// 文件不存在时使用默认值；主文件损坏时优先恢复上一代备份。
  Future<void> _load() async {
    final result = await _repository.load();
    if (result.failed) {
      _applyDefaults();
      AppLogger().error(
        '应用设置与备份均无法读取，已使用默认值',
        category: 'SETTINGS',
        error: result.error,
        stackTrace: result.stackTrace,
      );
      AppLogger().debug(
        '主设置读取异常: ${result.primaryError}\n${result.primaryStackTrace}',
        category: 'SETTINGS',
      );
      return;
    }
    final sourceSnapshot = result.snapshot;
    if (sourceSnapshot == null) return;
    final requiresFormatMigration = sourceSnapshot['schemaVersion'] != 2;
    final json = _flattenSettingsSnapshot(sourceSnapshot);
    final requiresRenderEngineDefaultMigration =
        json['plotRenderEngineDefaultApplied'] != true;
    if (result.recoveredFromBackup) {
      _recoveryNotice = '应用设置文件损坏，已自动恢复上一份有效设置。';
      AppLogger().warning(
        '应用设置损坏，已从备份恢复: ${result.primaryError}',
        category: 'SETTINGS',
      );
    }

    try {
      // 串口设置
      lastPort = json['lastPort'] as String?;
      baudRate = json['baudRate'] as int? ?? 115200;
      dataBits = json['dataBits'] as int? ?? 8;
      stopBits = json['stopBits'] as int? ?? 1;
      parity = json['parity'] as int? ?? 0;
      rts = json['rts'] as bool? ?? false;
      dtr = json['dtr'] as bool? ?? false;
      separateSerialProfiles = json['separateSerialProfiles'] as bool? ?? false;
      final globalSerial = saveToSerialConfig();
      serialPageProfiles = _decodeSerialProfiles(
        json['serialPageProfiles'],
        globalSerial,
      );
      networkConnectionsEnabled =
          json['networkConnectionsEnabled'] as bool? ?? false;
      networkPageProfiles = _decodeNetworkProfiles(json['networkPageProfiles']);
      dataPageConnectionTypes = _decodeConnectionTypes(
        json['dataPageConnectionTypes'],
      );
      final savedModbusMode = ModbusMode.fromString(
        json['modbusMode'] as String?,
      );
      modbusMode =
          !networkConnectionsEnabled && savedModbusMode == ModbusMode.tcp
              ? ModbusMode.rtu.value
              : savedModbusMode.value;
      modbusTimeoutMs =
          ((json['modbusTimeoutMs'] as num?)?.toInt() ?? 1000)
              .clamp(100, 60000)
              .toInt();
      modbusLayoutMode =
          ModbusRegisterLayoutMode.fromValue(json['modbusLayoutMode']).value;
      modbusByteOrder = ModbusByteOrder.fromString(json['modbusByteOrder']);
      modbusWordOrder = ModbusWordOrder.fromString(json['modbusWordOrder']);
      modbusLogMaxLines =
          ((json['modbusLogMaxLines'] as num?)?.toInt() ??
                  modbusDefaultLogMaxLines)
              .clamp(modbusMinLogMaxLines, modbusMaxLogMaxLines)
              .toInt();
      modbusProfileId = json['modbusProfileId'] as String? ?? '';
      modbusPages = [
        for (final value in (json['modbusPages'] as List? ?? const []))
          if (ModbusRegisterPage.fromJson(value) case final page?) page,
      ];
      flashConnectionConfig = FlashConnectionConfig.fromJson(
        json['flashConnectionConfig'],
      );
      flashOperationRiskWarningDismissed =
          json['flashOperationRiskWarningDismissed'] as bool? ?? false;

      // 绘图设置
      refreshFps = (json['refreshFps'] as int? ??
              PlotConfiguration.defaultRefreshFps)
          .clamp(
            PlotConfiguration.minRefreshFps,
            PlotConfiguration.maxRefreshFps,
          );
      plotFontSizeDelta = (json['plotFontSizeDelta'] as int? ?? 0).clamp(-3, 6);
      plotFontBold = json['plotFontBold'] as bool? ?? false;
      final savedMainPage = json['lastMainPage'] as String?;
      lastMainPage = switch (savedMainPage) {
        'plot' => 'plot',
        'shell' => 'shell',
        'rtt' => 'rtt',
        'probePlot' => 'probePlot',
        'modbus' => 'modbus',
        'flash' => 'flash',
        _ => 'rawData',
      };
      const defaultTabOrder = [
        'rawData',
        'shell',
        'plot',
        'rtt',
        'probePlot',
        'modbus',
        'flash',
      ];
      final storedVisiblePages =
          (json['visibleMainPages'] as List?)
              ?.whereType<String>()
              .where(defaultTabOrder.contains)
              .toSet()
              .toList();
      if (storedVisiblePages != null && storedVisiblePages.isNotEmpty) {
        visibleMainPages = storedVisiblePages;
      } else if (json.containsKey('rawDataShellEnabled') ||
          json.containsKey('rttPageEnabled')) {
        visibleMainPages = [
          'rawData',
          if (json['rawDataShellEnabled'] == true) 'shell',
          'plot',
          if (json['rttPageEnabled'] == true) ...['rtt', 'probePlot'],
        ];
      } else {
        visibleMainPages = const ['rawData', 'plot'];
      }
      final storedTabOrder =
          (json['mainTabOrder'] as List?)
              ?.whereType<String>()
              .where(defaultTabOrder.contains)
              .where(visibleMainPages.contains)
              .toSet()
              .toList() ??
          const <String>[];
      // 旧版顺序会包含已关闭页面，加载时只保留当前开启页面。
      mainTabOrder = [
        ...storedTabOrder,
        ...visibleMainPages.where((id) => !storedTabOrder.contains(id)),
      ];
      final storedMaxVisiblePoints =
          (json['maxVisiblePoints'] as num?)?.toInt() ??
          PlotConfiguration.defaultVisiblePointCount;
      maxVisiblePoints =
          storedMaxVisiblePoints
              .clamp(
                PlotConfiguration.minVisiblePointCount,
                PlotConfiguration.maxVisiblePointCount,
              )
              .toInt();
      plotHistoryMemoryLimitGiB =
          ((json['plotHistoryMemoryLimitGiB'] as num?)?.toInt() ??
                  PlotConfiguration.defaultHistoryMemoryLimitGiB)
              .clamp(
                PlotConfiguration.minHistoryMemoryLimitGiB,
                PlotConfiguration.maxHistoryMemoryLimitGiB,
              )
              .toInt();
      discardInitialPacketCount =
          ((json['discardInitialPacketCount'] as num?)?.toInt() ?? 0)
              .clamp(0, PlotConfiguration.maxDiscardInitialPacketCount)
              .toInt();
      keepPlotOnRestart = json['keepPlotOnRestart'] as bool? ?? false;
      snapHighlightEnabled = json['snapHighlightEnabled'] as bool? ?? true;
      snapHighlightDiameter =
          ((json['snapHighlightDiameter'] as num?)?.toDouble() ?? 8.0).clamp(
            6.0,
            12.0,
          );
      final snapColorMode = json['snapHighlightColorMode'] as String?;
      snapHighlightColorMode =
          snapColorMode == 'channel' ? 'channel' : 'cursor';
      xMeasurementLine1Color =
          (json['xMeasurementLine1Color'] as num?)?.toInt();
      xMeasurementLine2Color =
          (json['xMeasurementLine2Color'] as num?)?.toInt();
      yMeasurementLine1Color =
          (json['yMeasurementLine1Color'] as num?)?.toInt();
      yMeasurementLine2Color =
          (json['yMeasurementLine2Color'] as num?)?.toInt();
      xMeasurementLine1Opacity =
          ((json['xMeasurementLine1Opacity'] as num?)?.toDouble() ?? 1.0).clamp(
            0.0,
            1.0,
          );
      xMeasurementLine2Opacity =
          ((json['xMeasurementLine2Opacity'] as num?)?.toDouble() ?? 1.0).clamp(
            0.0,
            1.0,
          );
      yMeasurementLine1Opacity =
          ((json['yMeasurementLine1Opacity'] as num?)?.toDouble() ?? 1.0).clamp(
            0.0,
            1.0,
          );
      yMeasurementLine2Opacity =
          ((json['yMeasurementLine2Opacity'] as num?)?.toDouble() ?? 1.0).clamp(
            0.0,
            1.0,
          );
      yMeasurementSnapEnabled =
          json['yMeasurementSnapEnabled'] as bool? ?? true;
      xMultiMeasurementEnabled =
          json['xMultiMeasurementEnabled'] as bool? ?? false;
      yMultiMeasurementEnabled =
          json['yMultiMeasurementEnabled'] as bool? ?? false;
      statsToolbarEnabled = json['statsToolbarEnabled'] as bool? ?? false;
      triggerToolbarEnabled = json['triggerToolbarEnabled'] as bool? ?? false;
      previewToolbarEnabled = json['previewToolbarEnabled'] as bool? ?? false;
      plotReceiveAggregationEnabled =
          json['plotReceiveAggregationEnabled'] as bool? ?? false;
      final savedLodQuality = json['plotLodQuality'] as String?;
      final requiresPlotLodQualityDefaultMigration =
          savedLodQuality == null || savedLodQuality.trim().isEmpty;
      plotLodQuality = switch (savedLodQuality) {
        'performance' => 'performance',
        'balanced' || 'quality' => 'balanced',
        'qualityHigh' => 'qualityHigh',
        _ => 'balanced',
      };
      if (requiresRenderEngineDefaultMigration) {
        // 只迁移一次：让升级用户同样启用 D3D11，之后尊重用户手动选择。
        plotRenderEngine = 'd3d11';
        plotRenderEngineDefaultApplied = true;
      } else {
        plotRenderEngine =
            json['plotRenderEngine'] == 'canvas' ? 'canvas' : 'd3d11';
        plotRenderEngineDefaultApplied = true;
      }
      showGrid = json['showGrid'] as bool? ?? true;
      gridDensity = json['gridDensity'] as String? ?? 'normal';
      final background = json['plotBackground'] as String?;
      plotBackground = background == 'light' ? 'light' : 'dark';
      floatingPanelOpacity =
          ((json['floatingPanelOpacity'] as num?)?.toDouble() ?? 0.85).clamp(
            0.0,
            1.0,
          );
      plotLegendPanelRight = _nullableNonNegativeDouble(
        json['plotLegendPanelRight'],
      );
      plotLegendPanelTop = _nullableNonNegativeDouble(
        json['plotLegendPanelTop'],
      );
      plotLiveValuesPanelRight = _nullableNonNegativeDouble(
        json['plotLiveValuesPanelRight'],
      );
      plotLiveValuesPanelTop = _nullableNonNegativeDouble(
        json['plotLiveValuesPanelTop'],
      );
      observationClickToPlace =
          json['observationClickToPlace'] as bool? ?? false;
      plotGestureModifier =
          json['plotGestureModifier'] == 'control' ? 'control' : 'shift';
      showPlotSendDataInRaw = json['showPlotSendDataInRaw'] as bool? ?? true;
      useRandomSource = json['useRandomSource'] as bool? ?? false;
      randomFrequency = ((json['randomFrequency'] as num?)?.toDouble() ??
              1000.0)
          .roundToDouble()
          .clamp(1.0, 100000.0);
      followEnabled = json['followEnabled'] as bool? ?? false;
      followPositionRatio =
          ((json['followPositionRatio'] as num?)?.toDouble() ?? 0.9).clamp(
            0.5,
            0.95,
          );
      probePlotWindowPointLimit =
          ((json['probePlotWindowPointLimit'] as num?)?.toInt() ?? 100000)
              .clamp(10000, PlotConfiguration.maxMaterializedPointCount)
              .toInt();
      probePlotHistoryMemoryLimitMiB =
          ((json['probePlotHistoryMemoryLimitMiB'] as num?)?.toInt() ?? 256)
              .clamp(64, 2048)
              .toInt();
      probePlotLodQuality = switch (json['probePlotLodQuality'] as String?) {
        'performance' => 'performance',
        'balanced' => 'balanced',
        'quality' => 'quality',
        _ => 'balanced',
      };
      probePlotRenderEngine =
          json['probePlotRenderEngine'] == 'canvas' ? 'canvas' : 'd3d11';
      probePlotShowGrid = json['probePlotShowGrid'] as bool? ?? true;
      probePlotGridDensity = switch (json['probePlotGridDensity'] as String?) {
        'sparse' => 'sparse',
        'dense' => 'dense',
        _ => 'normal',
      };
      probePlotBackground =
          json['probePlotBackground'] == 'dark' ? 'dark' : 'light';
      probePlotFloatingPanelOpacity =
          ((json['probePlotFloatingPanelOpacity'] as num?)?.toDouble() ?? 0.9)
              .clamp(0.0, 1.0);
      probePlotFontSizeDelta =
          ((json['probePlotFontSizeDelta'] as num?)?.toInt() ?? 0).clamp(-3, 6);
      probePlotFontBold = json['probePlotFontBold'] as bool? ?? false;
      probePlotFollowPositionRatio =
          ((json['probePlotFollowPositionRatio'] as num?)?.toDouble() ?? 0.9)
              .clamp(0.5, 0.95);
      probePlotObservationClickToPlace =
          json['probePlotObservationClickToPlace'] as bool? ?? false;
      probePlotPreviewToolbarEnabled =
          json['probePlotPreviewToolbarEnabled'] as bool? ?? false;
      yFitDisplayRatio = ((json['yFitDisplayRatio'] as num?)?.toDouble() ?? 0.8)
          .clamp(0.5, 0.95);
      mathChannels = MathChannelConfig.normalizeList(json['mathChannels']);
      parserType = json['parserType'] as String? ?? 'zobow';
      sendProtocolType = json['sendProtocolType'] as String? ?? 'none';
      receiveCustomProtocolId =
          json['receiveCustomProtocolId'] as String? ?? '';
      sendCustomProtocolId = json['sendCustomProtocolId'] as String? ?? '';
      rChannelAddresses = _normalizeStringList(json['rChannelAddresses']);
      rProtocolLooseChannelSettings =
          json['rProtocolLooseChannelSettings'] as bool? ?? false;
      justFloatChannelCount =
          ((json['justFloatChannelCount'] as num?)?.toInt() ?? 0)
              .clamp(0, PlotConfiguration.rawChannelCount)
              .toInt();
      zobowChannelIds = _normalizeZobowChannelIds(json['zobowChannelIds']);
      zobowChannelTypes = _normalizeDataTypeList(
        json['zobowChannelTypes'],
        length: ParserConfig.maxZobowChannelCount,
        fallback: DataType.int16,
        allowed: const [DataType.uint16, DataType.int16],
      );
      channelPresetBindings = _normalizeChannelPresetBindings(
        json['channelPresetBindings'],
      );
      fixedFrameChannelTypes = _normalizeDataTypeList(
        json['fixedFrameChannelTypes'],
        length: SendProtocolConfig.maxChannelCount,
        fallback: DataType.uint16,
      );
      zobowProfileId = json['zobowProfileId'] as String? ?? '';
      rProfileId = json['rProfileId'] as String? ?? '';
      zobowPresetViewMode =
          (json['zobowPresetViewMode'] as String?) == 'list' ? 'list' : 'grid';
      autoUpdateCheckEnabled = json['autoUpdateCheckEnabled'] as bool? ?? false;
      updateChannel =
          (json['updateChannel'] as String?) == 'beta' ? 'beta' : 'stable';
      updateSource = switch ((json['updateSource'] as String?)?.toLowerCase()) {
        'github' => 'github',
        'gitee' => 'gitee',
        _ => 'auto',
      };
      disableNotifications = json['disableNotifications'] as bool? ?? false;
      diagnosticLoggingEnabled =
          json['diagnosticLoggingEnabled'] as bool? ?? false;
      connectionShortcutsEnabled =
          json['connectionShortcutsEnabled'] as bool? ?? true;
      crashDumpEnabled = json['crashDumpEnabled'] as bool? ?? true;
      rawDataDisplayLineLimit =
          ((json['rawDataDisplayLineLimit'] as num?)?.toInt() ?? 100000)
              .clamp(100, 100000)
              .toInt();
      rawDataAutoLineBreakIntervalMs =
          ((json['rawDataAutoLineBreakIntervalMs'] as num?)?.toInt() ?? 100)
              .clamp(1, 10000)
              .toInt();
      rawDataShellInputMode =
          (json['rawDataShellInputMode'] as String?) == 'key' ? 'key' : 'line';
      rawDataTerminalFontSize =
          ((json['rawDataTerminalFontSize'] as num?)?.toDouble() ?? 13.0).clamp(
            10.0,
            24.0,
          );
      rawDataTerminalFontFamily = _normalizeTerminalFontFamily(
        json['rawDataTerminalFontFamily'],
      );
      rawDataShellTheme =
          (json['rawDataShellTheme'] as String?) == 'dark' ? 'dark' : 'light';
      final cursor = json['rawDataShellCursor'] as String?;
      rawDataShellCursor =
          cursor == 'block' || cursor == 'underline' ? cursor! : 'verticalBar';
      shellEncoding =
          json['shellEncoding'] as String? ??
          json['rawDataEncoding'] as String? ??
          'UTF-8';
      // 独立 Shell 首次升级时沿用旧数据收发页 Shell 共用的行尾设置。
      shellLineEnding = switch (json['shellLineEnding'] as String? ??
          json['lineEnding'] as String?) {
        '\r' => '\r',
        '\n' => '\n',
        '\r\n' => '\r\n',
        _ => '\r',
      };
      shellLocalEcho = json['shellLocalEcho'] as bool? ?? false;
      shellScrollbackLines =
          ((json['shellScrollbackLines'] as num?)?.toInt() ?? 10000)
              .clamp(1000, 100000)
              .toInt();
      final savedShellConnectionMode = ShellConnectionMode.fromString(
        json['shellConnectionMode'] as String?,
      );
      shellConnectionMode =
          !networkConnectionsEnabled &&
                  savedShellConnectionMode == ShellConnectionMode.ssh
              ? ShellConnectionMode.normal.value
              : savedShellConnectionMode.value;
      sshConnectionConfig = SshConnectionConfig.fromJson(
        json['sshConnectionConfig'],
      );
      final knownHostsJson = json['sshKnownHosts'];
      sshKnownHosts = {
        if (knownHostsJson is Map)
          for (final entry in knownHostsJson.entries)
            if (SshKnownHost.fromJson(entry.value) case final host?)
              '${entry.key}': host,
      };
      sshKeepAliveEnabled = json['sshKeepAliveEnabled'] as bool? ?? true;
      ymodemSaveDirectoryPolicy = 'exports';
      rawDataEncoding = json['rawDataEncoding'] as String? ?? 'UTF-8';
      rawMultiSendProfileId = json['rawMultiSendProfileId'] as String? ?? '';
      rttBackendSelection = switch (json['rttBackendSelection'] as String?) {
        'external-jlink' => 'external-jlink',
        'bundled-openocd' => 'bundled-openocd',
        'external-openocd' => 'external-openocd',
        'external-pyocd' => 'external-pyocd',
        _ => 'automatic',
      };
      rttJlinkExecutablePath = json['rttJlinkExecutablePath'] as String? ?? '';
      rttOpenocdExecutablePath =
          json['rttOpenocdExecutablePath'] as String? ?? '';
      rttPyocdPythonPath = json['rttPyocdPythonPath'] as String? ?? '';
      rttPyocdCmsisDapVersion = switch (json['rttPyocdCmsisDapVersion']
          as String?) {
        'v1' => 'v1',
        'v2' => 'v2',
        _ => 'automatic',
      };
      rttBuiltinHelperPath = json['rttBuiltinHelperPath'] as String? ?? '';
      rttOpenocdInterfaceConfig =
          json['rttOpenocdInterfaceConfig'] as String? ??
          'interface/cmsis-dap.cfg';
      rttOpenocdTargetConfig = json['rttOpenocdTargetConfig'] as String? ?? '';
      rttProbeKind = json['rttProbeKind'] == 'cmsisDap' ? 'cmsisDap' : 'jlink';
      rttLastProbeId = json['rttLastProbeId'] as String? ?? '';
      rttTarget = json['rttTarget'] as String? ?? '';
      rttAutoDetectTarget = json['rttAutoDetectTarget'] as bool? ?? false;
      rttWireProtocol = json['rttWireProtocol'] == 'jtag' ? 'jtag' : 'swd';
      rttClockKhz =
          ((json['rttClockKhz'] as num?)?.toInt() ?? 4000)
              .clamp(100, 50000)
              .toInt();
      rttControlBlockAddress =
          (json['rttControlBlockAddress'] as num?)?.toInt();
      rttControlBlockMode = switch (json['rttControlBlockMode'] as String?) {
        'address' => 'address',
        'range' => 'range',
        // 旧配置只有地址字段时，继续按精确地址定位。
        null when rttControlBlockAddress != null => 'address',
        _ => 'automatic',
      };
      rttControlBlockRangeStart =
          (json['rttControlBlockRangeStart'] as num?)?.toInt();
      rttControlBlockRangeEnd =
          (json['rttControlBlockRangeEnd'] as num?)?.toInt();
      final legacyRttPollingIntervalMs =
          (json['rttPollingIntervalMs'] as num?)?.toInt();
      rttViewerPollingIntervalMs =
          ((json['rttViewerPollingIntervalMs'] as num?)?.toInt() ??
                  legacyRttPollingIntervalMs ??
                  RttConfiguration.defaultPollingIntervalMs)
              .clamp(
                RttConfiguration.minPollingIntervalMs,
                RttConfiguration.maxPollingIntervalMs,
              )
              .toInt();
      probeRttPollingIntervalMs =
          ((json['probeRttPollingIntervalMs'] as num?)?.toInt() ??
                  legacyRttPollingIntervalMs ??
                  RttConfiguration.defaultPollingIntervalMs)
              .clamp(
                RttConfiguration.minPollingIntervalMs,
                RttConfiguration.maxPollingIntervalMs,
              )
              .toInt();
      rttEncoding = json['rttEncoding'] as String? ?? 'UTF-8';
      rttDisplayMode = json['rttDisplayMode'] == 'hex' ? 'hex' : 'text';
      rttTimestampEnabled = json['rttTimestampEnabled'] as bool? ?? false;
      rttAutoScroll = json['rttAutoScroll'] as bool? ?? true;
      rttFontFamily = _normalizeTerminalFontFamily(json['rttFontFamily']);
      rttFontSize = ((json['rttFontSize'] as num?)?.toDouble() ?? 13.0).clamp(
        10.0,
        24.0,
      );
      rttHistoryLineLimit =
          ((json['rttHistoryLineLimit'] as num?)?.toInt() ??
                  RttConfiguration.defaultHistoryLines)
              .clamp(
                RttConfiguration.minHistoryLines,
                RttConfiguration.maxHistoryLines,
              )
              .toInt();
      rttTerminalColors = _normalizeRttTerminalColors(
        json['rttTerminalColors'],
      );
      rttTerminalLabels = _normalizeRttTerminalLabels(
        json['rttTerminalLabels'],
      );

      // 视口设置
      xMin =
          (json['xMin'] as num?)?.toDouble() ??
          PlotConfiguration.viewportDefaultXMin;
      xMax =
          (json['xMax'] as num?)?.toDouble() ??
          PlotConfiguration.viewportDefaultXMax;
      yMin =
          (json['yMin'] as num?)?.toDouble() ??
          PlotConfiguration.viewportDefaultYMin;
      yMax =
          (json['yMax'] as num?)?.toDouble() ??
          PlotConfiguration.viewportDefaultYMax;
      if (requiresFormatMigration ||
          requiresPlotLodQualityDefaultMigration ||
          requiresRenderEngineDefaultMigration ||
          storedMaxVisiblePoints != maxVisiblePoints) {
        await save();
      }
    } catch (error, stackTrace) {
      // 快照已完整校验；这里仍整体回退，避免未来新增归一化逻辑时留下半套状态。
      _applyDefaults();
      AppLogger().error(
        '应用设置应用失败，已恢复默认值',
        category: 'SETTINGS',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static void _validateSettingsSnapshot(Map<String, dynamic> json) {
    final flattened = _flattenSettingsSnapshot(json);
    const stringKeys = <String>{
      'lastPort',
      'lastMainPage',
      'snapHighlightColorMode',
      'plotLodQuality',
      'plotRenderEngine',
      'gridDensity',
      'plotBackground',
      'probePlotLodQuality',
      'probePlotRenderEngine',
      'probePlotGridDensity',
      'probePlotBackground',
      'parserType',
      'sendProtocolType',
      'receiveCustomProtocolId',
      'sendCustomProtocolId',
      'zobowProfileId',
      'rProfileId',
      'zobowPresetViewMode',
      'updateChannel',
      'updateSource',
      'rawDataShellInputMode',
      'rawDataTerminalFontFamily',
      'rawDataShellTheme',
      'rawDataShellCursor',
      'shellEncoding',
      'shellLineEnding',
      'ymodemSaveDirectoryPolicy',
      'rawDataEncoding',
      'rawMultiSendProfileId',
      'rttBackendSelection',
      'rttJlinkExecutablePath',
      'rttOpenocdExecutablePath',
      'rttPyocdPythonPath',
      'rttPyocdCmsisDapVersion',
      'rttBuiltinHelperPath',
      'rttOpenocdInterfaceConfig',
      'rttOpenocdTargetConfig',
      'rttProbeKind',
      'rttLastProbeId',
      'rttTarget',
      'rttWireProtocol',
      'rttControlBlockMode',
      'rttEncoding',
      'rttDisplayMode',
      'rttFontFamily',
    };
    const boolKeys = <String>{
      'rts',
      'dtr',
      'plotFontBold',
      'keepPlotOnRestart',
      'snapHighlightEnabled',
      'yMeasurementSnapEnabled',
      'xMultiMeasurementEnabled',
      'yMultiMeasurementEnabled',
      'statsToolbarEnabled',
      'triggerToolbarEnabled',
      'previewToolbarEnabled',
      'plotReceiveAggregationEnabled',
      'plotRenderEngineDefaultApplied',
      'showGrid',
      'observationClickToPlace',
      'useRandomSource',
      'followEnabled',
      'probePlotShowGrid',
      'probePlotFontBold',
      'probePlotObservationClickToPlace',
      'probePlotPreviewToolbarEnabled',
      'rProtocolLooseChannelSettings',
      'autoUpdateCheckEnabled',
      'disableNotifications',
      'diagnosticLoggingEnabled',
      'connectionShortcutsEnabled',
      'crashDumpEnabled',
      'rawDataShellMode',
      'rawDataShellEnabled',
      'shellEnabled',
      'shellLocalEcho',
      'rttPageEnabled',
      'rttAutoDetectTarget',
      'rttTimestampEnabled',
      'rttAutoScroll',
    };
    const integerKeys = <String>{
      'baudRate',
      'dataBits',
      'stopBits',
      'parity',
      'refreshFps',
      'plotFontSizeDelta',
      'probePlotFontSizeDelta',
      'modbusLayoutMode',
    };
    const numberKeys = <String>{
      'maxVisiblePoints',
      'plotHistoryMemoryLimitGiB',
      'discardInitialPacketCount',
      'snapHighlightDiameter',
      'xMeasurementLine1Color',
      'xMeasurementLine2Color',
      'yMeasurementLine1Color',
      'yMeasurementLine2Color',
      'xMeasurementLine1Opacity',
      'xMeasurementLine2Opacity',
      'yMeasurementLine1Opacity',
      'yMeasurementLine2Opacity',
      'floatingPanelOpacity',
      'plotLegendPanelRight',
      'plotLegendPanelTop',
      'plotLiveValuesPanelRight',
      'plotLiveValuesPanelTop',
      'randomFrequency',
      'followPositionRatio',
      'probePlotWindowPointLimit',
      'probePlotHistoryMemoryLimitMiB',
      'probePlotFloatingPanelOpacity',
      'probePlotFollowPositionRatio',
      'yFitDisplayRatio',
      'justFloatChannelCount',
      'rawDataDisplayLineLimit',
      'rawDataAutoLineBreakIntervalMs',
      'rawDataTerminalFontSize',
      'shellScrollbackLines',
      'rttClockKhz',
      'rttControlBlockAddress',
      'rttControlBlockRangeStart',
      'rttControlBlockRangeEnd',
      'rttViewerPollingIntervalMs',
      'probeRttPollingIntervalMs',
      'rttFontSize',
      'rttHistoryLineLimit',
      'xMin',
      'xMax',
      'yMin',
      'yMax',
      'modbusTimeoutMs',
    };
    const listKeys = <String>{
      'mainTabOrder',
      'mathChannels',
      'rChannelAddresses',
      'zobowChannelIds',
      'zobowChannelTypes',
      'channelPresetBindings',
      'fixedFrameChannelTypes',
      'rttTerminalColors',
      'rttTerminalLabels',
    };

    for (final entry in flattened.entries) {
      final value = entry.value;
      if (value == null) continue;
      final valid = switch (entry.key) {
        final key when stringKeys.contains(key) => value is String,
        final key when boolKeys.contains(key) => value is bool,
        final key when integerKeys.contains(key) => value is int,
        final key when numberKeys.contains(key) => value is num,
        final key when listKeys.contains(key) => value is List,
        _ => true,
      };
      if (!valid) {
        throw FormatException('设置字段 ${entry.key} 类型错误');
      }
    }

    // 在修改实例字段前执行所有可能涉及嵌套结构的归一化。
    MathChannelConfig.normalizeList(flattened['mathChannels']);
    _normalizeStringList(flattened['rChannelAddresses']);
    _normalizeZobowChannelIds(flattened['zobowChannelIds']);
    _normalizeChannelPresetBindings(flattened['channelPresetBindings']);
    _normalizeRttTerminalColors(flattened['rttTerminalColors']);
    _normalizeRttTerminalLabels(flattened['rttTerminalLabels']);
    _normalizeDataTypeList(
      flattened['zobowChannelTypes'],
      length: ParserConfig.maxZobowChannelCount,
      fallback: DataType.int16,
    );
    _normalizeDataTypeList(
      flattened['fixedFrameChannelTypes'],
      length: SendProtocolConfig.maxChannelCount,
      fallback: DataType.uint16,
    );
  }

  /// 保存所有设置到配置文件
  ///
  /// 200ms 内的连续修改合并为一次原子写入，所有写入保持严格串行。
  Future<void> save() => _repository.save(_toJson());

  /// 应用退出前提交尚在合并窗口内的设置，并等待串行写链结束。
  Future<void> flushPendingSave() => _repository.flush();

  /// 返回并清除本次启动期间的设置恢复提示。
  String? takeRecoveryNotice() {
    final notice = _recoveryNotice;
    _recoveryNotice = null;
    return notice;
  }

  /// 测试专用：在隔离目录重新加载单例，避免改写实际应用设置。
  Future<void> debugInitializeAt(String settingsPath) async {
    await _repository.setPath(settingsPath);
    _initialized = false;
    _recoveryNotice = null;
    _applyDefaults();
    await _load();
    _initialized = true;
  }

  /// 测试专用：解除文件路径并恢复内存默认值。
  Future<void> debugDetach() async {
    await _repository.setPath(null);
    _initialized = false;
    _recoveryNotice = null;
    _applyDefaults();
  }

  Map<String, dynamic> _toJson() => _nestSettingsSnapshot(_toFlatJson());

  Map<String, dynamic> _toFlatJson() => <String, dynamic>{
    // 串口设置
    'lastPort': lastPort,
    'baudRate': baudRate,
    'dataBits': dataBits,
    'stopBits': stopBits,
    'parity': parity,
    'rts': rts,
    'dtr': dtr,
    'separateSerialProfiles': separateSerialProfiles,
    'serialPageProfiles': {
      for (final entry in serialPageProfiles.entries)
        entry.key: entry.value.toJson(),
    },
    'networkConnectionsEnabled': networkConnectionsEnabled,
    'networkPageProfiles': {
      for (final entry in networkPageProfiles.entries)
        entry.key: entry.value.toJson(),
    },
    'dataPageConnectionTypes': dataPageConnectionTypes,
    if (modbusMode != ModbusMode.rtu.value) 'modbusMode': modbusMode,
    if (modbusTimeoutMs != 1000) 'modbusTimeoutMs': modbusTimeoutMs,
    if (modbusLayoutMode != ModbusRegisterLayoutMode.columnMajor.value)
      'modbusLayoutMode': modbusLayoutMode,
    if (modbusByteOrder != ModbusByteOrder.highByteFirst)
      'modbusByteOrder': modbusByteOrder.value,
    if (modbusWordOrder != ModbusWordOrder.highWordFirst)
      'modbusWordOrder': modbusWordOrder.value,
    if (modbusLogMaxLines != modbusDefaultLogMaxLines)
      'modbusLogMaxLines': modbusLogMaxLines,
    if (modbusProfileId.isNotEmpty) 'modbusProfileId': modbusProfileId,
    if (modbusPages.isNotEmpty)
      'modbusPages': [for (final page in modbusPages) page.toSparseJson()],
    'flashConnectionConfig': flashConnectionConfig.toJson(),
    'flashOperationRiskWarningDismissed': flashOperationRiskWarningDismissed,

    // 绘图设置
    'refreshFps': refreshFps,
    'plotFontSizeDelta': plotFontSizeDelta,
    'plotFontBold': plotFontBold,
    'lastMainPage': lastMainPage,
    'mainTabOrder': mainTabOrder,
    'visibleMainPages': visibleMainPages,
    'maxVisiblePoints': maxVisiblePoints,
    'plotHistoryMemoryLimitGiB': plotHistoryMemoryLimitGiB,
    'discardInitialPacketCount': discardInitialPacketCount,
    'keepPlotOnRestart': keepPlotOnRestart,
    'snapHighlightEnabled': snapHighlightEnabled,
    'snapHighlightDiameter': snapHighlightDiameter,
    'snapHighlightColorMode': snapHighlightColorMode,
    'xMeasurementLine1Color': xMeasurementLine1Color,
    'xMeasurementLine2Color': xMeasurementLine2Color,
    'yMeasurementLine1Color': yMeasurementLine1Color,
    'yMeasurementLine2Color': yMeasurementLine2Color,
    'xMeasurementLine1Opacity': xMeasurementLine1Opacity,
    'xMeasurementLine2Opacity': xMeasurementLine2Opacity,
    'yMeasurementLine1Opacity': yMeasurementLine1Opacity,
    'yMeasurementLine2Opacity': yMeasurementLine2Opacity,
    'yMeasurementSnapEnabled': yMeasurementSnapEnabled,
    'xMultiMeasurementEnabled': xMultiMeasurementEnabled,
    'yMultiMeasurementEnabled': yMultiMeasurementEnabled,
    'statsToolbarEnabled': statsToolbarEnabled,
    'triggerToolbarEnabled': triggerToolbarEnabled,
    'previewToolbarEnabled': previewToolbarEnabled,
    'plotReceiveAggregationEnabled': plotReceiveAggregationEnabled,
    'plotLodQuality': plotLodQuality,
    'plotRenderEngine': plotRenderEngine,
    'plotRenderEngineDefaultApplied': plotRenderEngineDefaultApplied,
    'showGrid': showGrid,
    'gridDensity': gridDensity,
    'plotBackground': plotBackground,
    'floatingPanelOpacity': floatingPanelOpacity,
    'plotLegendPanelRight': plotLegendPanelRight,
    'plotLegendPanelTop': plotLegendPanelTop,
    'plotLiveValuesPanelRight': plotLiveValuesPanelRight,
    'plotLiveValuesPanelTop': plotLiveValuesPanelTop,
    'observationClickToPlace': observationClickToPlace,
    'plotGestureModifier': plotGestureModifier,
    'showPlotSendDataInRaw': showPlotSendDataInRaw,
    'useRandomSource': useRandomSource,
    'randomFrequency': randomFrequency,
    'followEnabled': followEnabled,
    'followPositionRatio': followPositionRatio,
    'probePlotWindowPointLimit': probePlotWindowPointLimit,
    'probePlotHistoryMemoryLimitMiB': probePlotHistoryMemoryLimitMiB,
    'probePlotLodQuality': probePlotLodQuality,
    'probePlotRenderEngine': probePlotRenderEngine,
    'probePlotShowGrid': probePlotShowGrid,
    'probePlotGridDensity': probePlotGridDensity,
    'probePlotBackground': probePlotBackground,
    'probePlotFloatingPanelOpacity': probePlotFloatingPanelOpacity,
    'probePlotFontSizeDelta': probePlotFontSizeDelta,
    'probePlotFontBold': probePlotFontBold,
    'probePlotFollowPositionRatio': probePlotFollowPositionRatio,
    'probePlotObservationClickToPlace': probePlotObservationClickToPlace,
    'probePlotPreviewToolbarEnabled': probePlotPreviewToolbarEnabled,
    'yFitDisplayRatio': yFitDisplayRatio,
    'mathChannels': mathChannels.map((channel) => channel.toJson()).toList(),
    'parserType': parserType,
    'sendProtocolType': sendProtocolType,
    'receiveCustomProtocolId': receiveCustomProtocolId,
    'sendCustomProtocolId': sendCustomProtocolId,
    'rChannelAddresses': rChannelAddresses,
    'rProtocolLooseChannelSettings': rProtocolLooseChannelSettings,
    'justFloatChannelCount': justFloatChannelCount,
    'zobowChannelIds': zobowChannelIds,
    'zobowChannelTypes': zobowChannelTypes.map((type) => type.name).toList(),
    'channelPresetBindings':
        channelPresetBindings.map((binding) => binding.toJson()).toList(),
    'fixedFrameChannelTypes':
        fixedFrameChannelTypes.map((type) => type.name).toList(),
    'zobowProfileId': zobowProfileId,
    'rProfileId': rProfileId,
    'zobowPresetViewMode': zobowPresetViewMode,
    'autoUpdateCheckEnabled': autoUpdateCheckEnabled,
    'updateChannel': updateChannel,
    'updateSource': updateSource,
    'disableNotifications': disableNotifications,
    'diagnosticLoggingEnabled': diagnosticLoggingEnabled,
    'connectionShortcutsEnabled': connectionShortcutsEnabled,
    'crashDumpEnabled': crashDumpEnabled,
    'rawDataDisplayLineLimit': rawDataDisplayLineLimit,
    'rawDataAutoLineBreakIntervalMs': rawDataAutoLineBreakIntervalMs,
    'rawDataShellInputMode': rawDataShellInputMode,
    'rawDataTerminalFontSize': rawDataTerminalFontSize,
    'rawDataTerminalFontFamily': rawDataTerminalFontFamily,
    'rawDataShellTheme': rawDataShellTheme,
    'rawDataShellCursor': rawDataShellCursor,
    'shellEncoding': shellEncoding,
    'shellLineEnding': shellLineEnding,
    'shellLocalEcho': shellLocalEcho,
    'shellScrollbackLines': shellScrollbackLines,
    'shellConnectionMode': shellConnectionMode,
    'sshConnectionConfig': sshConnectionConfig.toJson(),
    'sshKnownHosts': {
      for (final entry in sshKnownHosts.entries)
        entry.key: entry.value.toJson(),
    },
    'sshKeepAliveEnabled': sshKeepAliveEnabled,
    'ymodemSaveDirectoryPolicy': ymodemSaveDirectoryPolicy,
    'rawDataEncoding': rawDataEncoding,
    'rawMultiSendProfileId': rawMultiSendProfileId,
    'rttBackendSelection': rttBackendSelection,
    'rttJlinkExecutablePath': rttJlinkExecutablePath,
    'rttOpenocdExecutablePath': rttOpenocdExecutablePath,
    'rttPyocdPythonPath': rttPyocdPythonPath,
    'rttPyocdCmsisDapVersion': rttPyocdCmsisDapVersion,
    'rttBuiltinHelperPath': rttBuiltinHelperPath,
    'rttOpenocdInterfaceConfig': rttOpenocdInterfaceConfig,
    'rttOpenocdTargetConfig': rttOpenocdTargetConfig,
    'rttProbeKind': rttProbeKind,
    'rttLastProbeId': rttLastProbeId,
    'rttTarget': rttTarget,
    'rttAutoDetectTarget': rttAutoDetectTarget,
    'rttWireProtocol': rttWireProtocol,
    'rttClockKhz': rttClockKhz,
    'rttControlBlockMode': rttControlBlockMode,
    'rttControlBlockAddress': rttControlBlockAddress,
    'rttControlBlockRangeStart': rttControlBlockRangeStart,
    'rttControlBlockRangeEnd': rttControlBlockRangeEnd,
    'rttViewerPollingIntervalMs': rttViewerPollingIntervalMs,
    'probeRttPollingIntervalMs': probeRttPollingIntervalMs,
    'rttEncoding': rttEncoding,
    'rttDisplayMode': rttDisplayMode,
    'rttTimestampEnabled': rttTimestampEnabled,
    'rttAutoScroll': rttAutoScroll,
    'rttFontFamily': rttFontFamily,
    'rttFontSize': rttFontSize,
    'rttHistoryLineLimit': rttHistoryLineLimit,
    'rttTerminalColors': rttTerminalColors,
    'rttTerminalLabels': rttTerminalLabels,

    // 视口设置
    'xMin': xMin,
    'xMax': xMax,
    'yMin': yMin,
    'yMax': yMax,
  };

  /// settings.json 第二版结构：先按全局和功能分组，再按功能内部用途分组。
  ///
  /// Map 的键仍使用运行时旧字段名，值是新 JSON 中的完整路径。读取时统一
  /// 展平，业务字段无需感知持久化结构；保存时反向构造嵌套对象。
  static const Map<String, List<String>> _settingsPaths = {
    // 全局
    'lastMainPage': ['global', 'navigation', 'lastPage'],
    'mainTabOrder': ['global', 'navigation', 'pageOrder'],
    'rawDataShellEnabled': ['global', 'navigation', 'shellPageEnabled'],
    'rttPageEnabled': ['global', 'navigation', 'probePagesEnabled'],
    'disableNotifications': ['global', 'behavior', 'notificationsDisabled'],
    'diagnosticLoggingEnabled': ['global', 'behavior', 'diagnosticLogging'],
    'connectionShortcutsEnabled': ['global', 'behavior', 'connectionShortcuts'],
    'crashDumpEnabled': ['global', 'behavior', 'crashDump'],
    'autoUpdateCheckEnabled': ['global', 'updates', 'automaticCheck'],
    'updateChannel': ['global', 'updates', 'channel'],
    'updateSource': ['global', 'updates', 'source'],

    // 串口连接
    'lastPort': ['serial', 'connection', 'lastPort'],
    'baudRate': ['serial', 'connection', 'baudRate'],
    'dataBits': ['serial', 'connection', 'dataBits'],
    'stopBits': ['serial', 'connection', 'stopBits'],
    'parity': ['serial', 'connection', 'parity'],
    'rts': ['serial', 'connection', 'rts'],
    'dtr': ['serial', 'connection', 'dtr'],
    'separateSerialProfiles': ['serial', 'profiles', 'separateByPage'],
    'serialPageProfiles': ['serial', 'profiles', 'pages'],
    'networkConnectionsEnabled': ['global', 'features', 'networkConnections'],
    'networkPageProfiles': ['network', 'pageProfiles'],
    'dataPageConnectionTypes': ['network', 'selectedTypeByPage'],
    'visibleMainPages': ['global', 'navigation', 'visiblePages'],

    // Modbus
    'modbusMode': ['modbus', 'connection', 'mode'],
    'modbusTimeoutMs': ['modbus', 'protocol', 'timeoutMs'],
    'modbusLayoutMode': ['modbus', 'view', 'layoutMode'],
    'modbusByteOrder': ['modbus', 'protocol', 'byteOrder'],
    'modbusWordOrder': ['modbus', 'protocol', 'wordOrder'],
    'modbusLogMaxLines': ['modbus', 'logging', 'maxLines'],
    'modbusProfileId': ['modbus', 'profiles', 'selectedId'],
    'modbusPages': ['modbus', 'pages'],

    // Flash编程
    'flashConnectionConfig': ['flash', 'connection'],
    'flashOperationRiskWarningDismissed': [
      'flash',
      'safety',
      'operationWarningDismissed',
    ],

    // 数据收发
    'rawDataDisplayLineLimit': ['rawData', 'display', 'lineLimit'],
    'rawDataAutoLineBreakIntervalMs': [
      'rawData',
      'display',
      'autoLineBreakIntervalMs',
    ],
    'rawDataEncoding': ['rawData', 'display', 'encoding'],
    'rawMultiSendProfileId': ['rawData', 'profiles', 'multiSendProfileId'],
    'rawDataShellMode': ['rawData', 'legacyShell', 'mode'],

    // Shell
    'rawDataShellInputMode': ['shell', 'terminal', 'inputMode'],
    'rawDataTerminalFontSize': ['shell', 'terminal', 'fontSize'],
    'rawDataTerminalFontFamily': ['shell', 'terminal', 'fontFamily'],
    'rawDataShellTheme': ['shell', 'terminal', 'theme'],
    'rawDataShellCursor': ['shell', 'terminal', 'cursor'],
    'shellEncoding': ['shell', 'terminal', 'encoding'],
    'shellLineEnding': ['shell', 'terminal', 'lineEnding'],
    'shellLocalEcho': ['shell', 'terminal', 'localEcho'],
    'shellScrollbackLines': ['shell', 'terminal', 'scrollbackLines'],
    'shellConnectionMode': ['shell', 'connection', 'mode'],
    'sshConnectionConfig': ['shell', 'ssh', 'connection'],
    'sshKnownHosts': ['shell', 'ssh', 'knownHosts'],
    'sshKeepAliveEnabled': ['shell', 'ssh', 'keepAliveEnabled'],
    'ymodemSaveDirectoryPolicy': [
      'shell',
      'fileTransfer',
      'saveDirectoryPolicy',
    ],

    // 串口绘图：性能与容量
    'refreshFps': ['serialPlot', 'performance', 'refreshFps'],
    'maxVisiblePoints': ['serialPlot', 'performance', 'windowPointLimit'],
    'plotHistoryMemoryLimitGiB': [
      'serialPlot',
      'performance',
      'historyMemoryLimitGiB',
    ],
    'discardInitialPacketCount': [
      'serialPlot',
      'performance',
      'discardInitialPacketCount',
    ],
    'plotReceiveAggregationEnabled': [
      'serialPlot',
      'performance',
      'receiveAggregation',
    ],
    'plotLodQuality': ['serialPlot', 'performance', 'lodQuality'],
    'plotRenderEngine': ['serialPlot', 'performance', 'renderEngine'],
    'plotRenderEngineDefaultApplied': [
      'serialPlot',
      'performance',
      'renderEngineDefaultApplied',
    ],

    // 串口绘图：外观
    'plotFontSizeDelta': ['serialPlot', 'appearance', 'fontSizeDelta'],
    'plotFontBold': ['serialPlot', 'appearance', 'fontBold'],
    'showGrid': ['serialPlot', 'appearance', 'showGrid'],
    'gridDensity': ['serialPlot', 'appearance', 'gridDensity'],
    'plotBackground': ['serialPlot', 'appearance', 'background'],
    'floatingPanelOpacity': [
      'serialPlot',
      'appearance',
      'floatingPanelOpacity',
    ],
    'plotLegendPanelRight': ['serialPlot', 'appearance', 'legendPanelRight'],
    'plotLegendPanelTop': ['serialPlot', 'appearance', 'legendPanelTop'],
    'plotLiveValuesPanelRight': [
      'serialPlot',
      'appearance',
      'liveValuesPanelRight',
    ],
    'plotLiveValuesPanelTop': [
      'serialPlot',
      'appearance',
      'liveValuesPanelTop',
    ],

    // 串口绘图：交互和工具栏
    'keepPlotOnRestart': ['serialPlot', 'interaction', 'keepOnRestart'],
    'snapHighlightEnabled': [
      'serialPlot',
      'interaction',
      'snapHighlightEnabled',
    ],
    'snapHighlightDiameter': [
      'serialPlot',
      'interaction',
      'snapHighlightDiameter',
    ],
    'snapHighlightColorMode': [
      'serialPlot',
      'interaction',
      'snapHighlightColorMode',
    ],
    'observationClickToPlace': [
      'serialPlot',
      'interaction',
      'observationClickToPlace',
    ],
    'plotGestureModifier': ['serialPlot', 'interaction', 'zoomModifier'],
    'showPlotSendDataInRaw': ['serialPlot', 'interaction', 'showSentDataInRaw'],
    'followEnabled': ['serialPlot', 'interaction', 'followEnabled'],
    'followPositionRatio': ['serialPlot', 'interaction', 'followPositionRatio'],
    'yFitDisplayRatio': ['serialPlot', 'interaction', 'yFitDisplayRatio'],
    'statsToolbarEnabled': ['serialPlot', 'toolbar', 'statistics'],
    'triggerToolbarEnabled': ['serialPlot', 'toolbar', 'trigger'],
    'previewToolbarEnabled': ['serialPlot', 'toolbar', 'locator'],

    // Delta 测量样式由串口绘图与探针绘图共用。
    'xMeasurementLine1Color': [
      'global',
      'plotMeasurements',
      'deltaX',
      'line1Color',
    ],
    'xMeasurementLine2Color': [
      'global',
      'plotMeasurements',
      'deltaX',
      'line2Color',
    ],
    'xMeasurementLine1Opacity': [
      'global',
      'plotMeasurements',
      'deltaX',
      'line1Opacity',
    ],
    'xMeasurementLine2Opacity': [
      'global',
      'plotMeasurements',
      'deltaX',
      'line2Opacity',
    ],
    'yMeasurementLine1Color': [
      'global',
      'plotMeasurements',
      'deltaY',
      'line1Color',
    ],
    'yMeasurementLine2Color': [
      'global',
      'plotMeasurements',
      'deltaY',
      'line2Color',
    ],
    'yMeasurementLine1Opacity': [
      'global',
      'plotMeasurements',
      'deltaY',
      'line1Opacity',
    ],
    'yMeasurementLine2Opacity': [
      'global',
      'plotMeasurements',
      'deltaY',
      'line2Opacity',
    ],
    'yMeasurementSnapEnabled': [
      'global',
      'plotMeasurements',
      'deltaY',
      'snapEnabled',
    ],
    'xMultiMeasurementEnabled': [
      'serialPlot',
      'interaction',
      'deltaXMultiMeasurement',
    ],
    'yMultiMeasurementEnabled': [
      'serialPlot',
      'interaction',
      'deltaYMultiMeasurement',
    ],

    // 串口绘图：数据源、协议、通道和视口
    'useRandomSource': ['serialPlot', 'dataSource', 'randomEnabled'],
    'randomFrequency': ['serialPlot', 'dataSource', 'randomFrequency'],
    'parserType': ['serialPlot', 'protocols', 'receiveType'],
    'sendProtocolType': ['serialPlot', 'protocols', 'sendType'],
    'receiveCustomProtocolId': ['serialPlot', 'protocols', 'receiveCustomId'],
    'sendCustomProtocolId': ['serialPlot', 'protocols', 'sendCustomId'],
    'rProtocolLooseChannelSettings': [
      'serialPlot',
      'protocols',
      'rProtocolLooseChannels',
    ],
    'justFloatChannelCount': [
      'serialPlot',
      'protocols',
      'justFloatChannelCount',
    ],
    'zobowProfileId': ['serialPlot', 'profiles', 'zobowProfileId'],
    'rProfileId': ['serialPlot', 'profiles', 'rProtocolProfileId'],
    'zobowPresetViewMode': ['serialPlot', 'profiles', 'zobowPresetViewMode'],
    'mathChannels': ['serialPlot', 'channels', 'math'],
    'rChannelAddresses': ['serialPlot', 'channels', 'rProtocolAddresses'],
    'zobowChannelIds': ['serialPlot', 'channels', 'zobowIds'],
    'zobowChannelTypes': ['serialPlot', 'channels', 'zobowTypes'],
    'channelPresetBindings': ['serialPlot', 'channels', 'presetBindings'],
    'fixedFrameChannelTypes': ['serialPlot', 'channels', 'fixedFrameTypes'],
    'xMin': ['serialPlot', 'viewport', 'xMin'],
    'xMax': ['serialPlot', 'viewport', 'xMax'],
    'yMin': ['serialPlot', 'viewport', 'yMin'],
    'yMax': ['serialPlot', 'viewport', 'yMax'],

    // 探针绘图
    'probePlotWindowPointLimit': [
      'probePlot',
      'performance',
      'windowPointLimit',
    ],
    'probePlotHistoryMemoryLimitMiB': [
      'probePlot',
      'performance',
      'historyMemoryLimitMiB',
    ],
    'probePlotLodQuality': ['probePlot', 'performance', 'lodQuality'],
    'probePlotRenderEngine': ['probePlot', 'performance', 'renderEngine'],
    'probePlotShowGrid': ['probePlot', 'appearance', 'showGrid'],
    'probePlotGridDensity': ['probePlot', 'appearance', 'gridDensity'],
    'probePlotBackground': ['probePlot', 'appearance', 'background'],
    'probePlotFloatingPanelOpacity': [
      'probePlot',
      'appearance',
      'floatingPanelOpacity',
    ],
    'probePlotFontSizeDelta': ['probePlot', 'appearance', 'fontSizeDelta'],
    'probePlotFontBold': ['probePlot', 'appearance', 'fontBold'],
    'probePlotFollowPositionRatio': [
      'probePlot',
      'interaction',
      'followPositionRatio',
    ],
    'probePlotObservationClickToPlace': [
      'probePlot',
      'interaction',
      'observationClickToPlace',
    ],
    'probePlotPreviewToolbarEnabled': ['probePlot', 'toolbar', 'locator'],
    'probeRttPollingIntervalMs': ['probePlot', 'rtt', 'pollingIntervalMs'],

    // RTT 与探针连接
    'rttBackendSelection': ['rtt', 'connection', 'backend'],
    'rttJlinkExecutablePath': ['rtt', 'connection', 'jlinkExecutable'],
    'rttOpenocdExecutablePath': ['rtt', 'connection', 'openocdExecutable'],
    'rttPyocdPythonPath': ['rtt', 'connection', 'pyocdPython'],
    'rttPyocdCmsisDapVersion': ['rtt', 'connection', 'pyocdCmsisDapVersion'],
    'rttBuiltinHelperPath': ['rtt', 'connection', 'builtinHelper'],
    'rttOpenocdInterfaceConfig': [
      'rtt',
      'connection',
      'openocdInterfaceConfig',
    ],
    'rttOpenocdTargetConfig': ['rtt', 'connection', 'openocdTargetConfig'],
    'rttProbeKind': ['rtt', 'connection', 'probeKind'],
    'rttLastProbeId': ['rtt', 'connection', 'lastProbeId'],
    'rttTarget': ['rtt', 'connection', 'target'],
    'rttAutoDetectTarget': ['rtt', 'connection', 'autoDetectTarget'],
    'rttWireProtocol': ['rtt', 'connection', 'wireProtocol'],
    'rttClockKhz': ['rtt', 'connection', 'clockKhz'],
    'rttControlBlockMode': ['rtt', 'controlBlock', 'mode'],
    'rttControlBlockAddress': ['rtt', 'controlBlock', 'address'],
    'rttControlBlockRangeStart': ['rtt', 'controlBlock', 'rangeStart'],
    'rttControlBlockRangeEnd': ['rtt', 'controlBlock', 'rangeEnd'],

    // RTT Viewer
    'rttViewerPollingIntervalMs': ['rttViewer', 'receive', 'pollingIntervalMs'],
    'rttEncoding': ['rttViewer', 'display', 'encoding'],
    'rttDisplayMode': ['rttViewer', 'display', 'mode'],
    'rttTimestampEnabled': ['rttViewer', 'display', 'timestamp'],
    'rttAutoScroll': ['rttViewer', 'display', 'autoScroll'],
    'rttFontFamily': ['rttViewer', 'display', 'fontFamily'],
    'rttFontSize': ['rttViewer', 'display', 'fontSize'],
    'rttHistoryLineLimit': ['rttViewer', 'history', 'lineLimit'],
    'rttTerminalColors': ['rttViewer', 'terminals', 'colors'],
    'rttTerminalLabels': ['rttViewer', 'terminals', 'labels'],
  };

  static final Object _missingSettingValue = Object();

  static Map<String, dynamic> _nestSettingsSnapshot(
    Map<String, dynamic> flattened,
  ) {
    final unmapped = flattened.keys
        .where((key) => !_settingsPaths.containsKey(key))
        .toList(growable: false);
    if (unmapped.isNotEmpty) {
      throw StateError('存在未分组的设置字段：${unmapped.join(', ')}');
    }

    final result = <String, dynamic>{'schemaVersion': 2};
    for (final pathEntry in _settingsPaths.entries) {
      if (!flattened.containsKey(pathEntry.key)) continue;
      final path = pathEntry.value;
      Map<String, dynamic> current = result;
      for (var index = 0; index < path.length - 1; index++) {
        final segment = path[index];
        final child = current.putIfAbsent(segment, () => <String, dynamic>{});
        if (child is! Map<String, dynamic>) {
          throw StateError('设置分组路径冲突：${path.join('.')}');
        }
        current = child;
      }
      current[path.last] = flattened[pathEntry.key];
    }
    return result;
  }

  static Map<String, dynamic> _flattenSettingsSnapshot(
    Map<String, dynamic> snapshot,
  ) {
    final schemaVersion = snapshot['schemaVersion'];
    if (schemaVersion != null && schemaVersion is! int) {
      throw const FormatException('设置字段 schemaVersion 类型错误');
    }
    if (schemaVersion is int && schemaVersion > 2) {
      throw FormatException('不支持的设置格式版本：$schemaVersion');
    }

    final flattened = <String, dynamic>{};
    // 兼容 v1 单层格式，以及用户手工保留的单层字段。
    for (final key in _settingsPaths.keys) {
      if (snapshot.containsKey(key)) flattened[key] = snapshot[key];
    }
    for (final legacyKey in const [
      'shellEnabled',
      'rttPollingIntervalMs',
      'lineEnding',
    ]) {
      if (snapshot.containsKey(legacyKey)) {
        flattened[legacyKey] = snapshot[legacyKey];
      }
    }

    // v2 嵌套字段优先于同名的旧单层字段。
    for (final entry in _settingsPaths.entries) {
      final value = _readNestedSetting(snapshot, entry.value);
      if (!identical(value, _missingSettingValue)) {
        flattened[entry.key] = value;
      }
    }
    return flattened;
  }

  static Object? _readNestedSetting(
    Map<String, dynamic> snapshot,
    List<String> path,
  ) {
    Object? current = snapshot;
    for (var index = 0; index < path.length; index++) {
      if (current is! Map) {
        throw FormatException('设置分组 ${path.take(index).join('.')} 必须为对象');
      }
      final segment = path[index];
      if (!current.containsKey(segment)) return _missingSettingValue;
      current = current[segment];
    }
    return current;
  }

  static List<String> _normalizeStringList(Object? value) {
    final values =
        value is List
            ? value.whereType<String>().map((item) => item.trim()).toList()
            : <String>[];
    while (values.length < PlotConfiguration.rawChannelCount) {
      values.add('');
    }
    return values.take(PlotConfiguration.rawChannelCount).toList();
  }

  static List<int> _normalizeRttTerminalColors(Object? value) {
    final defaults = RttConfiguration.defaultTerminalColors;
    final colors = <int>[];
    if (value is List) {
      for (final item in value) {
        if (item is! num) continue;
        colors.add(0xFF000000 | (item.toInt() & 0x00FFFFFF));
        if (colors.length == defaults.length) break;
      }
    }
    while (colors.length < defaults.length) {
      colors.add(defaults[colors.length]);
    }
    return colors;
  }

  static List<String> _normalizeRttTerminalLabels(Object? value) {
    final defaults = RttConfiguration.defaultTerminalLabels;
    if (value is! List) return List.of(defaults);
    return List.generate(defaults.length, (index) {
      final text =
          index < value.length && value[index] is String
              ? (value[index] as String).trim()
              : '';
      final innerText = text.replaceAll(RegExp(r'[\[\]]'), '').trim();
      if (innerText.isEmpty) return defaults[index];
      return innerText.length <= 32 ? innerText : innerText.substring(0, 32);
    });
  }

  static double? _nullableNonNegativeDouble(Object? value) {
    if (value is! num) return null;
    final parsed = value.toDouble();
    if (!parsed.isFinite || parsed < 0) return null;
    return parsed;
  }

  static List<int> _normalizeZobowChannelIds(Object? value) {
    final values =
        value is List
            ? value
                .whereType<num>()
                .map((item) => item.toInt() & 0xFFFFFFFF)
                .toList()
            : <int>[];
    while (values.length < ParserConfig.maxZobowChannelCount) {
      values.add(values.length + 1);
    }
    return values.take(ParserConfig.maxZobowChannelCount).toList();
  }

  static List<ChannelPresetBinding> _normalizeChannelPresetBindings(
    Object? value,
  ) {
    if (value is! List) return [];
    final bindings = <ChannelPresetBinding>[];
    for (final item in value) {
      if (item is! Map<String, dynamic>) continue;
      final binding = ChannelPresetBinding.fromJson(item);
      final maxChannel =
          binding.protocolType == AddressProfileProtocolType.rProtocol
              ? SendProtocolConfig.maxChannelCount
              : ParserConfig.maxZobowChannelCount;
      if (binding.channelIndex < 0 ||
          binding.channelIndex >= maxChannel ||
          binding.addressKey.isEmpty ||
          binding.name.isEmpty) {
        continue;
      }
      bindings.add(binding);
    }
    return bindings;
  }

  static List<DataType> _normalizeDataTypeList(
    Object? value, {
    required int length,
    required DataType fallback,
    List<DataType>? allowed,
  }) {
    final allowedSet = allowed?.toSet();
    final values = <DataType>[];
    if (value is List) {
      for (final item in value) {
        final name = item?.toString();
        DataType? parsed;
        for (final type in DataType.values) {
          if (type.name == name) {
            parsed = type;
            break;
          }
        }
        if (parsed == null) continue;
        if (allowedSet != null && !allowedSet.contains(parsed)) continue;
        values.add(parsed);
      }
    }
    while (values.length < length) {
      values.add(fallback);
    }
    return values.take(length).toList();
  }

  static String _normalizeTerminalFontFamily(Object? value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? 'Consolas' : text;
  }

  static Map<String, SerialConfig> _decodeSerialProfiles(
    Object? value,
    SerialConfig fallback,
  ) {
    final source = value is Map ? value : const <Object?, Object?>{};
    return {
      for (final page in const ['rawData', 'shell', 'plot', 'modbus'])
        if (source.containsKey(page))
          page: SerialConfig.fromJson(source[page], fallback: fallback),
    };
  }

  static Map<String, NetworkConnectionConfig> _decodeNetworkProfiles(
    Object? value,
  ) {
    final source = value is Map ? value : const <Object?, Object?>{};
    return {
      for (final page in const ['rawData', 'shell', 'plot', 'modbus'])
        if (source.containsKey(page))
          page: NetworkConnectionConfig.fromJson(source[page]),
    };
  }

  static Map<String, String> _decodeConnectionTypes(Object? value) {
    final source = value is Map ? value : const <Object?, Object?>{};
    return {
      for (final page in const ['rawData', 'shell', 'plot', 'modbus'])
        if (source[page] is String) page: source[page] as String,
    };
  }

  DataConnectionType connectionTypeForPage(String pageId) {
    final type = DataConnectionType.fromString(dataPageConnectionTypes[pageId]);
    if (!networkConnectionsEnabled && type != DataConnectionType.serial) {
      return DataConnectionType.serial;
    }
    if (pageId == 'plot' && type == DataConnectionType.tcpServer) {
      return DataConnectionType.serial;
    }
    if (pageId == 'shell' &&
        type != DataConnectionType.serial &&
        type != DataConnectionType.tcpClient) {
      return DataConnectionType.serial;
    }
    if (pageId == 'modbus' &&
        type != DataConnectionType.serial &&
        type != DataConnectionType.tcpClient) {
      return DataConnectionType.serial;
    }
    return type;
  }

  void saveConnectionTypeForPage(String pageId, DataConnectionType type) {
    dataPageConnectionTypes = {...dataPageConnectionTypes, pageId: type.value};
  }

  /// 返回页面当前应使用的串口参数；默认模式仍读取旧的全局配置。
  SerialConfig serialConfigForPage(String pageId) {
    final global = saveToSerialConfig();
    if (!separateSerialProfiles) return global;
    return serialPageProfiles[pageId]?.copyWith() ?? global;
  }

  void saveSerialConfigForPage(String pageId, SerialConfig config) {
    if (!separateSerialProfiles) {
      loadFromSerialConfig(config);
      return;
    }
    serialPageProfiles = {...serialPageProfiles, pageId: config.copyWith()};
  }

  /// 首次开启时复制全局参数；已有页面参数不会被覆盖。
  void setSeparateSerialProfiles(bool enabled) {
    if (separateSerialProfiles == enabled) return;
    if (enabled) {
      final global = saveToSerialConfig();
      serialPageProfiles = {
        for (final page in const ['rawData', 'shell', 'plot', 'modbus'])
          page: serialPageProfiles[page]?.copyWith() ?? global.copyWith(),
      };
    }
    separateSerialProfiles = enabled;
  }

  NetworkConnectionConfig networkConfigForPage(String pageId) =>
      networkPageProfiles[pageId] ??
      const NetworkConnectionConfig(type: DataConnectionType.tcpClient);

  void saveNetworkConfigForPage(String pageId, NetworkConnectionConfig config) {
    networkPageProfiles = {...networkPageProfiles, pageId: config};
  }

  /// 从 [SerialConfig] 加载串口设置
  void loadFromSerialConfig(SerialConfig config) {
    lastPort = config.port;
    baudRate = config.baudRate;
    dataBits = config.dataBits;
    stopBits = config.stopBits;
    parity = config.parity;
    rts = config.rts;
    dtr = config.dtr;
  }

  /// 将串口设置保存为 [SerialConfig]
  SerialConfig saveToSerialConfig() {
    return SerialConfig(
      port: lastPort,
      baudRate: baudRate,
      dataBits: dataBits,
      stopBits: stopBits,
      parity: parity,
      rts: rts,
      dtr: dtr,
    );
  }
}
