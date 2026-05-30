import 'dart:convert';
import 'dart:io';

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

  /// 绘图窗口点数上限，范围 1000000~40000000
  int maxVisiblePoints = 1000000;
  bool snapHighlightEnabled = true;
  double snapHighlightDiameter = 8.0;

  /// 是否显示网格
  bool showGrid = true;

  /// 网格密度: 'sparse'(稀疏), 'normal'(普通), 'dense'(密集)
  String gridDensity = 'normal';

  /// 是否使用随机数据源（而非串口）
  bool useRandomSource = false;

  /// 随机数据源频率 (Hz)
  double randomFrequency = 1000.0;

  /// 最新点跟随模式开关
  bool followEnabled = false;

  /// 解析器类型名称（'fireWater' / 'fixedFrame' / 'zobow' / 'justFloat'）
  String parserType = 'fireWater';

  /// JustFloat 通道数（0=自动识别）
  int justFloatChannelCount = 0;

  /// 当前选中的众邦电控配置文件ID（空字符串表示不使用）
  String zobowProfileId = '';

  /// 快捷地址选择窗口显示模式: 'grid'(平铺) / 'list'(列表)
  String zobowPresetViewMode = 'grid';

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
      maxVisiblePoints = ((json['maxVisiblePoints'] as num?)?.toInt() ??
              1000000)
          .clamp(1000000, 40000000);
      snapHighlightEnabled = json['snapHighlightEnabled'] as bool? ?? true;
      snapHighlightDiameter =
          ((json['snapHighlightDiameter'] as num?)?.toDouble() ?? 8.0).clamp(
            6.0,
            12.0,
          );
      showGrid = json['showGrid'] as bool? ?? true;
      gridDensity = json['gridDensity'] as String? ?? 'normal';
      useRandomSource = json['useRandomSource'] as bool? ?? false;
      randomFrequency = (json['randomFrequency'] as num?)?.toDouble() ?? 1000.0;
      followEnabled = json['followEnabled'] as bool? ?? false;
      parserType = json['parserType'] as String? ?? 'fireWater';
      justFloatChannelCount =
          ((json['justFloatChannelCount'] as num?)?.toInt() ?? 0)
              .clamp(0, 16)
              .toInt();
      zobowProfileId = json['zobowProfileId'] as String? ?? '';
      zobowPresetViewMode =
          (json['zobowPresetViewMode'] as String?) == 'list' ? 'list' : 'grid';

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
      'maxVisiblePoints': maxVisiblePoints,
      'snapHighlightEnabled': snapHighlightEnabled,
      'snapHighlightDiameter': snapHighlightDiameter,
      'showGrid': showGrid,
      'gridDensity': gridDensity,
      'useRandomSource': useRandomSource,
      'randomFrequency': randomFrequency,
      'followEnabled': followEnabled,
      'parserType': parserType,
      'justFloatChannelCount': justFloatChannelCount,
      'zobowProfileId': zobowProfileId,
      'zobowPresetViewMode': zobowPresetViewMode,

      // 视口设置
      'xMin': xMin,
      'xMax': xMax,
      'yMin': yMin,
      'yMax': yMax,
    };

    final file = File(_settingsPath!);
    file.writeAsStringSync(jsonEncode(json));
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
