import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/channel_config.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/data_source_config.dart';
import '../data/models/parse_result.dart';
import '../data/models/parser_config.dart';
import '../data/models/plot_data.dart';
import '../data/models/plot_lod_index.dart';
import '../data/parser/data_parser.dart';
import '../data/parser/firewater_parser.dart';
import '../data/parser/fixed_frame_parser.dart';
import '../data/parser/just_float_parser.dart';
import '../data/parser/zobow_parser.dart';
import '../data/source/data_source_manager.dart';
import '../data/models/zobow_config_profile.dart';
import '../services/app_notifications.dart';
import '../services/app_settings.dart';
import '../services/zobow_profile_service.dart';
import '../views/plot/plot_painter.dart';
import '../views/plot/plot_viewport.dart';
import 'base_viewmodel.dart';

typedef PlotImportProgressCallback = void Function(PlotImportProgress progress);

class PlotImportProgress {
  final String stage;
  final int current;
  final int total;
  final String? detail;

  const PlotImportProgress({
    required this.stage,
    required this.current,
    required this.total,
    this.detail,
  });

  double? get fraction {
    if (total <= 0) return null;
    return (current / total).clamp(0.0, 1.0);
  }
}

/// 绘图页面核心 ViewModel，负责整个波形绘图页面的业务逻辑。
///
/// 主要职责：
/// - 管理数据源（串口/随机源）的启动与停止
/// - 管理数据解析器（FireWater / 固定帧）的配置与切换
/// - 维护数据缓冲区，控制最大点数限制（10万点）
/// - 管理绘图视口（viewport）的缩放、平移、自适应、历史记录
/// - 提供光标系统（垂直跟随光标、X-X/Y-Y 测量光标、统计范围）
/// - 管理通道配置（可见性、颜色、缩放、偏移）
/// - 控制 UI 刷新频率（30~60 fps），实现数据接收与 UI 刷新解耦
/// - 统计测量（Max/Min/Avg）与 CSV 导出
/// - 配置持久化（通过 AppSettings）
///
/// 数据流：DataSourceManager → IDataParser → _dataPoints → PlotPainter
/// UI 刷新：通过 notifyListeners() 驱动 Consumer[PlotViewModel] 重建
class PlotViewModel extends BaseViewModel {
  // ========== 数据源 ==========
  /// 数据源管理器，封装串口和随机数据源的统一接口
  late final DataSourceManager _sourceManager;

  // ========== 解析器 ==========
  /// 当前使用的数据解析器（FireWater 或固定帧）
  IDataParser? _parser;

  /// 数据源字节流的订阅，dispose 时需要取消
  StreamSubscription? _parseSubscription;

  // ========== 数据缓冲区 ==========
  /// 当前绘图窗口的数据点（按 index 递增排序）
  final List<PlotDataPoint> _dataPoints = [];

  /// FireWater 等无法按固定帧随机访问的协议使用紧凑历史值缓存。
  ///
  /// Zobow 和固定帧协议使用原始帧缓存作为历史源；文本协议保存解析后
  /// 的数值块，并按视口重建当前绘图窗口。
  final _ParsedValueHistory _parsedHistory = _ParsedValueHistory();

  /// 全量历史的内存级 LOD 索引，用于大窗口拖动/缩放绘制。
  final PlotLodIndex _lodIndex = PlotLodIndex();

  /// 当前窗口最大点数，避免 UI 持有过多 PlotDataPoint 对象
  static const int minVisiblePoints = 1000000;
  static const int defaultVisiblePoints = 1000000;
  static const int maxVisiblePointsLimit = 40000000;
  int _maxVisiblePoints = defaultVisiblePoints;
  int _dataRevision = 0;

  /// 众邦电控有效原始帧缓存（本次运行内全量保留）。
  FixedPacketByteBuffer _zobowRawFrames = FixedPacketByteBuffer(
    packetSize: ZobowParser.frameLengthForConfig(ParserConfig.zobowDefault()),
  );

  FixedPacketByteBuffer _fixedFrameRawFrames = FixedPacketByteBuffer(
    packetSize: ParserConfig.fixedFrameDefault().totalFrameLength,
  );

  /// 当前窗口起始点序号
  int _visibleStartIndex = 0;

  /// 下一个数据点的索引序号（单调递增）
  int _nextIndex = 0;

  /// 绘图开始时间，用于计算时间戳
  DateTime? _startTime;

  // ========== 速率统计（基于计数器，避免遍历列表）==========
  /// 速率统计样本列表，用于计算实时接收速率
  final List<_RateSample> _rateSamples = [];

  /// 速率样本最大数量（最近1000个）
  static const int _maxRateSamples = 1000;

  // ========== 当前数据实际通道数 ==========
  /// 当前数据中实际出现的最大通道数（用于动态显示通道面板）
  int _activeChannelCount = 0;

  bool _hasStartedPlottingOnce = false;

  // ========== 视口 ==========
  /// 当前绘图视口，定义可见的 X/Y 数据范围
  PlotViewport viewport = PlotViewport(
    xMin: 0,
    xMax: 1000,
    yMin: 0,
    yMax: 32768,
  );

  // ========== 视口历史记录（用于撤回） ==========
  /// 视口历史记录栈，每次缩放/平移前保存当前状态
  final List<PlotViewport> _viewportHistory = [];

  /// 视口历史最大深度
  static const int _maxHistory = 50;

  // ========== 通道配置 ==========
  /// 通道配置列表（默认16通道），包含颜色、可见性、缩放、偏移等
  final List<ChannelConfig> channels = ChannelConfig.createDefaults();
  List<int>? _importedChannelAddresses;
  List<int>? get importedChannelAddresses =>
      _importedChannelAddresses == null
          ? null
          : List.unmodifiable(_importedChannelAddresses!);

  // ========== 状态 ==========
  /// 是否正在绘图（数据源运行中）
  bool _isPlotting = false;

  /// 是否正在停止绘图。
  ///
  /// 停止过程可能包含取消订阅、停止数据源、释放解析器等耗时操作。
  /// UI 先切换到停止中状态，避免用户重复点击造成并发清理。
  bool _isStopping = false;
  Future<void>? _stopFuture;

  /// 是否显示网格
  bool _showGrid = true;

  /// 是否使用随机数据源（而非串口）
  bool _useRandomSource = false;

  // ========== 高级设置 ==========
  /// UI 刷新帧率 (fps)，范围 30~60，默认 60
  int _refreshFps = 60;

  /// 绘图界面字体大小偏移，基于默认字号调整，范围 -3~6
  int _plotFontSizeDelta = 0;

  /// 网格密度: 'sparse'(稀疏), 'normal'(普通), 'dense'(密集)
  String _gridDensity = 'normal';

  /// 抗锯齿固定开启。
  static const bool _antiAliasEnabled = true;
  bool _snapHighlightEnabled = true;
  double _snapHighlightDiameter = 8.0;

  /// 最新点跟随模式：最新数据点保持在视口 3/4 宽度处
  bool _followEnabled = false;

  /// 单垂直光标开关（鼠标悬停显示垂直线+tooltip）
  bool _vCursorEnabled = false;

  /// X-X 测量开关（两条垂直测量线）
  bool _xMeasurementEnabled = false;

  /// Y-Y 测量开关（两条水平测量线）
  bool _yMeasurementEnabled = false;

  /// 统计测量开关（Max/Min/Avg）
  bool _statsEnabled = false;

  /// 统计范围开关（限定统计的 X 范围）
  bool _statsRangeEnabled = false;

  /// 统计范围左边界
  double? _statsX1;

  /// 统计范围右边界
  double? _statsX2;
  String? _cachedStatsText;
  String? _cachedStatsKey;

  /// 当前光标模式
  // cursorMode 已废弃，保留 CursorMode.follow 用于垂直光标标识
  /// 当前光标状态（由各种光标模式共用）
  CursorState? _cursor;

  final List<CursorState> _observations = [];

  /// 当前解析器类型
  ParserType _parserType = ParserType.fireWater;

  /// 解析器配置（FireWater 和固定帧共用）
  final ParserConfig _parserConfig = ParserConfig.fireWaterDefault();

  // ========== 缩放按钮状态 ==========
  /// 框选放大模式开关
  bool _boxZoomEnabled = false;

  // ========== 数据源配置 ==========
  /// 数据源配置（串口/随机源切换、随机源频率等）
  final DataSourceConfig _sourceConfig = DataSourceConfig();

  // ========== x-x / y-y 光标 ==========
  /// X-X 测量第一条垂直线位置（数据坐标）
  double? _xCursor1;

  /// X-X 测量第二条垂直线位置（数据坐标）
  double? _xCursor2;

  /// Y-Y 测量第一条水平线位置（数据坐标）
  double? _yCursor1;

  /// Y-Y 测量第二条水平线位置（数据坐标）
  double? _yCursor2;
  List<SnapHighlightPoint> _xCursor1SnapHighlights = const [];
  List<SnapHighlightPoint> _xCursor2SnapHighlights = const [];
  List<SnapHighlightPoint> _yCursor1SnapHighlights = const [];
  List<SnapHighlightPoint> _yCursor2SnapHighlights = const [];

  // ========== 众邦电控配置文件 ==========
  /// 配置文件服务
  final ZobowProfileService _profileService = ZobowProfileService();

  /// 配置文件列表（供UI下拉框使用）
  List<ZobowConfigProfile> get zobowProfiles => _profileService.profiles;

  /// 当前选中的配置文件
  ZobowConfigProfile? get selectedZobowProfile =>
      _profileService.selectedProfile;

  /// 当前选中的配置文件ID
  String get selectedZobowProfileId => _profileService.selectedProfileId;

  // ========== 定时刷新 ==========
  /// 定时刷新器，用于光标跟随和停止后的交互响应
  Timer? _refreshTimer;

  /// Last transient notification, retained for diagnostics and tests.
  String? _lastStatusMessage;
  bool _disposed = false;

  /// 定时刷新间隔（ms），无数据时保持 UI 响应
  static const int _refreshIntervalMs = 100;

  // ========== UI 刷新降频（数据不丢失）==========
  /// 待刷新的数据包计数，达到批量大小后触发 UI 刷新
  int _pendingNotifyCount = 0;

  /// 动态批量大小：控制 UI 刷新频率，数据始终全部接收
  /// 根据 _refreshFps 计算：batchSize = targetRate / fps
  /// 串口数据源使用固定批量大小（1000Hz / 30fps ≈ 33），避免依赖 randomIntervalMs
  int get _notifyBatchSize {
    if (_useRandomSource) {
      // 随机数据源：根据配置的频率计算
      final intervalMs = _sourceConfig.randomIntervalMs;
      final targetRate = 1000.0 / intervalMs; // 每秒目标包数
      final batch = (targetRate / _refreshFps).round().clamp(1, 1000);
      return batch;
    } else {
      // 串口数据源：使用固定批量，假设典型速率 1000Hz
      // 1000Hz / 30fps = 33 帧/刷新
      const assumedRate = 1000.0;
      final batch = (assumedRate / _refreshFps).round().clamp(10, 200);
      return batch;
    }
  }

  /// Fallback 定时器：确保数据流中断时 UI 仍能刷新
  Timer? _notifyTimer;

  // ========== 接收速率调试统计 ==========
  /// 上次日志报告时间
  DateTime? _lastRateLogTime;

  /// 上次日志报告时的 _nextIndex
  int _lastRateLogIndex = 0;

  /// 接收字节数统计（用于排查串口读取性能）
  int _totalReceivedBytes = 0;

  /// 上次日志报告时的接收字节数
  int _lastRateLogBytes = 0;

  /// 创建 PlotViewModel 并初始化数据源管理器、加载设置、启动定时刷新
  PlotViewModel(super.serialService) {
    _sourceManager = DataSourceManager(serialService);
    _loadSettings();
    _initZobowProfileService();
    _startRefreshTimer();
  }

  /// 初始化Zobow配置文件服务
  Future<void> _initZobowProfileService() async {
    await _profileService.init();
    // 加载上次选中的配置文件
    final savedProfileId = AppSettings().zobowProfileId;
    if (savedProfileId.isNotEmpty) {
      _profileService.selectProfile(savedProfileId);
    }
    Future.microtask(() => notifyListeners());
  }

  /// 从 AppSettings 加载绘图配置
  void _loadSettings() {
    final settings = AppSettings();
    _refreshFps = settings.refreshFps;
    _plotFontSizeDelta = settings.plotFontSizeDelta.clamp(-3, 6);
    _maxVisiblePoints = settings.maxVisiblePoints.clamp(
      minVisiblePoints,
      maxVisiblePointsLimit,
    );
    _showGrid = settings.showGrid;
    _gridDensity = settings.gridDensity;
    _snapHighlightEnabled = settings.snapHighlightEnabled;
    _snapHighlightDiameter = settings.snapHighlightDiameter.clamp(6.0, 12.0);
    _useRandomSource = settings.useRandomSource;
    _followEnabled = settings.followEnabled;
    _sourceConfig.randomIntervalMs = (1000.0 / settings.randomFrequency)
        .round()
        .clamp(1, 1000);
    viewport = PlotViewport(
      xMin: settings.xMin,
      xMax: settings.xMax,
      yMin: settings.yMin,
      yMax: settings.yMax,
    );
    // 同步到 serialService
    serialService.useRandomSource = _useRandomSource;
    // 加载解析器类型
    _parserType = _parserTypeFromString(settings.parserType);
    _parserConfig.type = _parserType;
    if (_parserType == ParserType.justFloat) {
      _parserConfig.channelCount =
          settings.justFloatChannelCount.clamp(0, 16).toInt();
    }
  }

  /// 保存绘图配置到 AppSettings
  void _saveSettings() {
    final settings = AppSettings();
    settings.refreshFps = _refreshFps;
    settings.plotFontSizeDelta = _plotFontSizeDelta;
    settings.maxVisiblePoints = _maxVisiblePoints;
    settings.snapHighlightEnabled = _snapHighlightEnabled;
    settings.snapHighlightDiameter = _snapHighlightDiameter;
    settings.showGrid = _showGrid;
    settings.gridDensity = _gridDensity;
    settings.useRandomSource = _useRandomSource;
    settings.randomFrequency = randomFrequency;
    settings.followEnabled = _followEnabled;
    settings.parserType = _parserType.name;
    if (_parserType == ParserType.justFloat) {
      settings.justFloatChannelCount =
          _parserConfig.channelCount.clamp(0, 16).toInt();
    }
    settings.zobowProfileId = _profileService.selectedProfileId;
    // vCursorEnabled 不持久化
    settings.xMin = viewport.xMin;
    settings.xMax = viewport.xMax;
    settings.yMin = viewport.yMin;
    settings.yMax = viewport.yMax;
    settings.save();
  }

  // ========== Getters ==========
  /// 当前绘图窗口的数据点列表（供 UI 读取）。
  ///
  /// 这里直接返回稳定窗口引用，避免每次 build 复制大列表。
  List<PlotDataPoint> get dataPoints => _dataPoints;
  bool get isPlotting => _isPlotting;
  bool get isStopping => _isStopping;
  bool get showGrid => _showGrid;
  bool get useRandomSource => _useRandomSource;
  int get refreshFps => _refreshFps;
  int get plotFontSizeDelta => _plotFontSizeDelta;
  String get gridDensity => _gridDensity;
  bool get boxZoomEnabled => _boxZoomEnabled;
  bool get followEnabled => _followEnabled;
  bool get vCursorEnabled => _vCursorEnabled;
  bool get xMeasurementEnabled => _xMeasurementEnabled;
  bool get yMeasurementEnabled => _yMeasurementEnabled;
  bool get statsEnabled => _statsEnabled;
  bool get statsRangeEnabled => _statsRangeEnabled;
  double? get statsX1 => _statsX1;
  double? get statsX2 => _statsX2;
  bool get antiAliasEnabled => _antiAliasEnabled;
  bool get snapHighlightEnabled => _snapHighlightEnabled;
  double get snapHighlightDiameter => _snapHighlightDiameter;
  CursorState? get cursor => _cursor;
  List<CursorState> get observations => List.unmodifiable(_observations);
  List<SnapHighlightPoint> get snapHighlights {
    if (!_snapHighlightEnabled) return const [];
    return [
      ..._xCursor1SnapHighlights,
      ..._xCursor2SnapHighlights,
      ..._yCursor1SnapHighlights,
      ..._yCursor2SnapHighlights,
      ..._observationSnapHighlights(),
    ];
  }

  ParserType get parserType => _parserType;
  ParserConfig get parserConfig => _parserConfig;
  PlotLodIndex get lodIndex => _lodIndex;
  int get zobowRawFrameCount => _zobowRawFrames.packetCount;

  /// 本次绘图接收到的数据点总数
  int get pointCount => _nextIndex;

  /// 当前窗口中的数据点数量
  int get visiblePointCount => _dataPoints.length;

  /// 当前窗口起始点序号
  int get visibleStartIndex => _visibleStartIndex;

  /// 当前窗口点数上限
  int get maxVisiblePoints => _maxVisiblePoints;

  /// 当前窗口数据版本，用于窗口长度不变但内容滚动时触发重绘。
  int get dataRevision => _dataRevision;

  /// 当前数据中实际出现的最大通道数
  int get activeChannelCount => _activeChannelCount;

  /// 随机源频率（Hz），由间隔毫秒数换算
  double get randomFrequency => 1000.0 / _sourceConfig.randomIntervalMs;

  /// X-X 测量第一条垂直线位置
  double? get xCursor1 => _xCursor1;

  /// X-X 测量第二条垂直线位置
  double? get xCursor2 => _xCursor2;

  /// Y-Y 测量第一条水平线位置
  double? get yCursor1 => _yCursor1;

  /// Y-Y 测量第二条水平线位置
  double? get yCursor2 => _yCursor2;

  /// 是否有可撤回的视口历史
  bool get canUndoZoom => _viewportHistory.isNotEmpty;

  int get _visibleEndIndex => _visibleStartIndex + _dataPoints.length;

  /// 状态栏提示文本，根据当前状态给用户操作建议
  ///
  /// 提示场景：
  /// - 未连接串口且未使用随机源 → 提示先连接串口或启用随机源
  /// - 串口连接中 → 提示正在连接
  /// - 串口已连接但未开始绘图 → 提示点击开始按钮
  /// - 众邦电控模式下 → 提示地址在通道面板设置
  String get hintText {
    if (serialService.isConnecting) {
      return '正在连接串口...';
    }
    if (_isPlotting) {
      final sources = <String>[];
      if (serialService.isConnected) {
        sources.add('串口 ${serialService.config.port ?? ''}'.trim());
      }
      if (_useRandomSource && _parserType == ParserType.fireWater) {
        sources.add('随机源 ${randomFrequency.toStringAsFixed(0)}Hz');
      }
      return sources.isEmpty ? '绘图中' : '数据源：${sources.join(' + ')}';
    }
    if (_isStopping) {
      return '正在停止绘图...';
    }
    if (_useRandomSource && _parserType != ParserType.fireWater) {
      if (!serialService.isConnected) {
        return '随机源仅支持 FireWater；当前解析器需要连接串口后绘图';
      }
      return '随机源已保留；当前解析器仅使用串口数据';
    }
    if (!serialService.isConnected && !_useRandomSource) {
      return '串口未连接，无法从串口绘图；可连接串口或启用随机源';
    }
    if (!serialService.isConnected && _useRandomSource) {
      return '随机源已启用，点击开始绘图';
    }
    if (serialService.isConnected) {
      return '串口已连接，点击开始按钮开始绘图';
    }
    return '';
  }

  /// 状态栏文本，显示当前视口范围、数据点数、接收速率、运行状态
  String get statusText {
    final buffer = StringBuffer();
    buffer.write('X: ${viewport.xMin.toInt()}-${viewport.xMax.toInt()} ');
    buffer.write('Y: ${viewport.yMin.toInt()}-${viewport.yMax.toInt()} ');
    // 计算每秒点数
    final pointsPerSecond = _calculatePointsPerSecond();
    if (pointsPerSecond != null) {
      buffer.write('点数: $_nextIndex (${pointsPerSecond.toStringAsFixed(1)}/s)');
    } else {
      buffer.write('点数: $_nextIndex');
    }
    if (_dataPoints.isNotEmpty && _dataPoints.length < _nextIndex) {
      buffer.write(' 窗口: $_visibleStartIndex-${_visibleEndIndex - 1}');
    }
    if (_isPlotting) {
      buffer.write(' [运行中]');
    }
    return buffer.toString();
  }

  /// 计算每秒点数，基于最近500ms的数据（响应更快）
  /// 使用计数器方式，避免遍历整个数据列表
  double? _calculatePointsPerSecond() {
    if (_rateSamples.length < 2 || _startTime == null) return null;
    final now = DateTime.now();
    final nowMs = now.difference(_startTime!).inMilliseconds;
    final cutoffMs = nowMs - 500; // 最近500ms

    // 二分查找找到500ms前的样本位置
    int left = 0, right = _rateSamples.length - 1;
    int startIdx = 0;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (_rateSamples[mid].timestampMs < cutoffMs) {
        startIdx = mid + 1;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    final recentCount = _rateSamples.length - startIdx;
    if (recentCount < 2) return null;
    return recentCount * 2.0; // 500ms * 2 = 1s
  }

  /// Show a floating transient notification.
  String? get lastStatusMessage => _lastStatusMessage;

  void showStatusMessage(
    String message, {
    Duration duration = const Duration(seconds: 4),
  }) {
    if (_disposed) return;
    _lastStatusMessage = message;
    AppNotifications.show(message, duration: duration);
  }

  // ========== 定时刷新 ==========
  /// 启动定时刷新器。
  ///
  /// 绘图运行时：定时刷新确保垂直光标跟随鼠标、数据更新及时显示。
  /// 停止绘图后：定时器继续运行（即使无光标），确保拖动/缩放等交互
  /// 的视觉反馈及时，避免因纯手势回调驱动导致的卡顿感。
  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: _refreshIntervalMs),
      (_) {
        // 光标模式下定时刷新（让垂直光标跟随鼠标）
        if (_vCursorEnabled && _cursor != null) {
          Future.microtask(() => notifyListeners());
        }
      },
    );
  }

  /// 停止定时刷新器
  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  // ========== 数据源控制 ==========
  /// 切换随机数据源开关
  ///
  /// 如果正在绘图，会自动重启数据源以应用变更。
  /// 同时同步更新 serialService 的随机源状态。
  void setUseRandomSource(bool value) {
    _useRandomSource = value;
    _sourceConfig.useRandom = value && _parserType == ParserType.fireWater;
    _sourceConfig.useSerial = serialService.isConnected;
    // 根据 FireWater 配置的通道数设置随机数据源通道数
    // 如果 fireWaterChannelCount 为 0，则默认输出 4 通道
    _sourceConfig.randomChannelCount =
        _parserConfig.fireWaterChannelCount > 0
            ? _parserConfig.fireWaterChannelCount
            : 4;
    _sourceManager.updateConfig(_sourceConfig);
    _saveSettings();

    if (value && _parserType != ParserType.fireWater) {
      showStatusMessage('随机源已保留；随机源数据仅支持 FireWater 解析器');
    } else {
      showStatusMessage(value ? '随机源已启用' : '随机源已关闭');
    }

    // 如果正在绘图，重启数据源
    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置随机源频率（Hz），范围 1~10000
  void setRandomFrequency(double hz) {
    final clampedHz = hz.clamp(1.0, 10000.0);
    final intervalMs = (1000.0 / clampedHz).round().clamp(1, 1000);
    _sourceConfig.randomIntervalMs = intervalMs;
    _sourceManager.updateConfig(_sourceConfig);
    _saveSettings();

    // 如果正在绘图，重启数据源以应用新频率
    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  // ========== 解析器控制 ==========
  /// 切换解析器类型（FireWater / 固定帧 / 众邦电控）
  ///
  /// 如果正在绘图，会自动重启以应用新解析器。
  /// 注意：随机数据源仅适用于 FireWater 协议，切换到其他解析器时保留开关
  /// 状态，但不会把随机源接入当前解析链。
  void setParserType(ParserType type) {
    _parserType = type;
    _parserConfig.type = type;
    if (type == ParserType.zobow &&
        _parserConfig.channelCount != ParserConfig.maxZobowChannelCount) {
      _parserConfig.channelCount = ParserConfig.minZobowChannelCount;
    } else if (type == ParserType.justFloat) {
      _parserConfig.channelCount =
          AppSettings().justFloatChannelCount.clamp(0, 16).toInt();
    }

    if (type != ParserType.fireWater && _useRandomSource) {
      AppLogger().info('切换到非 FireWater 协议，保留随机源开关但不接入当前解析链', category: 'PLOT');
      showStatusMessage('随机源已保留；当前解析器仅使用串口数据');
    }

    // 保存解析器类型到设置
    final settings = AppSettings();
    settings.parserType = type.name;
    if (type == ParserType.justFloat) {
      settings.justFloatChannelCount =
          _parserConfig.channelCount.clamp(0, 16).toInt();
    }
    settings.save();

    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  /// 更新解析器配置并同步到数据源
  ///
  /// 同时更新随机数据源的通道数以匹配 FireWater 配置。
  void updateParserConfig(ParserConfig config) {
    final oldZobowFrameLength = ZobowParser.frameLengthForConfig(_parserConfig);
    final oldFixedFrameLength = _parserConfig.totalFrameLength;
    _parserConfig.type = config.type;
    _parserConfig.frameHeaderLength = config.frameHeaderLength;
    _parserConfig.frameHeader = List.from(config.frameHeader);
    _parserConfig.dataType = config.dataType;
    _parserConfig.channelCount = config.channelCount;
    _parserConfig.fireWaterChannelCount = config.fireWaterChannelCount;
    _parserConfig.hasChecksum = config.hasChecksum;
    _parserConfig.checksumType = config.checksumType;
    _parserConfig.checksumBytes = config.checksumBytes;
    _parserConfig.hasFrameTail = config.hasFrameTail;
    _parserConfig.frameTail =
        config.frameTail != null ? List.from(config.frameTail!) : null;
    _parserConfig.zobowChannelIds = List.from(config.zobowChannelIds);
    _parserConfig.zobowChannelTypes = List.from(config.zobowChannelTypes);
    final newZobowFrameLength = ZobowParser.frameLengthForConfig(_parserConfig);
    final zobowFrameLengthChanged = oldZobowFrameLength != newZobowFrameLength;
    final fixedFrameLengthChanged =
        oldFixedFrameLength != _parserConfig.totalFrameLength;
    if (zobowFrameLengthChanged) {
      _resetZobowRawFrameBuffer();
    }
    if (fixedFrameLengthChanged) {
      _resetFixedFrameRawFrameBuffer();
    }
    if (zobowFrameLengthChanged || fixedFrameLengthChanged) {
      clearData();
    }

    // 更新随机数据源通道数以匹配 FireWater 配置
    _sourceConfig.randomChannelCount =
        config.fireWaterChannelCount > 0 ? config.fireWaterChannelCount : 4;
    _sourceManager.updateConfig(_sourceConfig);
    if (_parserType == ParserType.justFloat) {
      final settings = AppSettings();
      settings.justFloatChannelCount =
          _parserConfig.channelCount.clamp(0, 16).toInt();
      settings.save();
    }

    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  // ========== 绘图控制 ==========
  /// 开始绘图
  ///
  /// 流程：
  /// 1. 检查数据源可用性（串口已连接或随机源已启用）
  /// 2. 清空旧数据、重置视口和光标
  /// 3. 创建解析器并启动数据源
  /// 4. 连接数据流：DataSourceManager → Parser → _dataPoints
  /// 5. 启动定时刷新
  Future<void> startPlotting() async {
    if (_isStopping) {
      showStatusMessage('正在停止绘图，请稍候');
      return;
    }
    if (_isPlotting) return;

    if (serialService.isConnected) {
      final connected = await serialService.refreshConnectionStatus();
      if (!connected && !_useRandomSource) {
        const message = '检测到串口已断开，无法绘图；请重新连接串口';
        showStatusMessage(message);
        AppLogger().warning(message, category: 'PLOT');
        return;
      }
    }

    final canUseRandom =
        _useRandomSource && _parserType == ParserType.fireWater;

    // 检查是否有数据源
    if (!serialService.isConnected && !_useRandomSource) {
      const message = '串口未连接，无法绘图；请连接串口或启用随机源';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      return;
    }

    if (!serialService.isConnected && _useRandomSource && !canUseRandom) {
      const message = '随机源仅支持 FireWater 解析器，请切回 FireWater 或连接串口';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      return;
    }

    // 再次确认数据源配置与实际状态一致
    _sourceConfig.useSerial = serialService.isConnected;
    _sourceConfig.useRandom = canUseRandom;

    // 清空旧数据
    _dataPoints.clear();
    _parsedHistory.clear();
    _lodIndex.clear();
    _zobowRawFrames.clear();
    _fixedFrameRawFrames.clear();
    _importedChannelAddresses = null;
    _visibleStartIndex = 0;
    _dataRevision++;
    _rateSamples.clear();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = DateTime.now();

    // 重置速率统计
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;

    // 保留上一轮缩放比例；首次启动仍使用默认视口。
    if (_hasStartedPlottingOnce) {
      final xRange = viewport.xRange;
      viewport = viewport.copyWith(xMin: 0, xMax: xRange);
    } else {
      viewport = viewport.reset();
      _hasStartedPlottingOnce = true;
    }
    _viewportHistory.clear();

    // 重置光标（垂直光标为临时功能，每次开始绘图时关闭）
    _vCursorEnabled = false;
    _cursor = null;
    _observations.clear();
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _clearSnapHighlights();

    // 创建解析器
    _parser = _createParser();

    // 发送协议初始化数据（如果有）。初始化失败时不能继续启动绘图，
    // 否则串口物理断开后会进入“看似绘图中但没有数据”的错误状态。
    if (!_sendProtocolInitData()) {
      _parser?.dispose();
      _parser = null;
      _sourceConfig.useSerial = false;
      _sourceConfig.useRandom = false;
      serialService.isPlotting = false;
      const message = '协议初始化发送失败，已停止绘图并断开串口';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      Future.microtask(() => notifyListeners());
      return;
    }

    // 配置并启动数据源
    // 注意：useSerial/useRandom 已在开头同步
    // 根据 FireWater 配置设置随机数据源通道数
    _sourceConfig.randomChannelCount =
        _parserConfig.fireWaterChannelCount > 0
            ? _parserConfig.fireWaterChannelCount
            : 4;
    _sourceManager.updateConfig(_sourceConfig);
    _isPlotting = true;
    serialService.isPlotting = true;
    _sourceManager.start();

    // 连接数据源 → 解析器
    _parseSubscription = _sourceManager.byteStream.listen(
      (data) => _parser?.feed(data),
      onError: (error) {
        AppLogger().error('数据源错误: $error', category: 'PLOT');
      },
    );

    // 连接解析器 → 数据缓冲区
    _parser?.outputStream.listen(
      (result) => _onParseResult(result),
      onError: (error) {
        AppLogger().error('解析器错误: $error', category: 'PLOT');
      },
    );

    // 开始绘图时自动停止原始数据接收
    if (serialService.isRawReceiving) {
      serialService.stopRawReceiving();
    }
    Future.microtask(() => serialService.notifyListeners());
    _startRefreshTimer();
    AppLogger().info('开始绘图', category: 'PLOT');
    showStatusMessage('开始绘图');
    Future.microtask(() => notifyListeners());
  }

  /// 停止绘图
  ///
  /// 取消数据流订阅、停止数据源、释放解析器，但保持定时刷新运行
  /// 以确保交互响应及时。
  Future<void> stopPlotting() {
    if (_isStopping) {
      return _stopFuture ?? Future.value();
    }
    if (!_isPlotting) return Future.value();

    _isStopping = true;
    _isPlotting = false;
    serialService.isPlotting = false;
    // 停止绘图后保持定时刷新，确保交互响应及时
    _startRefreshTimer();
    showStatusMessage('正在停止绘图...', duration: Duration.zero);
    Future.microtask(() => serialService.notifyListeners());
    Future.microtask(() => notifyListeners());

    _stopFuture = Future<void>(() async {
      await _parseSubscription?.cancel();
      _parseSubscription = null;
      _sourceManager.stop();
      _parser?.dispose();
      _parser = null;

      _notifyTimer?.cancel();
      _notifyTimer = null;
      _pendingNotifyCount = 0;
      _isStopping = false;
      if (!_disposed) {
        showStatusMessage('已停止绘图');
        Future.microtask(() {
          if (!_disposed) notifyListeners();
        });
      }
    }).whenComplete(() {
      _stopFuture = null;
    });
    return _stopFuture!;
  }

  /// 重启绘图（用于配置变更时）
  void _restartPlotting() {
    stopPlotting().then((_) {
      if (!_disposed) unawaited(startPlotting());
    });
  }

  /// 清空所有数据、速率统计、视口和光标
  void clearData() {
    _dataPoints.clear();
    _parsedHistory.clear();
    _lodIndex.clear();
    _zobowRawFrames.clear();
    _fixedFrameRawFrames.clear();
    _importedChannelAddresses = null;
    _visibleStartIndex = 0;
    _dataRevision++;
    _rateSamples.clear();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = null;
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;
    viewport = viewport.reset();
    _viewportHistory.clear();
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _clearSnapHighlights();
    Future.microtask(() => notifyListeners());
  }

  // ========== 数据接收 ==========
  @visibleForTesting
  void ingestParsedResultForTest(ParseResult result) {
    _onParseResult(result);
  }

  /// 处理解析器输出的数据包
  ///
  /// 每包数据都处理（不丢失），但 UI 刷新按 [_notifyBatchSize] 批量触发：
  /// - 添加数据点到缓冲区，超限时从头部批量移除
  /// - 更新速率统计样本
  /// - 更新实际通道数
  /// - 跟随模式下自动平移视口
  /// - 批量计数达到阈值或 fallback 定时器到期时触发 notifyListeners()
  void _onParseResult(ParseResult result) {
    if (!result.success || result.values == null || result.values!.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final timestamp =
        _startTime != null
            ? now.difference(_startTime!).inMilliseconds.toDouble()
            : 0.0;

    final point = PlotDataPoint(
      index: _nextIndex++,
      timestamp: timestamp,
      values: List.from(result.values!),
    );

    if (_parserType == ParserType.zobow && result.rawBytes != null) {
      _zobowRawFrames.appendPacket(result.rawBytes!);
    } else if (_parserType == ParserType.fixedFrame &&
        result.rawBytes != null) {
      _fixedFrameRawFrames.appendPacket(result.rawBytes!);
    } else {
      _parsedHistory.add(point.values);
    }
    _lodIndex.add(point.index, point.values);

    final appendToVisibleWindow = _isViewingTail || _followEnabled;
    if (appendToVisibleWindow) {
      _dataPoints.add(point);
      _trimVisibleWindowToLimit();
      _dataRevision++;
    }

    // 统计接收字节数
    _totalReceivedBytes += result.bytesConsumed;

    // 记录速率统计样本
    _rateSamples.add(_RateSample(_nextIndex - 1, timestamp.toInt()));
    while (_rateSamples.length > _maxRateSamples) {
      _rateSamples.removeAt(0);
    }

    // 更新实际通道数。JustFloat 自动识别模式下以最新有效帧为准，
    // 避免上一帧较多通道遗留的偏置轴继续显示。
    final nextActiveChannelCount =
        _parserType == ParserType.justFloat && _parserConfig.channelCount == 0
            ? point.channelCount
            : (point.channelCount > _activeChannelCount
                ? point.channelCount
                : _activeChannelCount);
    if (nextActiveChannelCount != _activeChannelCount) {
      _activeChannelCount = nextActiveChannelCount;
    }

    // 自动跟随最新数据（仅跟随模式开启时）
    if (_isPlotting && _followEnabled && _dataPoints.length > 1) {
      final lastIndex = _dataPoints.last.index;
      // 最新点在 3/4 宽度处
      final range = viewport.xRange;
      viewport = viewport.copyWith(
        xMin: (lastIndex - range * 0.75).toDouble(),
        xMax: (lastIndex + range * 0.25).toDouble(),
      );
    }

    // 数据接收：每包数据都处理，不丢失
    // UI 刷新降频：只控制重绘频率，不影响数据接收和统计
    _pendingNotifyCount++;
    final batchSize = _notifyBatchSize;

    // 每秒输出一次接收速率日志（调试用）
    if (_lastRateLogTime == null) {
      _lastRateLogTime = now;
      _lastRateLogIndex = _nextIndex;
      _lastRateLogBytes = _totalReceivedBytes;
    } else if (now.difference(_lastRateLogTime!).inMilliseconds >= 1000) {
      final elapsedMs = now.difference(_lastRateLogTime!).inMilliseconds;
      final receivedPoints = _nextIndex - _lastRateLogIndex;
      final receivedBytes = _totalReceivedBytes - _lastRateLogBytes;
      final rate = receivedPoints * 1000.0 / elapsedMs;
      AppLogger().info(
        '接收统计: ${rate.toStringAsFixed(1)} 点/s | '
        '$_pendingNotifyCount 待刷新 | batch=$batchSize | '
        '${receivedBytes}B/s | 缓冲区=${_dataPoints.length}点',
        category: 'PLOT',
      );
      _lastRateLogTime = now;
      _lastRateLogIndex = _nextIndex;
      _lastRateLogBytes = _totalReceivedBytes;
    }

    if (_pendingNotifyCount >= batchSize) {
      _pendingNotifyCount = 0;
      _notifyTimer?.cancel();
      _notifyTimer = null;
      Future.microtask(() => notifyListeners());
    } else if (_notifyTimer == null) {
      // fallback timer：确保即使数据流中断也能刷新UI
      final delayMs = (1000 / _refreshFps).round();
      _notifyTimer = Timer(Duration(milliseconds: delayMs), () {
        _pendingNotifyCount = 0;
        _notifyTimer = null;
        Future.microtask(() => notifyListeners());
      });
    }
  }

  bool get _isViewingTail {
    if (_dataPoints.isEmpty) return true;
    return _visibleEndIndex >= _historyPointCount - 1;
  }

  int get _historyPointCount {
    if (_parserType == ParserType.zobow) return _zobowRawFrames.packetCount;
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return _fixedFrameRawFrames.packetCount;
    }
    return _parsedHistory.length;
  }

  void _trimVisibleWindowToLimit() {
    if (_dataPoints.length <= _maxVisiblePoints) {
      _visibleStartIndex = _dataPoints.isEmpty ? 0 : _dataPoints.first.index;
      return;
    }

    final removeCount = _dataPoints.length - _maxVisiblePoints;
    _dataPoints.removeRange(0, removeCount);
    _visibleStartIndex = _dataPoints.first.index;
  }

  void _loadZobowWindowForViewport({bool force = false}) {
    if (_parserType != ParserType.zobow || _zobowRawFrames.isEmpty) return;

    var start =
        viewport.xMin.floor().clamp(0, _zobowRawFrames.packetCount).toInt();
    var end =
        viewport.xMax.ceil().clamp(start, _zobowRawFrames.packetCount).toInt();
    if (end - start > _maxVisiblePoints) {
      end = start + _maxVisiblePoints;
      viewport = viewport.copyWith(
        xMin: start.toDouble(),
        xMax: end.toDouble(),
      );
    }

    final currentStart = _visibleStartIndex;
    final currentEnd = _visibleEndIndex;
    if (!force && start >= currentStart && end <= currentEnd) return;

    _rebuildZobowWindow(start, end - start);
  }

  void _loadWindowForViewport({bool force = false}) {
    switch (_parserType) {
      case ParserType.zobow:
        _loadZobowWindowForViewport(force: force);
        break;
      case ParserType.fireWater:
      case ParserType.justFloat:
        _loadParsedWindowForViewport(force: force);
        break;
      case ParserType.fixedFrame:
        if (_fixedFrameRawFrames.isNotEmpty) {
          _loadFixedFrameWindowForViewport(force: force);
        } else {
          _loadParsedWindowForViewport(force: force);
        }
        break;
    }
  }

  void _loadFixedFrameWindowForViewport({bool force = false}) {
    if (_fixedFrameRawFrames.isEmpty) return;

    var start =
        viewport.xMin
            .floor()
            .clamp(0, _fixedFrameRawFrames.packetCount)
            .toInt();
    var end =
        viewport.xMax
            .ceil()
            .clamp(start, _fixedFrameRawFrames.packetCount)
            .toInt();
    if (end - start > _maxVisiblePoints) {
      end = start + _maxVisiblePoints;
      viewport = viewport.copyWith(
        xMin: start.toDouble(),
        xMax: end.toDouble(),
      );
    }

    final currentStart = _visibleStartIndex;
    final currentEnd = _visibleEndIndex;
    if (!force && start >= currentStart && end <= currentEnd) return;

    _rebuildFixedFrameWindow(start, end - start);
  }

  void _loadParsedWindowForViewport({bool force = false}) {
    if (_parsedHistory.isEmpty) return;

    var start = viewport.xMin.floor().clamp(0, _parsedHistory.length).toInt();
    var end = viewport.xMax.ceil().clamp(start, _parsedHistory.length).toInt();
    if (end - start > _maxVisiblePoints) {
      end = start + _maxVisiblePoints;
      viewport = viewport.copyWith(
        xMin: start.toDouble(),
        xMax: end.toDouble(),
      );
    }

    final currentStart = _visibleStartIndex;
    final currentEnd = _visibleEndIndex;
    if (!force && start >= currentStart && end <= currentEnd) return;

    _rebuildParsedWindow(start, end - start);
  }

  void _loadTailWindow() {
    switch (_parserType) {
      case ParserType.zobow:
        _loadZobowTailWindow();
        break;
      case ParserType.fireWater:
      case ParserType.justFloat:
        final count = _parsedHistory.length.clamp(0, _maxVisiblePoints).toInt();
        final start = _parsedHistory.length - count;
        _rebuildParsedWindow(start, count);
        break;
      case ParserType.fixedFrame:
        if (_fixedFrameRawFrames.isNotEmpty) {
          _loadFixedFrameTailWindow();
        } else {
          final count =
              _parsedHistory.length.clamp(0, _maxVisiblePoints).toInt();
          final start = _parsedHistory.length - count;
          _rebuildParsedWindow(start, count);
        }
        break;
    }
  }

  void _rebuildParsedWindow(int start, int count) {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;
    if (count <= 0) return;

    for (int i = 0; i < count; i++) {
      final pointIndex = start + i;
      _dataPoints.add(
        PlotDataPoint(
          index: pointIndex,
          timestamp: pointIndex.toDouble(),
          values: _parsedHistory.valuesAt(pointIndex),
        ),
      );
    }
  }

  void _loadZobowTailWindow() {
    if (_parserType != ParserType.zobow || _zobowRawFrames.isEmpty) return;
    final count =
        _zobowRawFrames.packetCount.clamp(0, _maxVisiblePoints).toInt();
    final start = _zobowRawFrames.packetCount - count;
    _rebuildZobowWindow(start, count);
  }

  void _rebuildZobowWindow(int start, int count) {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;

    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _zobowRawFrames.readPacket(packetIndex);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: ZobowParser.decodeFrameValues(frame, _parserConfig),
        ),
      );
    }
  }

  Future<void> _rebuildZobowWindowAsync(
    int start,
    int count, {
    PlotImportProgressCallback? onProgress,
  }) async {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;

    const batchSize = 4096;
    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _zobowRawFrames.readPacket(packetIndex);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: ZobowParser.decodeFrameValues(frame, _parserConfig),
        ),
      );
      if ((i + 1) % batchSize == 0 || i + 1 == count) {
        onProgress?.call(
          PlotImportProgress(stage: '刷新绘图窗口', current: i + 1, total: count),
        );
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// 根据当前解析器类型创建对应的解析器实例
  IDataParser _createParser() {
    switch (_parserType) {
      case ParserType.fireWater:
        return FireWaterParser(_parserConfig);
      case ParserType.fixedFrame:
        return FixedFrameParser(_parserConfig);
      case ParserType.zobow:
        return ZobowParser(_parserConfig);
      case ParserType.justFloat:
        return JustFloatParser(_parserConfig);
    }
  }

  // ========== 协议启动初始化数据发送（预留接口，供后续协议扩展） ==========

  /// 协议启动时发送初始化数据
  ///
  /// 某些协议（如众邦电控）需要在开始绘图前发送配置数据。
  /// 返回是否发送成功，发送失败会阻止本次绘图启动。
  bool _sendProtocolInitData() {
    switch (_parserType) {
      case ParserType.zobow:
        return _sendJackFourChannelInitData();
      default:
        return true; // 其他协议无需发送
    }
  }

  /// 发送 众邦电控初始化数据
  ///
  /// 格式：18字节
  /// 前16字节为4个通道号（小端序uint32），后2字节为前16字节的CRC16/MODBUS（小端序）
  bool _sendJackFourChannelInitData() {
    // 串口未连接时不发送初始化数据
    if (!serialService.isConnected) {
      AppLogger().debug('串口未连接，跳过众邦电控初始化数据发送', category: 'PLOT');
      return false;
    }

    try {
      final bytes = buildZobowInitFrame(
        _parserConfig.zobowChannelIds
            .take(_parserConfig.zobowChannelCount)
            .toList(),
      );
      serialService.send(bytes);

      AppLogger().info('众邦电控初始化数据已发送: ${_bytesToHex(bytes)}', category: 'PLOT');
      return true;
    } catch (e) {
      AppLogger().error('众邦电控初始化数据发送失败: $e', category: 'PLOT');
      return false;
    }
  }

  /// 构造众邦电控初始化帧。
  ///
  /// 通道号使用 uint32 little-endian 编码，CRC 覆盖全部通道号字节。
  static Uint8List buildZobowInitFrame(List<int> channelIds) {
    if (channelIds.length != 4 && channelIds.length != 8) {
      throw ArgumentError.value(
        channelIds,
        'channelIds',
        'must contain 4 or 8 ids',
      );
    }

    final dataLength = channelIds.length * 4;
    final bytes = Uint8List(dataLength + 2);
    final buffer = ByteData.sublistView(bytes);
    for (int i = 0; i < channelIds.length; i++) {
      buffer.setUint32(i * 4, channelIds[i] & 0xFFFFFFFF, Endian.little);
    }

    final dataBytes = Uint8List.sublistView(bytes, 0, dataLength);
    final crc = calculateCrc(dataBytes, crc16Polys['CRC-16/MODBUS']!);
    bytes[dataLength] = crc & 0xFF;
    bytes[dataLength + 1] = (crc >> 8) & 0xFF;
    return bytes;
  }

  void _resetZobowRawFrameBuffer() {
    _zobowRawFrames = FixedPacketByteBuffer(
      packetSize: ZobowParser.frameLengthForConfig(_parserConfig),
    );
  }

  /// 字节转16进制字符串（用于日志）
  void _resetFixedFrameRawFrameBuffer() {
    _fixedFrameRawFrames = FixedPacketByteBuffer(
      packetSize: _parserConfig.totalFrameLength,
    );
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  // ========== 视口控制（带历史记录） ==========
  /// 保存当前视口到历史记录栈（用于撤回）
  void _saveViewport() {
    _viewportHistory.add(viewport.copy());
    if (_viewportHistory.length > _maxHistory) {
      _viewportHistory.removeAt(0);
    }
  }

  /// 更新视口并保存到历史记录
  ///
  /// [fromDrag] 为 true 时表示来自用户拖动交互，跳过配置保存和
  /// 历史记录，避免频繁文件写入导致的卡顿。拖动结束后再统一保存。
  void updateViewport(PlotViewport newViewport, {bool fromDrag = false}) {
    // 保存当前的偏移通道数量，避免 copy() 丢失
    final offsetChannelCount = viewport.offsetChannelCount;
    if (!fromDrag) {
      _saveViewport();
    }
    viewport = _limitXRange(newViewport).copy();
    viewport.setOffsetChannelCount(offsetChannelCount);
    if (!fromDrag) {
      _loadWindowForViewport();
    }
    if (!fromDrag) {
      _saveSettings();
      AppLogger().trace(
        'updateViewport: xMin=${viewport.xMin.toStringAsFixed(1)} | fromDrag=$fromDrag',
        category: 'PLOT',
      );
    }
    if (fromDrag) {
      // 拖动时同步通知，避免微任务堆积
      notifyListeners();
    } else {
      Future.microtask(() => notifyListeners());
    }
  }

  /// 拖动结束后保存视口配置
  ///
  /// 在 PlotGestureHandler._handlePointerUp 中调用，将拖动期间的
  /// 最终视口保存到配置和历史记录。
  void saveDragViewport() {
    _saveViewport();
    _loadWindowForViewport();
    _saveSettings();
    AppLogger().trace(
      'saveDragViewport: xMin=${viewport.xMin.toStringAsFixed(1)}',
      category: 'PLOT',
    );
    Future.microtask(() => notifyListeners());
  }

  /// 重置视口到默认值并保存历史记录
  void resetViewport() {
    _saveViewport();
    viewport = viewport.reset();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 撤回上次缩放
  void undoZoom() {
    if (_viewportHistory.isEmpty) return;
    final previous = _viewportHistory.removeLast();
    viewport = _limitXRange(previous).copy();
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  PlotViewport _limitXRange(PlotViewport candidate) {
    if (candidate.xRange <= _maxVisiblePoints) return candidate;
    return candidate.copyWith(xMax: candidate.xMin + _maxVisiblePoints);
  }

  /// X 轴放大
  void zoomXIn() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = _limitXRange(viewport.zoomX(0.8, centerX));
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X 轴缩小
  void zoomXOut() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = _limitXRange(viewport.zoomX(1.25, centerX));
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴放大
  void zoomYIn() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(0.8, centerY);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴缩小
  void zoomYOut() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(1.25, centerY);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置框选放大开关
  void setBoxZoomEnabled(bool value) {
    _boxZoomEnabled = value;
    Future.microtask(() => notifyListeners());
  }

  /// Y轴自适应：保持X轴不变，调整Y轴使屏幕内所有数据可见
  void fitYAxis() {
    if (_historyPointCount > 0) {
      _loadWindowForViewport(force: true);
    }
    if (_dataPoints.isEmpty) return;
    final visiblePoints =
        _dataPoints.where((p) {
          return p.index >= viewport.xMin && p.index <= viewport.xMax;
        }).toList();
    if (visiblePoints.isEmpty) return;

    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final point in visiblePoints) {
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        if (channels[i].offsetEnabled) continue;
        final v = point.values[i] * channels[i].yScale + channels[i].yOffset;
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }

    _saveViewport();
    var changed = false;
    if (minY != double.infinity && maxY != double.negativeInfinity) {
      if (minY == maxY) {
        showStatusMessage('Y轴数据范围为0，跳过默认Y轴自适应');
      } else {
        final padding = (maxY - minY) * 0.1;
        viewport = viewport.copyWith(
          yMin: minY - padding,
          yMax: maxY + padding,
        );
        changed = true;
      }
    }

    changed = _fitOffsetChannelsY(visiblePoints) || changed;
    if (!changed) return;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X轴自适应：保持Y轴不变，调整X轴使所有数据可见
  void fitXAxis() {
    if (_nextIndex <= 3) {
      showStatusMessage('X轴数据点过少，跳过自适应');
      return;
    }
    final maxX = _nextIndex.toDouble();
    final minX = (maxX - _maxVisiblePoints).clamp(0, maxX).toDouble();

    _saveViewport();
    viewport = viewport.copyWith(xMin: minX, xMax: maxX);
    _loadTailWindow();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void _loadFixedFrameTailWindow() {
    if (_fixedFrameRawFrames.isEmpty) return;
    final count =
        _fixedFrameRawFrames.packetCount.clamp(0, _maxVisiblePoints).toInt();
    final start = _fixedFrameRawFrames.packetCount - count;
    _rebuildFixedFrameWindow(start, count);
  }

  void _rebuildFixedFrameWindow(int start, int count) {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;

    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _fixedFrameRawFrames.readPacket(packetIndex);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: FixedFrameParser.decodeFrameValues(frame, _parserConfig),
        ),
      );
    }
  }

  /// 全自适应：调整X和Y使所有可见通道数据完全显示
  void fitAll() {
    if (_nextIndex <= 3) {
      showStatusMessage('X轴数据点过少，跳过自适应');
      return;
    }

    _loadTailWindow();

    // X范围
    final maxX = _nextIndex.toDouble();
    final minX = (maxX - _maxVisiblePoints).clamp(0, maxX).toDouble();

    // Y范围（只计算可见通道）
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final point in _dataPoints) {
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        if (channels[i].offsetEnabled) continue;
        final v = point.values[i] * channels[i].yScale + channels[i].yOffset;
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }

    _saveViewport();
    if (minY != double.infinity && maxY != double.negativeInfinity) {
      if (minY == maxY) {
        viewport = viewport.copyWith(xMin: minX, xMax: maxX);
        showStatusMessage('默认Y轴数据范围为0，仅自适应X轴');
      }
      if (minY != maxY) {
        final padding = (maxY - minY) * 0.1;
        viewport = viewport.copyWith(
          xMin: minX,
          xMax: maxX,
          yMin: minY - padding,
          yMax: maxY + padding,
        );
      }
    } else {
      viewport = viewport.copyWith(xMin: minX, xMax: maxX);
    }
    _fitOffsetChannelsY(_dataPoints);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  bool _fitOffsetChannelsY(Iterable<PlotDataPoint> points) {
    final valuesByChannel = <int, (double, double)>{};
    final activeLimit =
        _activeChannelCount > 0 ? _activeChannelCount : channels.length;
    for (final point in points) {
      for (
        int i = 0;
        i < point.values.length && i < channels.length && i < activeLimit;
        i++
      ) {
        final channel = channels[i];
        if (!channel.visible || !channel.offsetEnabled) continue;
        final value = point.values[i];
        final current = valuesByChannel[i];
        if (current == null) {
          valuesByChannel[i] = (value, value);
        } else {
          valuesByChannel[i] = (
            value < current.$1 ? value : current.$1,
            value > current.$2 ? value : current.$2,
          );
        }
      }
    }

    var changed = false;
    final targetMin = viewport.yMin + viewport.yRange * 0.1;
    final targetMax = viewport.yMax - viewport.yRange * 0.1;
    final targetRange = targetMax - targetMin;
    if (targetRange <= 0) return false;

    for (final entry in valuesByChannel.entries) {
      final minY = entry.value.$1;
      final maxY = entry.value.$2;

      final channel = channels[entry.key];
      if (minY == maxY) {
        channel.yScale = 1.0;
        channel.yOffset = (targetMin + targetMax) / 2 - minY;
      } else {
        channel.yScale = targetRange / (maxY - minY);
        channel.yOffset = targetMin - minY * channel.yScale;
      }
      changed = true;
    }

    return changed;
  }

  /// 设置跟随开关
  void setFollowEnabled(bool value) {
    _followEnabled = value;
    if (value && _historyPointCount > 0) {
      final maxX = _nextIndex.toDouble();
      final minX = (maxX - _maxVisiblePoints).clamp(0, maxX).toDouble();
      viewport = viewport.copyWith(xMin: minX, xMax: maxX);
      _loadTailWindow();
    }
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置单垂直光标开关
  ///
  /// 光标开关为临时功能，不保存到配置。
  void setVCursorEnabled(bool value) {
    _vCursorEnabled = value;
    _cursor = null;
    Future.microtask(() => notifyListeners());
  }

  // ========== 通道控制 ==========
  /// 设置通道可见性
  void setChannelVisible(int index, bool visible) {
    if (index < 0 || index >= channels.length) return;
    channels[index].visible = visible;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道颜色
  void setChannelColor(int index, Color color) {
    if (index < 0 || index >= channels.length) return;
    channels[index].color = color;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道是否显示连线
  void setChannelShowLine(int index, bool show) {
    if (index < 0 || index >= channels.length) return;
    channels[index].showLine = show;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道点半径
  void setChannelPointSize(int index, double size) {
    if (index < 0 || index >= channels.length) return;
    channels[index].pointSize = size.clamp(0.5, 12.0);
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道线宽
  void setChannelLineWidth(int index, double width) {
    if (index < 0 || index >= channels.length) return;
    channels[index].lineWidth = width.clamp(0.5, 8.0);
    Future.microtask(() => notifyListeners());
  }

  /// 一键设置所有通道的显示状态
  void setAllChannelsVisible(bool visible) {
    for (final ch in channels) {
      ch.visible = visible;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道别名
  void setChannelAlias(int index, String alias) {
    if (index < 0 || index >= channels.length) return;
    channels[index].alias = alias;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴偏移
  void setChannelYOffset(int index, double offset) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yOffset = offset;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道偏移功能开关
  void setChannelOffsetEnabled(int index, bool enabled) {
    if (index < 0 || index >= channels.length) return;
    channels[index].offsetEnabled = enabled;
    if (!enabled) {
      // 关闭偏置时，偏移和缩放都归位
      channels[index].yOffset = 0;
      channels[index].yScale = 1.0;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴缩放
  void setChannelYScale(int index, double scale) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yScale = scale;
    Future.microtask(() => notifyListeners());
  }

  /// 缩放通道 Y 轴（滚轮缩放，按比例调整）
  void zoomChannelYScale(int index, double scaleDelta) {
    if (index < 0 || index >= channels.length) return;
    final newScale = (channels[index].yScale * scaleDelta).clamp(0.001, 1000.0);
    channels[index].yScale = newScale;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 众邦电控的通道号
  void setZobowChannelId(int index, int channelId) {
    if (index < 0 || index >= _parserConfig.zobowChannelCount) return;
    _parserConfig.zobowChannelIds[index] = channelId & 0xFFFFFFFF;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 众邦电控的通道数据类型，并重新解释已缓存的原始帧。
  Future<bool> setZobowChannelType(
    int index,
    DataType type, {
    PlotImportProgressCallback? onProgress,
  }) async {
    if (index < 0 || index >= _parserConfig.zobowChannelCount) return false;
    if (type != DataType.uint16 && type != DataType.int16) return false;
    if (_isPlotting || _isStopping) {
      showStatusMessage('请停止绘图后再修改众邦通道数据类型');
      return false;
    }
    if (index < channels.length) {
      channels[index].dataType = type;
    }
    if (_parserConfig.zobowChannelTypes[index] == type) return true;

    _parserConfig.zobowChannelTypes[index] = type;

    final total = _zobowRawFrames.packetCount;
    if (total > 0) {
      final visibleStart = _visibleStartIndex;
      final visibleCount = _dataPoints.length;
      final stopwatch = Stopwatch()..start();
      _lodIndex.clear();

      const batchSize = 4096;
      for (int packetIndex = 0; packetIndex < total; packetIndex++) {
        final frame = _zobowRawFrames.readPacket(packetIndex);
        _lodIndex.add(
          packetIndex,
          ZobowParser.decodeFrameValues(frame, _parserConfig),
        );
        if ((packetIndex + 1) % batchSize == 0 || packetIndex + 1 == total) {
          onProgress?.call(
            PlotImportProgress(
              stage: '重新解释众邦数据',
              current: packetIndex + 1,
              total: total,
            ),
          );
          await Future<void>.delayed(Duration.zero);
        }
      }

      await _rebuildZobowWindowAsync(
        visibleStart,
        visibleCount,
        onProgress: onProgress,
      );
      AppLogger().info(
        '众邦通道类型转换完成: $total 帧, ${stopwatch.elapsedMilliseconds}ms',
        category: 'PLOT',
      );
    }

    Future.microtask(() => notifyListeners());
    return true;
  }

  // ========== 显示控制 ==========
  /// 设置网格显示开关
  void setShowGrid(bool show) {
    _showGrid = show;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 UI 刷新帧率（30~60 fps）
  void setRefreshFps(int fps) {
    _refreshFps = fps.clamp(30, 60);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setSnapHighlightEnabled(bool value) {
    if (_snapHighlightEnabled == value) return;
    _snapHighlightEnabled = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setSnapHighlightDiameter(double value) {
    final next = value.clamp(6.0, 12.0).toDouble();
    if ((_snapHighlightDiameter - next).abs() < 1e-9) return;
    _snapHighlightDiameter = next;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置绘图界面字体大小偏移（-3~+6，基于默认字号）
  void setPlotFontSizeDelta(int delta) {
    _plotFontSizeDelta = delta.clamp(-3, 6);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置绘图窗口点数上限（1000000~40000000）
  void setMaxVisiblePoints(int points) {
    final next = points.clamp(minVisiblePoints, maxVisiblePointsLimit).toInt();
    if (next == _maxVisiblePoints) return;
    _maxVisiblePoints = next;

    if (_historyPointCount > 0) {
      viewport = _limitXRange(viewport).copy();
      _loadWindowForViewport(force: true);
    }

    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置网格密度（sparse/normal/dense）
  void setGridDensity(String density) {
    const valid = {'sparse', 'normal', 'dense'};
    if (valid.contains(density)) {
      _gridDensity = density;
      _saveSettings();
      Future.microtask(() => notifyListeners());
    }
  }

  /// 切换 X-X 测量开关
  ///
  /// 开启时自动在视口中心初始化两条测量线，间隔为 X 范围的 1/4。
  void toggleXMeasurement() {
    _xMeasurementEnabled = !_xMeasurementEnabled;
    if (_xMeasurementEnabled && _xCursor1 == null) {
      // 自动初始化两条线，间隔为X范围的1/4
      final range = viewport.xRange;
      final center = viewport.xMin + range / 2;
      _xCursor1 = _snapXToNearestVisiblePoint(center - range / 8);
      _xCursor2 = _snapXToNearestVisiblePoint(center + range / 8);
    }
    if (!_xMeasurementEnabled) {
      _xCursor1 = null;
      _xCursor2 = null;
      _xCursor1SnapHighlights = const [];
      _xCursor2SnapHighlights = const [];
      // 如果垂直光标也关闭，清除 cursor
      if (!_vCursorEnabled) _cursor = null;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换 Y-Y 测量开关
  ///
  /// 开启时自动在视口中心初始化两条测量线，Y2 在上（值更大）。
  void toggleYMeasurement() {
    _yMeasurementEnabled = !_yMeasurementEnabled;
    if (_yMeasurementEnabled && _yCursor1 == null) {
      // 自动初始化两条线，Y2在上（值更大），间隔为Y范围的1/4
      final range = viewport.yRange;
      final center = viewport.yMin + range / 2;
      _yCursor1 = center - range / 8; // 下方（值小）
      _yCursor2 = center + range / 8; // 上方（值大）
    }
    if (!_yMeasurementEnabled) {
      _yCursor1 = null;
      _yCursor2 = null;
      _yCursor1SnapHighlights = const [];
      _yCursor2SnapHighlights = const [];
      // 如果垂直光标也关闭，清除 cursor
      if (!_vCursorEnabled) _cursor = null;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换统计测量开关
  ///
  /// 开启时默认统计整个波形（当前视口范围）。
  void toggleStats() {
    _statsEnabled = !_statsEnabled;
    if (_statsEnabled && _statsX1 == null) {
      // 默认统计整个波形，范围设为当前视口
      _statsX1 = viewport.xMin;
      _statsX2 = viewport.xMax;
    }
    if (!_statsEnabled) {
      _statsX1 = null;
      _statsX2 = null;
      _statsRangeEnabled = false;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换统计范围开关
  ///
  /// 开启时 S1/S2 初始位置在视口 1/4 和 3/4 处；
  /// 关闭时恢复为整个视口范围。
  void toggleStatsRange() {
    if (!_statsEnabled) return;
    _statsRangeEnabled = !_statsRangeEnabled;
    if (_statsRangeEnabled) {
      // S1/S2 初始位置在 1/4 和 3/4 处
      final range = viewport.xRange;
      _statsX1 = viewport.xMin + range * 0.25;
      _statsX2 = viewport.xMin + range * 0.75;
    } else {
      // 关闭范围时恢复为整个视口
      _statsX1 = viewport.xMin;
      _statsX2 = viewport.xMax;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围左边界
  void setStatsX1(double x) {
    _statsX1 = x;
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围右边界
  void setStatsX2(double x) {
    _statsX2 = x;
    Future.microtask(() => notifyListeners());
  }

  /// 更新垂直光标（跟随鼠标模式）
  ///
  /// - X 值吸附到最近的整数（数据点索引都是整数）
  /// - 使用二分查找精确匹配数据点，避免线性扫描
  /// - 未绘制到数据点的区域设置 hasData=false，tooltip 不显示
  void updateFollowCursor(double x, double y, Offset screenPosition) {
    _cursor = _buildCursorAtX(x, y: y, screenPosition: screenPosition);
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  /// 更新光标状态（由外部直接设置）
  void updateCursor(CursorState? cursor) {
    _cursor = cursor;
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  void addObservation() {
    final cursorX = _cursor?.x;
    final sourceX =
        cursorX != null && viewport.isVisibleX(cursorX)
            ? cursorX
            : viewport.xMin + viewport.xRange / 2;
    _observations.add(_buildCursorAtX(sourceX));
    scheduleMicrotask(notifyListeners);
  }

  void updateObservation(int index, double x) {
    if (index < 0 || index >= _observations.length) return;
    _observations[index] = _buildCursorAtX(x);
    scheduleMicrotask(notifyListeners);
  }

  void removeObservation(int index) {
    if (index < 0 || index >= _observations.length) return;
    _observations.removeAt(index);
    scheduleMicrotask(notifyListeners);
  }

  CursorState _buildCursorAtX(double x, {double? y, Offset? screenPosition}) {
    final point = _nearestVisiblePointByX(x);
    final snappedX =
        point?.index.toDouble() ??
        x.clamp(viewport.xMin, viewport.xMax).toDouble();
    final channelValues =
        point == null ? null : List<double>.from(point.values);
    final hasData = point != null;

    return CursorState(
      x: snappedX,
      y: y,
      screenPosition: screenPosition,
      channelValues: channelValues,
      hasData: hasData,
    );
  }

  PlotDataPoint? _nearestVisiblePointByX(double x) {
    if (_dataPoints.isEmpty) return null;
    final range = _dataPointRangeByX(viewport.xMin, viewport.xMax);
    if (range == null) return null;

    int left = range.start;
    int right = range.end - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final midX = _dataPoints[mid].index.toDouble();
      if (midX < x) {
        left = mid + 1;
      } else if (midX > x) {
        right = mid - 1;
      } else {
        return _dataPoints[mid];
      }
    }

    final candidates = <int>[
      if (right >= range.start && right < range.end) right,
      if (left >= range.start && left < range.end) left,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final da = (_dataPoints[a].index.toDouble() - x).abs();
      final db = (_dataPoints[b].index.toDouble() - x).abs();
      return da.compareTo(db);
    });
    return _dataPoints[candidates.first];
  }

  double _snapXToNearestVisiblePoint(double x) {
    return _nearestVisiblePointByX(x)?.index.toDouble() ??
        x.clamp(viewport.xMin, viewport.xMax).toDouble();
  }

  // ========== x-x / y-y 光标控制 ==========
  /// 设置 X1 光标位置（拖动时使用）
  ///
  /// 同时保留 xCursor2 和 yCursor2，避免拖动时覆盖另一组测量线。
  List<SnapHighlightPoint> _snapHighlightsForX(double x, Color color) {
    final point = _nearestVisiblePointByX(x);
    if (point == null) return const [];
    final highlights = <SnapHighlightPoint>[];
    for (int i = 0; i < point.values.length && i < channels.length; i++) {
      final channel = channels[i];
      if (!channel.visible) continue;
      highlights.add(
        SnapHighlightPoint(
          x: point.index.toDouble(),
          y: point.values[i] * channel.yScale + channel.yOffset,
          color: color,
        ),
      );
    }
    return highlights;
  }

  List<SnapHighlightPoint> _snapHighlightForY(double y, Color color) {
    if (_dataPoints.isEmpty) return const [];
    const maxScanPoints = 4096;
    final range = _dataPointRangeByX(viewport.xMin, viewport.xMax);
    if (range == null) return const [];
    final visibleCount = range.end - range.start;
    final step = (visibleCount / maxScanPoints).ceil().clamp(1, visibleCount);

    SnapHighlightPoint? best;
    var bestDistance = double.infinity;
    void visit(PlotDataPoint point) {
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        final channel = channels[i];
        if (!channel.visible) continue;
        final pointY = point.values[i] * channel.yScale + channel.yOffset;
        final distance = (pointY - y).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = SnapHighlightPoint(
            x: point.index.toDouble(),
            y: pointY,
            color: color,
          );
        }
      }
    }

    for (int i = range.start; i < range.end; i += step) {
      visit(_dataPoints[i]);
    }
    if (step > 1) visit(_dataPoints[range.end - 1]);
    return best == null ? const [] : [best!];
  }

  List<SnapHighlightPoint> _observationSnapHighlights() {
    final highlights = <SnapHighlightPoint>[];
    for (final observation in _observations) {
      final values = observation.channelValues;
      if (!observation.hasData || values == null) continue;
      for (int i = 0; i < values.length && i < channels.length; i++) {
        final channel = channels[i];
        if (!channel.visible) continue;
        highlights.add(
          SnapHighlightPoint(
            x: observation.x,
            y: values[i] * channel.yScale + channel.yOffset,
            color: Colors.amber,
          ),
        );
      }
    }
    return highlights;
  }

  void _clearSnapHighlights() {
    _xCursor1SnapHighlights = const [];
    _xCursor2SnapHighlights = const [];
    _yCursor1SnapHighlights = const [];
    _yCursor2SnapHighlights = const [];
  }

  void setXCursor1(double x) {
    _xCursor1 = _snapXToNearestVisiblePoint(x);
    _xCursor1SnapHighlights = _snapHighlightsForX(_xCursor1!, Colors.cyan);
    Future.microtask(() => notifyListeners());
  }

  /// 设置 X2 光标位置（拖动时使用）
  void setXCursor2(double x) {
    _xCursor2 = _snapXToNearestVisiblePoint(x);
    _xCursor2SnapHighlights = _snapHighlightsForX(_xCursor2!, Colors.yellow);
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y1 光标位置（拖动时使用）
  void setYCursor1(double y) {
    _yCursor1 = y;
    _yCursor1SnapHighlights = _snapHighlightForY(y, Colors.cyan);
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y2 光标位置（拖动时使用）
  void setYCursor2(double y) {
    _yCursor2 = y;
    _yCursor2SnapHighlights = _snapHighlightForY(y, Colors.yellow);
    Future.microtask(() => notifyListeners());
  }

  /// 清除所有光标和测量线
  void clearCursors() {
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _clearSnapHighlights();
    _cursor = null;
    Future.microtask(() => notifyListeners());
  }

  /// 测量信息文本，显示 X1/X2/Y1/Y2 值和 delta
  String? get measurementText {
    final buffer = StringBuffer();
    bool hasData = false;

    if (_xMeasurementEnabled && _xCursor1 != null && _xCursor2 != null) {
      final dx = _xCursor2! - _xCursor1!;
      buffer.writeln('X1 = ${_formatDisplayNumber(_xCursor1!)}');
      buffer.writeln('X2 = ${_formatDisplayNumber(_xCursor2!)}');
      buffer.writeln('ΔX = ${_formatDisplayNumber(dx)}');
      hasData = true;
    }

    if (_yMeasurementEnabled && _yCursor1 != null && _yCursor2 != null) {
      final dy = _yCursor2! - _yCursor1!;
      if (hasData) buffer.writeln('---');
      buffer.writeln('Y1 = ${_formatDisplayNumber(_yCursor1!)}');
      buffer.writeln('Y2 = ${_formatDisplayNumber(_yCursor2!)}');
      buffer.writeln('ΔY = ${_formatDisplayNumber(dy)}');
      hasData = true;
    }

    return hasData ? buffer.toString().trim() : null;
  }

  /// 统计测量信息文本，显示各通道最大值、最小值、平均值
  String? get statsText {
    if (!_statsEnabled || _dataPoints.isEmpty) return null;

    final xMin =
        _statsRangeEnabled && _statsX1 != null && _statsX2 != null
            ? (_statsX1! < _statsX2! ? _statsX1! : _statsX2!)
            : viewport.xMin;
    final xMax =
        _statsRangeEnabled && _statsX1 != null && _statsX2 != null
            ? (_statsX1! > _statsX2! ? _statsX1! : _statsX2!)
            : viewport.xMax;
    final visibleChannelKey =
        channels.map((channel) => channel.visible ? '1' : '0').join();
    final cacheKey =
        '$_dataRevision|$xMin|$xMax|$_statsRangeEnabled|$visibleChannelKey|$_activeChannelCount';
    if (_cachedStatsKey == cacheKey) return _cachedStatsText;

    final range = _dataPointRangeByX(xMin, xMax);
    if (range == null) {
      _cachedStatsKey = cacheKey;
      _cachedStatsText = null;
      return null;
    }

    final buffer = StringBuffer();
    bool hasVisibleChannel = false;
    final commonCount = range.end - range.start;

    if (commonCount == 0) return null;
    const exactStatsPointLimit = 100000;
    final approximate = commonCount > exactStatsPointLimit;
    final sampleStep =
        approximate
            ? (commonCount / exactStatsPointLimit).ceil().clamp(1, commonCount)
            : 1;
    final statPrefix = approximate ? '约' : '';

    for (int i = 0; i < channels.length; i++) {
      if (!channels[i].visible) continue;

      double? maxVal, minVal, sum;
      int count = 0;

      for (
        int pointIndex = range.start;
        pointIndex < range.end;
        pointIndex += sampleStep
      ) {
        final point = _dataPoints[pointIndex];
        if (i >= point.channelCount) continue;

        final val = point.values[i];
        maxVal = maxVal == null || val > maxVal ? val : maxVal;
        minVal = minVal == null || val < minVal ? val : minVal;
        sum = (sum ?? 0) + val;
        count++;
      }

      if (count == 0) continue;
      if (hasVisibleChannel) buffer.writeln('---');
      hasVisibleChannel = true;

      buffer.writeln('Ch$i:');
      buffer.writeln('  Max: $statPrefix${_formatDisplayNumber(maxVal!)}');
      buffer.writeln('  Min: $statPrefix${_formatDisplayNumber(minVal!)}');
      buffer.writeln('  Avg: $statPrefix${_formatDisplayNumber(sum! / count)}');
    }

    if (!hasVisibleChannel) {
      _cachedStatsKey = cacheKey;
      _cachedStatsText = null;
      return null;
    }

    // 统一显示 N 和 Range
    buffer.writeln('---');
    buffer.writeln('N: $commonCount');
    if (approximate) buffer.writeln('Mode: 约 $exactStatsPointLimit samples');
    final rangeStart = _dataPoints[range.start].index;
    final rangeEnd = _dataPoints[range.end - 1].index;
    buffer.writeln('Range: $rangeStart ~ $rangeEnd');

    _cachedStatsKey = cacheKey;
    _cachedStatsText = buffer.toString().trim();
    return _cachedStatsText;
  }

  String _formatDisplayNumber(double value) {
    if ((value - value.roundToDouble()).abs() < 1e-9) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(6)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  ({int start, int end})? _dataPointRangeByX(double xMin, double xMax) {
    if (_dataPoints.isEmpty) return null;

    int left = 0;
    int right = _dataPoints.length;
    while (left < right) {
      final mid = (left + right) ~/ 2;
      if (_dataPoints[mid].index < xMin) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    final start = left;

    left = start;
    right = _dataPoints.length;
    while (left < right) {
      final mid = (left + right) ~/ 2;
      if (_dataPoints[mid].index <= xMax) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    final end = left;

    if (start >= end) return null;
    return (start: start, end: end);
  }

  // ========== 导出 ==========
  /// 导出数据到 CSV 文件
  ///
  /// [selectedPath] 为 null 时，自动保存到可执行文件目录下的 exports 文件夹。
  /// 返回实际保存的文件路径，失败返回 null。
  Future<String?> exportToCsv(String? selectedPath) async {
    try {
      if (_nextIndex == 0) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }

      String path;
      if (selectedPath != null) {
        path = selectedPath;
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.csv';
      }
      final file = File(path);

      // 构建 CSV 内容
      final buffer = StringBuffer();

      // 表头: x,y1,y2,...
      final maxChannels = _exportChannelCount;
      buffer.writeln(
        '# vscope_plot_meta=${jsonEncode(_buildExportMetadata(maxChannels))}',
      );
      buffer.write('x');
      for (int i = 0; i < maxChannels; i++) {
        buffer.write(',y${i + 1}');
      }
      buffer.writeln();

      // 数据行。所有协议导出历史全量数据；Zobow 从原始帧按需解析。
      if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
        for (
          int packetIndex = 0;
          packetIndex < _zobowRawFrames.packetCount;
          packetIndex++
        ) {
          final values = ZobowParser.decodeFrameValues(
            _zobowRawFrames.readPacket(packetIndex),
            _parserConfig,
          );
          buffer.write(packetIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            buffer.write(values[i].toStringAsFixed(6));
          }
          buffer.writeln();
        }
      } else if (_parserType == ParserType.fixedFrame &&
          _fixedFrameRawFrames.isNotEmpty) {
        for (
          int packetIndex = 0;
          packetIndex < _fixedFrameRawFrames.packetCount;
          packetIndex++
        ) {
          final values = FixedFrameParser.decodeFrameValues(
            _fixedFrameRawFrames.readPacket(packetIndex),
            _parserConfig,
          );
          buffer.write(packetIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            if (i < values.length) {
              buffer.write(values[i].toStringAsFixed(6));
            }
          }
          buffer.writeln();
        }
      } else {
        for (
          int pointIndex = 0;
          pointIndex < _parsedHistory.length;
          pointIndex++
        ) {
          final values = _parsedHistory.valuesAt(pointIndex);
          buffer.write(pointIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            if (i < values.length) {
              buffer.write(values[i].toStringAsFixed(6));
            }
          }
          buffer.writeln();
        }
      }

      await file.writeAsString(buffer.toString());
      AppLogger().info('已导出 CSV: $path', category: 'PLOT');
      return path;
    } catch (e) {
      AppLogger().error('CSV 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  Future<String?> exportToBin(String? selectedPath) async {
    try {
      final points = _collectExportPoints();
      if (points.isEmpty) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }

      String path;
      if (selectedPath != null) {
        path = selectedPath;
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.bin';
      }

      final channelCount = _exportChannelCount;
      final payloadLength = points.length * (8 + channelCount * 8);
      final payload = ByteData(payloadLength);
      var offset = 0;
      for (final point in points) {
        payload.setFloat64(offset, point.timestamp, Endian.little);
        offset += 8;
        for (int i = 0; i < channelCount; i++) {
          final value = i < point.values.length ? point.values[i] : 0.0;
          payload.setFloat64(offset, value, Endian.little);
          offset += 8;
        }
      }

      final payloadBytes = payload.buffer.asUint8List();
      final metadataBytes = utf8.encode(
        jsonEncode(_buildExportMetadata(channelCount)),
      );
      final dataBlock =
          BytesBuilder(copy: false)
            ..add(metadataBytes)
            ..add(payloadBytes);
      final dataBlockBytes = dataBlock.takeBytes();
      final checksum = calculateCrc(dataBlockBytes, crc32Polys['CRC-32']!);
      final header = ByteData(28);
      const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
      for (int i = 0; i < magic.length; i++) {
        header.setUint8(i, magic[i]);
      }
      header.setUint16(8, 2, Endian.little);
      header.setUint16(10, channelCount, Endian.little);
      header.setUint32(12, points.length, Endian.little);
      header.setUint32(16, payloadLength, Endian.little);
      header.setUint32(20, checksum, Endian.little);
      header.setUint32(24, metadataBytes.length, Endian.little);

      final builder =
          BytesBuilder(copy: false)
            ..add(header.buffer.asUint8List())
            ..add(dataBlockBytes);
      await File(path).writeAsBytes(builder.takeBytes());
      AppLogger().info('已导出 BIN: $path', category: 'PLOT');
      return path;
    } catch (e) {
      AppLogger().error('BIN 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  int get _exportChannelCount {
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      return _parserConfig.zobowChannelCount;
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return _parserConfig.channelCount;
    }
    return _parsedHistory.maxChannelCount;
  }

  Map<String, dynamic> _buildExportMetadata(int channelCount) {
    final names = List<String>.generate(channelCount, (i) {
      if (i >= channels.length) return 'Ch$i';
      return channels[i].alias.isNotEmpty ? channels[i].alias : 'Ch$i';
    }, growable: false);
    final metadata = <String, dynamic>{'channelNames': names};
    if (_importedChannelAddresses != null) {
      metadata['channelAddresses'] = _importedChannelAddresses!
          .take(channelCount)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (_parserType == ParserType.zobow) {
      metadata['parserType'] = ParserType.zobow.name;
      metadata['zobowChannelIds'] = _parserConfig.zobowChannelIds
          .take(channelCount)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    return metadata;
  }

  List<PlotDataPoint> _collectExportPoints() {
    final points = <PlotDataPoint>[];
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      for (int i = 0; i < _zobowRawFrames.packetCount; i++) {
        points.add(
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: ZobowParser.decodeFrameValues(
              _zobowRawFrames.readPacket(i),
              _parserConfig,
            ),
          ),
        );
      }
      return points;
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      for (int i = 0; i < _fixedFrameRawFrames.packetCount; i++) {
        points.add(
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: FixedFrameParser.decodeFrameValues(
              _fixedFrameRawFrames.readPacket(i),
              _parserConfig,
            ),
          ),
        );
      }
      return points;
    }
    for (int i = 0; i < _parsedHistory.length; i++) {
      points.add(
        PlotDataPoint(
          index: i,
          timestamp: i.toDouble(),
          values: _parsedHistory.valuesAt(i),
        ),
      );
    }
    return points;
  }

  // ========== 导入 ==========
  static const int _importProgressBatchSize = 10000;

  Future<void> _reportImportProgress(
    PlotImportProgressCallback? onProgress,
    String stage,
    int current,
    int total, {
    String? detail,
  }) async {
    if (onProgress == null) {
      await Future<void>.delayed(Duration.zero);
      return;
    }

    onProgress.call(
      PlotImportProgress(
        stage: stage,
        current: current,
        total: total,
        detail: detail,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  /// 从 CSV 文件导入数据
  ///
  /// 支持格式：表头 x,y1,y2,...，最大16通道。
  /// 导入成功后会清空现有数据并替换，返回 null；失败返回错误信息。
  Future<String?> importFromCsv(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 CSV', 0, 0);
      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        return '文件为空';
      }
      await _reportImportProgress(
        onProgress,
        '读取 CSV',
        lines.length,
        lines.length,
      );

      final metadata = <String, dynamic>{};
      var headerLineIndex = 0;
      while (headerLineIndex < lines.length &&
          lines[headerLineIndex].trim().startsWith('#')) {
        final line = lines[headerLineIndex].trim();
        const prefix = '# vscope_plot_meta=';
        if (line.startsWith(prefix)) {
          final decoded = jsonDecode(line.substring(prefix.length));
          if (decoded is Map<String, dynamic>) {
            metadata.addAll(decoded);
          }
        }
        headerLineIndex++;
      }
      if (headerLineIndex >= lines.length) {
        return '缺少 CSV 表头';
      }

      // 解析表头
      final header = lines[headerLineIndex].trim();
      if (!header.toLowerCase().startsWith('x')) {
        return '表头格式错误，第一列应为 x';
      }

      final headerParts = header.split(',');
      final channelCount = headerParts.length - 1; // 减去 x 列
      if (channelCount < 1) {
        return '至少需要 1 个数据列';
      }
      if (channelCount > 16) {
        return '通道数超过限制（最大16通道）';
      }

      // 解析数据行
      final importedPoints = <PlotDataPoint>[];
      final dataLineCount = lines.length - headerLineIndex - 1;
      int index = 0;
      for (int i = headerLineIndex + 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final parts = line.split(',');
        if (parts.length < 2) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final xValue = double.tryParse(parts[0].trim());
        if (xValue == null) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final values = <double>[];
        for (int c = 1; c < parts.length && c <= channelCount; c++) {
          final v = double.tryParse(parts[c].trim());
          if (v != null) {
            values.add(v);
          } else {
            values.add(0);
          }
        }

        // 如果某行列数不足，补零
        while (values.length < channelCount) {
          values.add(0);
        }

        importedPoints.add(
          PlotDataPoint(index: index, timestamp: xValue, values: values),
        );
        index++;

        if (index % _importProgressBatchSize == 0) {
          await _reportImportProgress(
            onProgress,
            '解析 CSV',
            i - headerLineIndex,
            dataLineCount,
            detail: '$index 点',
          );
        }
      }

      if (importedPoints.isEmpty) {
        return '未找到有效数据行';
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: metadata,
        onProgress: onProgress,
      );

      AppLogger().info(
        'CSV 导入成功: $filePath, ${importedPoints.length} 点, $channelCount 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('CSV 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  Future<String?> importFromBin(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 BIN', 0, 0);
      final bytes = await file.readAsBytes();
      if (bytes.length < 24) {
        return 'BIN 文件头不完整';
      }
      await _reportImportProgress(
        onProgress,
        '读取 BIN',
        bytes.length,
        bytes.length,
        detail: '${bytes.length} 字节',
      );

      const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
      for (int i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) {
          return 'BIN 文件标识错误';
        }
      }

      final header = ByteData.sublistView(bytes, 0, 24);
      final version = header.getUint16(8, Endian.little);
      final channelCount = header.getUint16(10, Endian.little);
      final pointCount = header.getUint32(12, Endian.little);
      final payloadLength = header.getUint32(16, Endian.little);
      final expectedChecksum = header.getUint32(20, Endian.little);

      if (version != 1 && version != 2) return '不支持的 BIN 版本: $version';
      if (channelCount < 1 || channelCount > 16) return '通道数无效';
      final headerLength = version == 2 ? 28 : 24;
      if (bytes.length < headerLength) return 'BIN 文件头不完整';
      final metadataLength =
          version == 2
              ? ByteData.sublistView(bytes, 24, 28).getUint32(0, Endian.little)
              : 0;
      if (bytes.length != headerLength + metadataLength + payloadLength) {
        return 'BIN 文件长度不匹配';
      }

      final dataBlock = Uint8List.sublistView(bytes, headerLength);
      await _reportImportProgress(onProgress, '校验 BIN', 0, payloadLength);
      final actualChecksum = calculateCrc(dataBlock, crc32Polys['CRC-32']!);
      if (actualChecksum != expectedChecksum) {
        return 'BIN 校验失败';
      }
      await _reportImportProgress(
        onProgress,
        '校验 BIN',
        payloadLength,
        payloadLength,
      );

      final metadata = <String, dynamic>{};
      if (metadataLength > 0) {
        final decoded = jsonDecode(
          utf8.decode(Uint8List.sublistView(dataBlock, 0, metadataLength)),
        );
        if (decoded is Map<String, dynamic>) {
          metadata.addAll(decoded);
        }
      }

      final payload = Uint8List.sublistView(dataBlock, metadataLength);

      final rowLength = 8 + channelCount * 8;
      if (payloadLength != pointCount * rowLength) {
        return 'BIN 数据长度不匹配';
      }

      final data = ByteData.sublistView(payload);
      final importedPoints = <PlotDataPoint>[];
      var offset = 0;
      for (int i = 0; i < pointCount; i++) {
        final x = data.getFloat64(offset, Endian.little);
        offset += 8;
        final values = <double>[];
        for (int c = 0; c < channelCount; c++) {
          values.add(data.getFloat64(offset, Endian.little));
          offset += 8;
        }
        importedPoints.add(
          PlotDataPoint(index: i, timestamp: x, values: values),
        );
        if ((i + 1) % _importProgressBatchSize == 0) {
          await _reportImportProgress(
            onProgress,
            '解析 BIN',
            i + 1,
            pointCount,
            detail: '${i + 1} 点',
          );
        }
      }

      if (importedPoints.isEmpty) {
        return '未找到有效数据行';
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: metadata,
        onProgress: onProgress,
      );
      AppLogger().info(
        'BIN 导入成功: $filePath, ${importedPoints.length} 点, $channelCount 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('BIN 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  /// Import data exported by the legacy VisualScope application.
  ///
  /// The legacy format stores four independent little-endian int16 channel
  /// blocks. Its first 50,000 samples are a reserved history area and are not
  /// part of the user-visible capture.
  Future<String?> importFromLegacyDat(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 DAT', 0, 0);
      final bytes = await file.readAsBytes();
      const channelCount = 4;
      const reservedPointCount = 50000;
      const minimumHeaderLength = 0x24;
      if (bytes.length < minimumHeaderLength) {
        return 'DAT 文件头不完整';
      }
      await _reportImportProgress(
        onProgress,
        '读取 DAT',
        bytes.length,
        bytes.length,
        detail: '${bytes.length} 字节',
      );

      final data = ByteData.sublistView(bytes);
      final declaredLength = data.getUint32(0, Endian.little);
      if (declaredLength != bytes.length) {
        return 'DAT 文件长度校验失败';
      }

      final storedPointCount = data.getUint32(0x20, Endian.little);
      if (storedPointCount <= reservedPointCount) {
        return 'DAT 文件没有有效数据';
      }
      final expectedLength = 4 + channelCount * (32 + storedPointCount * 2);
      if (expectedLength != bytes.length) {
        return 'DAT 数据布局不匹配';
      }

      final importedPointCount = storedPointCount - reservedPointCount;
      final addresses = <int>[];
      final channelDataOffsets = <int>[];
      for (int channel = 0; channel < channelCount; channel++) {
        final channelNumber = channel + 1;
        final blockOffset = channel * storedPointCount * 2;
        final dataOffset =
            0x04 + channelNumber * 32 + blockOffset + reservedPointCount * 2;
        // Each channel block has a 32-byte header. Its address field is the
        // uint32 value 12 bytes before the raw sample data.
        final addressOffset = dataOffset - reservedPointCount * 2 - 12;
        final dataEnd =
            0x04 + channelNumber * 32 + blockOffset + storedPointCount * 2;
        if (addressOffset + 4 > bytes.length ||
            dataOffset > dataEnd ||
            dataEnd > bytes.length) {
          return 'DAT 通道数据不完整';
        }
        addresses.add(data.getUint32(addressOffset, Endian.little));
        channelDataOffsets.add(dataOffset);
      }

      final importedPoints = <PlotDataPoint>[];
      for (int pointIndex = 0; pointIndex < importedPointCount; pointIndex++) {
        final byteOffset = pointIndex * 2;
        importedPoints.add(
          PlotDataPoint(
            index: pointIndex,
            timestamp: pointIndex.toDouble(),
            values: [
              for (final offset in channelDataOffsets)
                data.getInt16(offset + byteOffset, Endian.little).toDouble(),
            ],
          ),
        );
        if ((pointIndex + 1) % _importProgressBatchSize == 0 ||
            pointIndex + 1 == importedPointCount) {
          await _reportImportProgress(
            onProgress,
            '解析 DAT',
            pointIndex + 1,
            importedPointCount,
            detail: '${pointIndex + 1} 点',
          );
        }
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: {'channelAddresses': addresses},
        onProgress: onProgress,
      );
      AppLogger().info(
        '旧版 DAT 导入成功: $filePath, $importedPointCount 点, 地址=${addresses.map((address) => '0x${address.toRadixString(16).toUpperCase()}').join(',')}',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('旧版 DAT 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  Future<void> _replaceImportedPoints(
    List<PlotDataPoint> importedPoints,
    int channelCount, {
    Map<String, dynamic>? metadata,
    PlotImportProgressCallback? onProgress,
  }) async {
    _dataPoints.clear();
    _parsedHistory.clear();
    _lodIndex.clear();
    _zobowRawFrames.clear();
    _fixedFrameRawFrames.clear();
    _importedChannelAddresses = null;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (int i = 0; i < importedPoints.length; i++) {
      final point = importedPoints[i];
      _parsedHistory.add(point.values);
      _lodIndex.add(point.index, point.values);
      for (final value in point.values) {
        if (value < minY) minY = value;
        if (value > maxY) maxY = value;
      }
      if ((i + 1) % _importProgressBatchSize == 0 ||
          i + 1 == importedPoints.length) {
        await _reportImportProgress(
          onProgress,
          '建立绘图索引',
          i + 1,
          importedPoints.length,
          detail: '${i + 1} 点',
        );
      }
    }
    _nextIndex = importedPoints.length;
    _activeChannelCount = channelCount;
    _startTime = null;
    _applyImportedMetadata(metadata, channelCount);

    final visibleCount =
        importedPoints.length.clamp(0, _maxVisiblePoints).toInt();
    final visibleStart = importedPoints.length - visibleCount;
    viewport = PlotViewport(
      xMin: visibleStart.toDouble(),
      xMax: importedPoints.length.toDouble(),
      yMin: minY == double.infinity ? 0 : minY,
      yMax: maxY == double.negativeInfinity ? 1 : maxY,
    );
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      0,
      visibleCount,
      detail: '$visibleCount 点',
    );
    _rebuildParsedWindow(visibleStart, visibleCount);
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      visibleCount,
      visibleCount,
      detail: '$visibleCount 点',
    );
    _viewportHistory.clear();

    _cursor = null;
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;

    Future.microtask(() => notifyListeners());
  }

  void _applyImportedMetadata(
    Map<String, dynamic>? metadata,
    int channelCount,
  ) {
    if (metadata == null || metadata.isEmpty) return;

    final names = metadata['channelNames'];
    if (names is List) {
      for (
        int i = 0;
        i < names.length && i < channelCount && i < channels.length;
        i++
      ) {
        final name = names[i];
        if (name is String && name.isNotEmpty) {
          channels[i].alias = name == 'Ch$i' ? '' : name;
        }
      }
    }

    final addresses = metadata['channelAddresses'];
    if (addresses is List) {
      _importedChannelAddresses = _applyChannelAddresses(
        addresses,
        channelCount,
      );
    }

    final ids = metadata['zobowChannelIds'];
    if (metadata['parserType'] == ParserType.zobow.name && ids is List) {
      _parserType = ParserType.zobow;
      _parserConfig.type = ParserType.zobow;
      _parserConfig.channelCount =
          channelCount >= ParserConfig.maxZobowChannelCount
              ? ParserConfig.maxZobowChannelCount
              : ParserConfig.minZobowChannelCount;
      _applyChannelAddresses(ids, _parserConfig.zobowChannelCount);
      AppSettings().parserType = ParserType.zobow.name;
      _saveSettings();
    }
  }

  List<int> _applyChannelAddresses(List<dynamic> values, int channelCount) {
    final addresses = <int>[];
    for (
      int i = 0;
      i < values.length &&
          i < channelCount &&
          i < _parserConfig.zobowChannelIds.length;
      i++
    ) {
      final value = values[i];
      final address = switch (value) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(
          value.replaceAll('0x', '').replaceAll('0X', ''),
          radix: 16,
        ),
        _ => null,
      };
      if (address != null) {
        final normalized = address & 0xFFFFFFFF;
        _parserConfig.zobowChannelIds[i] = normalized;
        addresses.add(normalized);
      }
    }
    return addresses;
  }

  // ========== 众邦电控配置文件操作 ==========

  /// 选择配置文件
  void selectZobowProfile(String? profileId) {
    _profileService.selectProfile(profileId);
    // 保存到设置
    final settings = AppSettings();
    settings.zobowProfileId = profileId ?? '';
    settings.save();
    Future.microtask(() => notifyListeners());
  }

  /// 创建新配置文件
  Future<ZobowConfigProfile?> createZobowProfile(String name) async {
    final profile = await _profileService.createProfile(name);
    Future.microtask(() => notifyListeners());
    return profile;
  }

  /// 更新配置文件
  Future<void> updateZobowProfile(ZobowConfigProfile profile) async {
    await _profileService.updateProfile(profile);
    Future.microtask(() => notifyListeners());
  }

  /// 删除配置文件
  Future<void> deleteZobowProfile(String id) async {
    await _profileService.deleteProfile(id);
    Future.microtask(() => notifyListeners());
  }

  /// 应用预设到指定通道
  void applyPresetToChannel(int channelIndex, ZobowChannelPreset preset) {
    if (channelIndex < 0 || channelIndex >= 4) return;
    _parserConfig.zobowChannelIds[channelIndex] = preset.address & 0xFFFFFFFF;
    // 同时设置通道别名
    if (preset.name.isNotEmpty && channelIndex < channels.length) {
      channels[channelIndex].alias = preset.name;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 重新加载配置文件列表
  Future<void> reloadZobowProfiles() async {
    await _profileService.reload();
    Future.microtask(() => notifyListeners());
  }

  /// 释放所有资源：取消订阅、停止数据源、释放解析器、停止定时器
  ///
  /// 注意：全局单例模式下不修改 serialService.isPlotting，
  /// 避免页面切换时误停绘图状态。
  @override
  void dispose() {
    _disposed = true;
    _parseSubscription?.cancel();
    _parseSubscription = null;
    _sourceManager.stop();
    _parser?.dispose();
    _parser = null;
    _isPlotting = false;
    _isStopping = false;
    _stopFuture = null;
    // 全局单例模式下不重置 serialService.isPlotting
    // serialService.isPlotting = false;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _pendingNotifyCount = 0;
    _stopRefreshTimer();
    _sourceManager.dispose();
    super.dispose();
  }
}

/// 速率统计样本
class _ParsedValueHistory {
  static const int _chunkPointCount = 4096;
  static const int _maxChannels = 16;

  final List<Float64List> _valueChunks = [];
  final List<Uint8List> _countChunks = [];

  int _length = 0;
  int _maxChannelCount = 0;

  bool get isEmpty => _length == 0;
  int get length => _length;
  int get maxChannelCount => _maxChannelCount;

  void clear() {
    _valueChunks.clear();
    _countChunks.clear();
    _length = 0;
    _maxChannelCount = 0;
  }

  void add(List<double> values) {
    final chunkIndex = _length ~/ _chunkPointCount;
    final chunkOffset = _length % _chunkPointCount;
    if (chunkIndex == _valueChunks.length) {
      _valueChunks.add(Float64List(_chunkPointCount * _maxChannels));
      _countChunks.add(Uint8List(_chunkPointCount));
    }

    final count = values.length.clamp(0, _maxChannels).toInt();
    _countChunks[chunkIndex][chunkOffset] = count;
    final base = chunkOffset * _maxChannels;
    final chunk = _valueChunks[chunkIndex];
    for (int i = 0; i < count; i++) {
      chunk[base + i] = values[i];
    }

    if (count > _maxChannelCount) _maxChannelCount = count;
    _length++;
  }

  List<double> valuesAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    final chunkIndex = index ~/ _chunkPointCount;
    final chunkOffset = index % _chunkPointCount;
    final count = _countChunks[chunkIndex][chunkOffset];
    final base = chunkOffset * _maxChannels;
    final chunk = _valueChunks[chunkIndex];

    return List<double>.generate(
      count,
      (i) => chunk[base + i],
      growable: false,
    );
  }
}

class _RateSample {
  final int index;
  final int timestampMs;
  _RateSample(this.index, this.timestampMs);
}

/// 将字符串解析为 ParserType
ParserType _parserTypeFromString(String value) {
  return switch (value) {
    'fixedFrame' => ParserType.fixedFrame,
    'zobow' => ParserType.zobow,
    'justFloat' => ParserType.justFloat,
    _ => ParserType.fireWater,
  };
}
