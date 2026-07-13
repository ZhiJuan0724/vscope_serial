import 'dart:convert';
import 'dart:io';

import '../data/models/address_config_profile.dart';
import '../data/models/channel_config.dart';
import '../data/models/math_channel_config.dart';
import '../data/models/parser_config.dart';
import '../data/models/serial_config.dart';

/// 应用设置 - 全局单例，负责配置的持久化
///
/// 配置文件存储在软件目录下：
/// - Windows: `<exe_dir>\vscope_serial\settings.json`
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

  /// 配置文件完整路径（由 [init] 设置）
  String? _settingsPath;

  /// 是否已完成初始化
  bool _initialized = false;

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

  // ========== 绘图设置 ==========
  /// UI 刷新帧率 (fps)，范围 30~60
  int refreshFps = 60;

  /// 绘图界面字体大小偏移，基于默认字号调整，范围 -3~6
  int plotFontSizeDelta = 0;

  /// 绘图界面文本是否使用粗体。
  bool plotFontBold = false;

  /// 绘图窗口点数上限，范围 1000000~40000000
  int maxVisiblePoints = 1000000;

  /// 每次开始绘图时丢弃的前置有效数据包数量，范围 0~10000。
  int discardInitialPacketCount = 0;

  /// 开始新一轮绘图时是否保留上一轮绘图数据并继续追加。
  bool keepPlotOnRestart = false;

  bool snapHighlightEnabled = true;
  double snapHighlightDiameter = 8.0;
  String snapHighlightColorMode = 'cursor';
  bool statsToolbarEnabled = false;
  bool triggerToolbarEnabled = false;
  bool previewToolbarEnabled = false;

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

  /// 是否使用随机数据源（而非串口）
  bool useRandomSource = false;

  /// 随机数据源频率 (Hz)，范围 1~100000。
  double randomFrequency = 1000.0;

  /// 最新点跟随模式开关
  bool followEnabled = false;

  /// 最新点跟随位置比例，范围 0.50~0.95。
  double followPositionRatio = 0.9;

  /// Y 轴自适应数据显示占比，范围 0.50~0.95。
  double yFitDisplayRatio = 0.8;

  /// 数学通道配置，固定 Math1~Math4。
  List<MathChannelConfig> mathChannels = MathChannelConfig.createDefaults();

  /// 解析器类型名称（'fireWater' / 'fixedFrame' / 'zobow' / 'justFloat'）
  String parserType = 'fireWater';

  /// 发送协议名称（'none' / 'rProtocol'）。
  String sendProtocolType = 'none';

  /// 预留给后续 Lua 自定义收发协议。
  String receiveCustomProtocolId = '';
  String sendCustomProtocolId = '';

  /// r 协议通道地址文本。保留十进制或 0x 十六进制输入形式。
  List<String> rChannelAddresses = List.filled(16, '');

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

  // ========== 原始数据设置 ==========
  /// 数据收发页面保留的最大显示行数。
  int rawDataDisplayLineLimit = 100000;

  /// 数据收发页面 Shell 模式开关。
  bool rawDataShellMode = false;

  /// 是否在普通收发页面显示 Shell 模式入口。
  bool rawDataShellEnabled = false;

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

  /// YMODEM 接收文件保存策略，当前固定为 exports。
  String ymodemSaveDirectoryPolicy = 'exports';

  /// 文本解码方式，默认 UTF-8。
  String rawDataEncoding = 'UTF-8';

  // ========== 视口设置 ==========
  /// 视口 X 轴最小值
  double xMin = 0;

  /// 视口 X 轴最大值
  double xMax = 1000;

  /// 视口 Y 轴最小值
  double yMin = 0;

  /// 视口 Y 轴最大值
  double yMax = 32768;

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
    _settingsPath = '${appDir.path}/$_settingsFileName';

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

    refreshFps = 60;
    plotFontSizeDelta = 0;
    plotFontBold = false;
    maxVisiblePoints = 1000000;
    discardInitialPacketCount = 0;
    keepPlotOnRestart = false;
    snapHighlightEnabled = true;
    snapHighlightDiameter = 8.0;
    snapHighlightColorMode = 'cursor';
    statsToolbarEnabled = false;
    triggerToolbarEnabled = false;
    previewToolbarEnabled = false;
    showGrid = true;
    gridDensity = 'normal';
    plotBackground = 'dark';
    floatingPanelOpacity = 0.85;
    plotLegendPanelRight = null;
    plotLegendPanelTop = null;
    plotLiveValuesPanelRight = null;
    plotLiveValuesPanelTop = null;
    observationClickToPlace = false;
    useRandomSource = false;
    randomFrequency = 1000.0;
    followEnabled = false;
    followPositionRatio = 0.9;
    yFitDisplayRatio = 0.8;
    mathChannels = MathChannelConfig.createDefaults();
    parserType = 'fireWater';
    sendProtocolType = 'none';
    receiveCustomProtocolId = '';
    sendCustomProtocolId = '';
    rChannelAddresses = List.filled(16, '');
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

    rawDataDisplayLineLimit = 100000;
    rawDataShellMode = false;
    rawDataShellEnabled = false;
    rawDataShellInputMode = 'line';
    rawDataTerminalFontSize = 13.0;
    rawDataTerminalFontFamily = 'Consolas';
    rawDataShellTheme = 'light';
    rawDataShellCursor = 'verticalBar';
    ymodemSaveDirectoryPolicy = 'exports';

    xMin = 0;
    xMax = 1000;
    yMin = 0;
    yMax = 32768;
  }

  /// 从配置文件加载所有设置
  ///
  /// 文件不存在时使用默认值，解析失败时静默使用默认值。
  Future<void> _load() async {
    if (_settingsPath == null) return;
    final file = File(_settingsPath!);
    if (!file.existsSync()) return;

    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

      // 串口设置
      lastPort = json['lastPort'] as String?;
      baudRate = json['baudRate'] as int? ?? 115200;
      dataBits = json['dataBits'] as int? ?? 8;
      stopBits = json['stopBits'] as int? ?? 1;
      parity = json['parity'] as int? ?? 0;
      rts = json['rts'] as bool? ?? false;
      dtr = json['dtr'] as bool? ?? false;

      // 绘图设置
      refreshFps = (json['refreshFps'] as int? ?? 60).clamp(30, 60);
      plotFontSizeDelta = (json['plotFontSizeDelta'] as int? ?? 0).clamp(-3, 6);
      plotFontBold = json['plotFontBold'] as bool? ?? false;
      maxVisiblePoints = ((json['maxVisiblePoints'] as num?)?.toInt() ??
              1000000)
          .clamp(1000000, 40000000);
      discardInitialPacketCount =
          ((json['discardInitialPacketCount'] as num?)?.toInt() ?? 0)
              .clamp(0, 10000)
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
      statsToolbarEnabled = json['statsToolbarEnabled'] as bool? ?? false;
      triggerToolbarEnabled = json['triggerToolbarEnabled'] as bool? ?? false;
      previewToolbarEnabled = json['previewToolbarEnabled'] as bool? ?? false;
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
      yFitDisplayRatio = ((json['yFitDisplayRatio'] as num?)?.toDouble() ?? 0.8)
          .clamp(0.5, 0.95);
      mathChannels = MathChannelConfig.normalizeList(json['mathChannels']);
      parserType = json['parserType'] as String? ?? 'fireWater';
      sendProtocolType = json['sendProtocolType'] as String? ?? 'none';
      receiveCustomProtocolId =
          json['receiveCustomProtocolId'] as String? ?? '';
      sendCustomProtocolId = json['sendCustomProtocolId'] as String? ?? '';
      rChannelAddresses = _normalizeStringList(json['rChannelAddresses']);
      rProtocolLooseChannelSettings =
          json['rProtocolLooseChannelSettings'] as bool? ?? false;
      justFloatChannelCount =
          ((json['justFloatChannelCount'] as num?)?.toInt() ?? 0)
              .clamp(0, 16)
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
      rawDataDisplayLineLimit =
          ((json['rawDataDisplayLineLimit'] as num?)?.toInt() ?? 100000)
              .clamp(100, 100000)
              .toInt();
      rawDataShellMode = json['rawDataShellMode'] as bool? ?? false;
      rawDataShellEnabled = json['rawDataShellEnabled'] as bool? ?? false;
      if (!rawDataShellEnabled) rawDataShellMode = false;
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
      ymodemSaveDirectoryPolicy = 'exports';
      rawDataEncoding = json['rawDataEncoding'] as String? ?? 'UTF-8';

      // 视口设置
      xMin = (json['xMin'] as num?)?.toDouble() ?? 0;
      xMax = (json['xMax'] as num?)?.toDouble() ?? 1000;
      yMin = (json['yMin'] as num?)?.toDouble() ?? 0;
      yMax = (json['yMax'] as num?)?.toDouble() ?? 32768;
    } catch (e) {
      // 配置文件损坏，使用默认值
    }
  }

  /// 保存所有设置到配置文件
  ///
  /// 配置以 JSON 格式写入，覆盖原有内容。
  Future<void> save() async {
    if (_settingsPath == null) return;

    final json = <String, dynamic>{
      // 串口设置
      'lastPort': lastPort,
      'baudRate': baudRate,
      'dataBits': dataBits,
      'stopBits': stopBits,
      'parity': parity,
      'rts': rts,
      'dtr': dtr,

      // 绘图设置
      'refreshFps': refreshFps,
      'plotFontSizeDelta': plotFontSizeDelta,
      'plotFontBold': plotFontBold,
      'maxVisiblePoints': maxVisiblePoints,
      'discardInitialPacketCount': discardInitialPacketCount,
      'keepPlotOnRestart': keepPlotOnRestart,
      'snapHighlightEnabled': snapHighlightEnabled,
      'snapHighlightDiameter': snapHighlightDiameter,
      'snapHighlightColorMode': snapHighlightColorMode,
      'statsToolbarEnabled': statsToolbarEnabled,
      'triggerToolbarEnabled': triggerToolbarEnabled,
      'previewToolbarEnabled': previewToolbarEnabled,
      'showGrid': showGrid,
      'gridDensity': gridDensity,
      'plotBackground': plotBackground,
      'floatingPanelOpacity': floatingPanelOpacity,
      'plotLegendPanelRight': plotLegendPanelRight,
      'plotLegendPanelTop': plotLegendPanelTop,
      'plotLiveValuesPanelRight': plotLiveValuesPanelRight,
      'plotLiveValuesPanelTop': plotLiveValuesPanelTop,
      'observationClickToPlace': observationClickToPlace,
      'useRandomSource': useRandomSource,
      'randomFrequency': randomFrequency,
      'followEnabled': followEnabled,
      'followPositionRatio': followPositionRatio,
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
      'rawDataDisplayLineLimit': rawDataDisplayLineLimit,
      'rawDataShellMode': rawDataShellMode,
      'rawDataShellEnabled': rawDataShellEnabled,
      'rawDataShellInputMode': rawDataShellInputMode,
      'rawDataTerminalFontSize': rawDataTerminalFontSize,
      'rawDataTerminalFontFamily': rawDataTerminalFontFamily,
      'rawDataShellTheme': rawDataShellTheme,
      'rawDataShellCursor': rawDataShellCursor,
      'ymodemSaveDirectoryPolicy': ymodemSaveDirectoryPolicy,
      'rawDataEncoding': rawDataEncoding,

      // 视口设置
      'xMin': xMin,
      'xMax': xMax,
      'yMin': yMin,
      'yMax': yMax,
    };

    final file = File(_settingsPath!);
    file.writeAsStringSync(jsonEncode(json));
  }

  static List<String> _normalizeStringList(Object? value) {
    final values =
        value is List
            ? value.whereType<String>().map((item) => item.trim()).toList()
            : <String>[];
    while (values.length < 16) {
      values.add('');
    }
    return values.take(16).toList();
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
