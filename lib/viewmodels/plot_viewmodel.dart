import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/constants/plot_configuration.dart';
import '../core/localization/app_strings.dart';
import '../core/utils/app_logger.dart';
import '../core/utils/atomic_file.dart';
import '../core/utils/crc.dart';
import '../core/utils/plot_value_formatter.dart';
import '../core/utils/plot_performance_metrics.dart';
import '../data/models/channel_config.dart';
import '../data/models/data_source_config.dart';
import '../data/models/math_channel_config.dart';
import '../data/models/parse_result.dart';
import '../data/models/parser_config.dart';
import '../data/models/plot_data.dart';
import '../data/models/plot_lod_index.dart';
import '../data/models/retention_usage.dart';
import '../data/parser/data_parser.dart';
import '../data/parser/firewater_parser.dart';
import '../data/parser/fixed_frame_parser.dart';
import '../data/parser/just_float_parser.dart';
import '../data/parser/zobow_parser.dart';
import '../data/models/address_config_profile.dart';
import '../data/protocol/plot_protocol_codec.dart';
import '../data/protocol/send_protocol.dart';
import '../services/app_notifications.dart';
import '../services/app_settings.dart';
import '../services/serial_service.dart';
import '../services/address_profile_service.dart';
import '../services/plot_protocol_initializer.dart';
import '../views/plot/plot_painter.dart';
import '../views/plot/plot_viewport.dart';
import 'base_viewmodel.dart';
import 'plot_history_store.dart';
import 'plot_math_engine.dart';
import 'plot_observation_assembler.dart';
import 'plot_session_controller.dart';
import 'plot_statistics_calculator.dart';
import 'plot_trigger_runtime.dart';
import 'plot_window_provider.dart';

part 'plot_viewmodel/plot_import_export.dart';
part 'plot_viewmodel/plot_channel_controls.dart';
part 'plot_viewmodel/plot_display_controls.dart';
part 'plot_viewmodel/plot_interaction_controls.dart';
part 'plot_viewmodel/plot_profiles.dart';
part 'plot_viewmodel/plot_support_models.dart';
part 'plot_viewmodel/plot_viewport_controls.dart';

typedef PlotImportProgressCallback = void Function(PlotImportProgress progress);
typedef PlotExportProgressCallback = void Function(PlotImportProgress progress);

enum PlotTriggerComparison {
  greater('>'),
  less('<'),
  equal('='),
  crossUp('上升沿经过'),
  crossDown('下降沿经过');

  final String label;

  const PlotTriggerComparison(this.label);
}

enum PlotTriggerAction {
  markOnly('不停止'),
  stopImmediately('立即停止'),
  stopAfterPackets('继续接收后停止');

  final String label;

  const PlotTriggerAction(this.label);
}

enum PlotTriggerObservationMode {
  none('不打观察'),
  triggerPoint('标记触发点'),
  allHits('标记本轮全部命中');

  final String label;

  const PlotTriggerObservationMode(this.label);
}

class PlotTriggerConfig {
  static const double equalTolerance = 1e-6;

  bool enabled;
  int channelIndex;
  PlotTriggerComparison comparison;
  double targetValue;
  int hitThreshold;
  int triggerLimit;
  PlotTriggerAction action;
  int postTriggerPacketCount;
  PlotTriggerObservationMode observationMode;
  bool includeSystemTimeInNote;

  PlotTriggerConfig({
    this.enabled = false,
    this.channelIndex = 0,
    this.comparison = PlotTriggerComparison.greater,
    this.targetValue = 0,
    this.hitThreshold = 1,
    this.triggerLimit = 1,
    this.action = PlotTriggerAction.stopImmediately,
    this.postTriggerPacketCount = 0,
    this.observationMode = PlotTriggerObservationMode.none,
    this.includeSystemTimeInNote = true,
  });

  PlotTriggerConfig copy() {
    return PlotTriggerConfig(
      enabled: enabled,
      channelIndex: channelIndex,
      comparison: comparison,
      targetValue: targetValue,
      hitThreshold: hitThreshold,
      triggerLimit: triggerLimit,
      action: action,
      postTriggerPacketCount: postTriggerPacketCount,
      observationMode: observationMode,
      includeSystemTimeInNote: includeSystemTimeInNote,
    );
  }
}

class PlotImportProgress {
  final String stage;
  final int current;
  final int total;
  final String? detail;
  final double? bytesPerSecond;

  const PlotImportProgress({
    required this.stage,
    required this.current,
    required this.total,
    this.detail,
    this.bytesPerSecond,
  });

  double? get fraction {
    if (total <= 0) return null;
    return (current / total).clamp(0.0, 1.0);
  }
}

class PlotExportCancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
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
/// 数据流：DataSourceManager → IDataParser → 历史缓存/当前窗口 → 分层 Painter。
///
/// 这里同时维护“全量历史”和“当前绘图窗口”两套数据结构：
/// - 当前窗口 `_dataPoints` 只保存 UI 正在绘制的点，避免 Flutter 持有过多对象。
/// - 文本/浮点协议的历史值进入 `_historyStore`，按视口重建窗口。
/// - Zobow/FixedFrame 的历史以原始固定帧保存，导出和回看都能复用原始字节。
/// - 历史存储中的 LOD 始终增量更新，用于大范围拖动/缩放时快速预览。
///
/// UI 刷新：通过 notifyListeners() 驱动 Consumer[PlotViewModel] 重建。
class PlotViewModel extends BaseViewModel {
  // ========== 数据源 ==========
  /// 唯一拥有 parser、数据订阅和 start/stop single-flight 的会话控制器。
  late final PlotSessionController _sessionController;
  late final PlotProtocolInitializer _protocolInitializer;

  // ========== 数据缓冲区 ==========
  /// 唯一拥有当前精确窗口和异步加载 generation 的窗口提供器。
  late final PlotWindowProvider _windowProvider;
  List<PlotDataPoint> get _dataPoints => _windowProvider.points;

  /// 唯一拥有紧凑值、固定原始帧和 LOD 的历史存储。
  final PlotHistoryStore _historyStore = PlotHistoryStore();

  /// 当前窗口最大点数，避免 UI 持有过多 PlotDataPoint 对象
  static const int maxObservationCount = PlotConfiguration.maxObservationCount;
  static const int minVisiblePoints = PlotConfiguration.minVisiblePointCount;
  static const int defaultVisiblePoints =
      PlotConfiguration.defaultVisiblePointCount;
  static const int maxVisiblePointsLimit =
      PlotConfiguration.maxVisiblePointCount;
  static const int maxDiscardInitialPacketCount =
      PlotConfiguration.maxDiscardInitialPacketCount;
  int _maxVisiblePoints = defaultVisiblePoints;
  final int _materializedPointLimit;
  int _discardInitialPacketCount = 0;
  int _activeDiscardInitialPacketLimit = 0;
  int _discardedInitialPacketCount = 0;
  int _dataRevision = 0;
  int _channelConfigRevision = 0;
  int _viewportRevision = 0;
  int _overlayRevision = 0;

  /// 各显示通道是否已经观察到有限小数值，避免 Painter 每帧扫描窗口。
  final List<bool> _observedChannelValues = List<bool>.filled(
    PlotConfiguration.totalChannelCount,
    false,
  );
  final List<bool> _observedFractionalValues = List<bool>.filled(
    PlotConfiguration.totalChannelCount,
    false,
  );

  static const int plotRetentionLimitBytes =
      PlotConfiguration.defaultHistoryMemoryLimitBytes;
  static const double _retentionWarningRatio = 0.8;
  int _plotRetentionLimitBytes;
  final bool _retentionLimitInjected;
  bool _plotRetentionWarningShown = false;
  bool _plotRetentionLimitReached = false;
  String? _plotRetentionStopReason;

  /// 下一个数据点的索引序号（单调递增）
  int _nextIndex = 0;

  /// 绘图开始时间，用于计算时间戳
  DateTime? _startTime;

  // ========== 速率统计（基于计数器，避免遍历列表）==========
  /// 速率统计按 50ms 聚合，避免高频接收时每包创建一个 Dart 对象。
  final ListQueue<_RateBucket> _rateBuckets = ListQueue<_RateBucket>();

  /// 速率统计保留窗口，必须按时间裁剪，不能按固定样本数裁剪。
  static const int _rateSampleWindowMs = 2400;
  static const int _rateDisplayWindowMs = 2000;
  static const int _rateBucketDurationMs = 50;

  static const int _rateCalculationIntervalMs = 250;
  static const double _rateDisplayEmaAlpha = 0.35;
  static const double _highRateEnterThreshold = 10000.0;
  static const double _highRateExitThreshold = 8000.0;
  static const int _highRateExitHoldMs = 2000;
  static const int _highRateRefreshFps = 30;
  static const double _highRateLodTargetUpdatesPerSecond = 5000.0;

  double? _cachedPointsPerSecond;
  double? _cachedRawPointsPerSecond;
  double? _smoothedPointsPerSecond;
  int? _lastRateCalculationMs;
  bool _highRateMode = false;
  int? _belowHighRateSinceMs;

  // ========== 当前数据实际通道数 ==========
  /// 当前数据中实际出现的通道数（用于动态显示通道面板）。
  ///
  /// 大多数协议取运行期内出现过的最大值；JustFloat 自动识别模式例外，
  /// 以最新有效帧为准，这样设备从 8 通道切到 4 通道后不会继续显示
  /// 已经没有数据的偏置轴和 r 协议地址槽位。
  int _activeChannelCount = 0;
  int? _retainedAutoChannelCount;

  bool _hasStartedPlottingOnce = false;

  // ========== 视口 ==========
  /// 当前绘图视口，定义可见的 X/Y 数据范围
  PlotViewport viewport = PlotViewport(
    xMin: PlotConfiguration.viewportDefaultXMin,
    xMax: PlotConfiguration.viewportDefaultXMax,
    yMin: PlotConfiguration.viewportDefaultYMin,
    yMax: PlotConfiguration.viewportDefaultYMax,
  );

  // ========== 视口历史记录（用于撤回） ==========
  /// 视口历史记录栈，每次缩放/平移前保存当前状态
  final List<PlotViewport> _viewportHistory = [];

  /// 视口历史最大深度
  static const int _maxHistory = 50;

  // ========== 通道配置 ==========
  /// 通道配置列表（默认16通道），包含颜色、可见性、缩放、偏移等
  final List<ChannelConfig> channels = ChannelConfig.createDefaults();
  final List<MathChannelConfig> mathChannels =
      MathChannelConfig.createDefaults();
  final PlotMathEngine _mathEngine = PlotMathEngine();
  final PlotObservationAssembler _observationAssembler =
      const PlotObservationAssembler();
  final PlotStatisticsCalculator _statisticsCalculator =
      const PlotStatisticsCalculator();
  int _nextOffsetBindingGroupId = 1;
  List<PlotDataPoint>? _cachedDisplayDataPoints;
  String? _cachedDisplayDataKey;
  PlotDataPoint? _cachedLatestDisplayPoint;
  String? _cachedLatestDisplayPointKey;
  List<ChannelConfig>? _cachedDisplayChannels;
  String? _cachedDisplayChannelKey;
  List<int>? _importedChannelAddresses;
  List<ChannelPresetBinding> _channelPresetBindings = [];
  List<int>? get importedChannelAddresses =>
      _importedChannelAddresses == null
          ? null
          : List.unmodifiable(_importedChannelAddresses!);

  // ========== 状态 ==========
  bool get _isPlotting => _sessionController.isRunning;
  bool get _isStarting => _sessionController.isStarting;
  bool get _isStopping => _sessionController.isStopping;

  /// 是否显示网格
  bool _showGrid = true;

  /// 是否使用随机数据源（而非串口）
  bool _useRandomSource = false;

  // ========== 高级设置 ==========
  /// UI 刷新帧率 (fps)，范围 30~60，默认 60
  int _refreshFps = 60;

  /// 绘图界面字体大小偏移，基于默认字号调整，范围 -3~6
  int _plotFontSizeDelta = 0;

  /// 绘图界面文本是否使用粗体。
  bool _plotFontBold = false;

  /// 网格密度: 'sparse'(稀疏), 'normal'(普通), 'dense'(密集)
  String _gridDensity = 'normal';

  /// 绘图背景: 'dark'(黑底), 'light'(白底)
  String _plotBackground = 'dark';

  /// 绘图区悬浮窗不透明度。
  double _floatingPanelOpacity = 0.85;
  double? _legendPanelRight;
  double? _legendPanelTop;
  double? _liveValuesPanelRight;
  double? _liveValuesPanelTop;

  /// 添加观察时是否先跟随鼠标，再由左键固定。
  bool _observationClickToPlace = false;

  /// 抗锯齿固定开启。
  static const bool _antiAliasEnabled = true;
  bool _snapHighlightEnabled = true;
  double _snapHighlightDiameter = 8.0;
  String _snapHighlightColorMode = 'cursor';
  bool _statsToolbarEnabled = false;
  bool _triggerToolbarEnabled = false;
  bool _previewToolbarEnabled = false;
  PlotLodQuality _lodQuality = PlotLodQuality.performance;
  bool _keepPlotOnRestart = false;

  /// 最新点跟随模式：最新数据点保持在视口指定宽度比例处。
  bool _followEnabled = false;
  double _followPositionRatio = 0.9;
  double _yFitDisplayRatio = 0.8;

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

  final List<PlotObservation> _observations = [];
  bool _observationPlacementActive = false;
  CursorState? _observationPreview;
  final PlotTriggerConfig _triggerConfig = PlotTriggerConfig();
  final PlotTriggerRuntime<PlotDataPoint> _triggerRuntime =
      PlotTriggerRuntime<PlotDataPoint>();
  bool _triggerStopDispatchScheduled = false;
  bool _triggerConfigured = false;

  /// 当前解析器类型
  ParserType _parserType = ParserType.zobow;

  /// 用户选择的发送协议。Zobow 接收协议会临时覆盖为内置发送协议。
  SendProtocolType _sendProtocolType = SendProtocolType.none;

  final SendProtocolConfig _sendProtocolConfig = SendProtocolConfig();
  bool _rProtocolLooseChannelSettings = false;

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
  final AddressProfileService _profileService = AddressProfileService();
  final AddressProfileService _rProfileService = AddressProfileService(
    protocolType: AddressProfileProtocolType.rProtocol,
  );
  int _profileRevision = 0;

  /// 配置文件列表（供UI下拉框使用）
  List<AddressConfigProfile> get zobowProfiles => _profileService.profiles;
  int get profileRevision => _profileRevision;

  /// 当前选中的配置文件
  AddressConfigProfile? get selectedZobowProfile =>
      _profileService.selectedProfile;

  /// 当前选中的配置文件ID
  String get selectedZobowProfileId => _profileService.selectedProfileId;

  List<AddressConfigProfile> get rProfiles => _rProfileService.profiles;
  AddressConfigProfile? get selectedRProfile =>
      _rProfileService.selectedProfile;
  String get selectedRProfileId => _rProfileService.selectedProfileId;

  // ========== 定时刷新 ==========
  /// 定时刷新器，用于光标跟随和停止后的交互响应
  Timer? _refreshTimer;

  /// 最近一次临时提示，保留给诊断和测试使用。
  String? _lastStatusMessage;
  String? _protocolInitFailureMessage;
  bool _disposed = false;

  /// 定时刷新间隔（ms），无数据时保持 UI 响应
  static const int _refreshIntervalMs = 100;

  // ========== UI 刷新降频（数据不丢失）==========
  /// 待刷新的数据包计数，达到批量大小后触发 UI 刷新
  int _pendingNotifyCount = 0;

  /// 动态批量大小：控制 UI 刷新频率，数据始终全部接收。
  int get _notifyBatchSize {
    final fps = effectiveRefreshFps;
    final double targetRate;
    if (_useRandomSource) {
      targetRate = _sourceConfig.randomFrequencyHz;
    } else {
      targetRate =
          _cachedRawPointsPerSecond ?? _cachedPointsPerSecond ?? 1000.0;
    }
    return (targetRate / fps).round().clamp(1, 5000);
  }

  int get _visibleTrimBatchSize {
    final byRatio = (effectiveMaterializedPointLimit / 32).round();
    return math.min(
      effectiveMaterializedPointLimit,
      byRatio.clamp(4096, 65536).toInt(),
    );
  }

  int get _lodSampleStep {
    if (!_highRateMode) return 1;
    final rate = _cachedRawPointsPerSecond ?? _cachedPointsPerSecond;
    if (rate == null || rate <= _highRateLodTargetUpdatesPerSecond) return 1;
    return (rate / _highRateLodTargetUpdatesPerSecond).ceil().clamp(1, 128);
  }

  /// 兜底定时器：确保数据流中断时 UI 仍能刷新。
  Timer? _notifyTimer;
  bool _dragViewportNotifyScheduled = false;
  int _dragViewportNotifyGeneration = 0;

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
  PlotViewModel(
    super.serialService, {
    int? retentionLimitBytes,
    int? materializedPointLimit,
  }) : _materializedPointLimit =
           materializedPointLimit ??
           PlotConfiguration.maxMaterializedPointCount,
       _retentionLimitInjected = retentionLimitBytes != null,
       _plotRetentionLimitBytes =
           retentionLimitBytes ??
           AppSettings().plotHistoryMemoryLimitGiB *
               PlotConfiguration.bytesPerGiB {
    if (_plotRetentionLimitBytes <= 0) {
      throw ArgumentError.value(
        _plotRetentionLimitBytes,
        'retentionLimitBytes',
        'must be positive',
      );
    }
    if (_materializedPointLimit <= 0 ||
        _materializedPointLimit > PlotConfiguration.maxMaterializedPointCount) {
      throw ArgumentError.value(
        _materializedPointLimit,
        'materializedPointLimit',
        'must be between 1 and '
            '${PlotConfiguration.maxMaterializedPointCount}',
      );
    }
    _windowProvider = PlotWindowProvider(
      isDisposed: () => _disposed,
      onStateChanged: () {
        Future.microtask(() {
          if (!_disposed) notifyListeners();
        });
      },
      onCommitted: () {
        _dataRevision++;
        _invalidateDisplayCaches();
      },
    );
    _sessionController = PlotSessionController(
      serialService,
      onStateChanged: () {
        Future.microtask(() {
          if (!_disposed) notifyListeners();
        });
      },
    );
    _protocolInitializer = PlotProtocolInitializer(serialService);
    _loadSettings();
    _initAddressProfileServices();
    _startRefreshTimer();
  }

  @override
  void notifyListeners() {
    PlotPerformanceMetrics.instance.increment(
      PlotPerformanceMetric.viewModelNotify,
    );
    super.notifyListeners();
  }

  /// 初始化Zobow配置文件服务
  Future<void> _initAddressProfileServices() async {
    await _profileService.init();
    await _rProfileService.init();
    if (_disposed) return;
    // 加载上次选中的配置文件
    final savedProfileId = AppSettings().zobowProfileId;
    if (savedProfileId.isNotEmpty) {
      _profileService.selectProfile(savedProfileId);
    }
    final savedRProfileId = AppSettings().rProfileId;
    if (savedRProfileId.isNotEmpty) {
      _rProfileService.selectProfile(savedRProfileId);
    }
    _profileRevision++;
    unawaited(
      Future.microtask(() {
        if (!_disposed) notifyListeners();
      }),
    );
  }

  /// 从 AppSettings 加载绘图配置
  void _loadSettings() {
    final settings = AppSettings();
    _refreshFps = settings.refreshFps;
    _plotFontSizeDelta = settings.plotFontSizeDelta.clamp(-3, 6);
    _plotFontBold = settings.plotFontBold;
    _maxVisiblePoints = settings.maxVisiblePoints.clamp(
      minVisiblePoints,
      maxVisiblePointsLimit,
    );
    _discardInitialPacketCount = settings.discardInitialPacketCount.clamp(
      0,
      maxDiscardInitialPacketCount,
    );
    _showGrid = settings.showGrid;
    _gridDensity = settings.gridDensity;
    _plotBackground = settings.plotBackground == 'light' ? 'light' : 'dark';
    _floatingPanelOpacity = settings.floatingPanelOpacity.clamp(0.0, 1.0);
    _legendPanelRight = settings.plotLegendPanelRight;
    _legendPanelTop = settings.plotLegendPanelTop;
    _liveValuesPanelRight = settings.plotLiveValuesPanelRight;
    _liveValuesPanelTop = settings.plotLiveValuesPanelTop;
    _observationClickToPlace = settings.observationClickToPlace;
    _snapHighlightEnabled = settings.snapHighlightEnabled;
    _snapHighlightDiameter = settings.snapHighlightDiameter.clamp(6.0, 12.0);
    _snapHighlightColorMode = settings.snapHighlightColorMode;
    _statsToolbarEnabled = settings.statsToolbarEnabled;
    _triggerToolbarEnabled = settings.triggerToolbarEnabled;
    _previewToolbarEnabled = settings.previewToolbarEnabled;
    _lodQuality = switch (settings.plotLodQuality) {
      'balanced' => PlotLodQuality.balanced,
      'qualityHigh' => PlotLodQuality.quality,
      _ => PlotLodQuality.performance,
    };
    _keepPlotOnRestart = settings.keepPlotOnRestart;
    _useRandomSource = settings.useRandomSource;
    _followEnabled = settings.followEnabled;
    _followPositionRatio = settings.followPositionRatio.clamp(0.5, 0.95);
    _yFitDisplayRatio = settings.yFitDisplayRatio.clamp(0.5, 0.95);
    _replaceMathChannels(settings.mathChannels, save: false);
    _applyPlotBackgroundPalette();
    _sourceConfig.randomFrequencyHz = settings.randomFrequency.clamp(
      1.0,
      100000.0,
    );
    _sourceConfig.randomIntervalMs =
        (1000.0 / _sourceConfig.randomFrequencyHz)
            .round()
            .clamp(1, 1000)
            .toInt();
    _setViewport(
      PlotViewport(
        xMin: settings.xMin,
        xMax: settings.xMax,
        yMin: settings.yMin,
        yMax: settings.yMax,
      ),
    );
    // 同步到 serialService
    serialService.useRandomSource = _useRandomSource;
    // 加载解析器类型
    _parserType = _parserTypeFromString(settings.parserType);
    _parserConfig
      ..type = _parserType
      ..source =
          settings.receiveCustomProtocolId.isEmpty
              ? ProtocolSource.builtIn
              : ProtocolSource.lua
      ..customProtocolId =
          settings.receiveCustomProtocolId.isEmpty
              ? null
              : settings.receiveCustomProtocolId
      ..zobowChannelIds = List.from(settings.zobowChannelIds)
      ..zobowChannelTypes = List.from(settings.zobowChannelTypes)
      ..fixedFrameChannelTypes = List.from(settings.fixedFrameChannelTypes);
    _channelPresetBindings =
        settings.channelPresetBindings
            .map(
              (binding) => ChannelPresetBinding(
                protocolType: binding.protocolType,
                channelIndex: binding.channelIndex,
                addressKey: binding.addressKey,
                name: binding.name,
                profileId: binding.profileId,
              ),
            )
            .toList();
    _sendProtocolType = _sendProtocolTypeFromString(settings.sendProtocolType);
    _sendProtocolConfig
      ..type = _sendProtocolType
      ..source =
          settings.sendCustomProtocolId.isEmpty
              ? ProtocolSource.builtIn
              : ProtocolSource.lua
      ..customProtocolId =
          settings.sendCustomProtocolId.isEmpty
              ? null
              : settings.sendCustomProtocolId
      ..rChannelAddresses = List.from(settings.rChannelAddresses);
    _restorePresetAliasesFromBindings();
    _rProtocolLooseChannelSettings = settings.rProtocolLooseChannelSettings;
    if (_parserType == ParserType.justFloat) {
      _parserConfig.channelCount =
          settings.justFloatChannelCount
              .clamp(0, PlotConfiguration.rawChannelCount)
              .toInt();
    }
  }

  /// 保存绘图配置到 AppSettings
  void _saveSettings() {
    final settings = AppSettings();
    settings.refreshFps = _refreshFps;
    settings.plotFontSizeDelta = _plotFontSizeDelta;
    settings.plotFontBold = _plotFontBold;
    settings.maxVisiblePoints = _maxVisiblePoints;
    if (!_retentionLimitInjected) {
      settings.plotHistoryMemoryLimitGiB = plotRetentionLimitGiB;
    }
    settings.discardInitialPacketCount = _discardInitialPacketCount;
    settings.snapHighlightEnabled = _snapHighlightEnabled;
    settings.snapHighlightDiameter = _snapHighlightDiameter;
    settings.snapHighlightColorMode = _snapHighlightColorMode;
    settings.statsToolbarEnabled = _statsToolbarEnabled;
    settings.triggerToolbarEnabled = _triggerToolbarEnabled;
    settings.previewToolbarEnabled = _previewToolbarEnabled;
    settings.plotLodQuality = switch (_lodQuality) {
      PlotLodQuality.performance => 'performance',
      PlotLodQuality.balanced => 'balanced',
      PlotLodQuality.quality => 'qualityHigh',
    };
    settings.keepPlotOnRestart = _keepPlotOnRestart;
    settings.showGrid = _showGrid;
    settings.gridDensity = _gridDensity;
    settings.plotBackground = _plotBackground;
    settings.floatingPanelOpacity = _floatingPanelOpacity;
    settings.plotLegendPanelRight = _legendPanelRight;
    settings.plotLegendPanelTop = _legendPanelTop;
    settings.plotLiveValuesPanelRight = _liveValuesPanelRight;
    settings.plotLiveValuesPanelTop = _liveValuesPanelTop;
    settings.observationClickToPlace = _observationClickToPlace;
    settings.useRandomSource = _useRandomSource;
    settings.randomFrequency = randomFrequency;
    settings.followEnabled = _followEnabled;
    settings.followPositionRatio = _followPositionRatio;
    settings.yFitDisplayRatio = _yFitDisplayRatio;
    settings.mathChannels =
        mathChannels
            .map((channel) => MathChannelConfig.fromJson(channel.toJson()))
            .toList();
    settings.parserType = _parserType.name;
    settings.receiveCustomProtocolId = _parserConfig.customProtocolId ?? '';
    settings.sendProtocolType = _sendProtocolType.name;
    settings.sendCustomProtocolId = _sendProtocolConfig.customProtocolId ?? '';
    settings.rChannelAddresses = List.from(
      _sendProtocolConfig.rChannelAddresses,
    );
    settings.rProtocolLooseChannelSettings = _rProtocolLooseChannelSettings;
    if (_parserType == ParserType.justFloat) {
      settings.justFloatChannelCount =
          _parserConfig.channelCount
              .clamp(0, PlotConfiguration.rawChannelCount)
              .toInt();
    }
    settings.zobowChannelIds = List.from(_parserConfig.zobowChannelIds);
    settings.zobowChannelTypes = List.from(_parserConfig.zobowChannelTypes);
    settings.channelPresetBindings =
        _channelPresetBindings
            .map(
              (binding) => ChannelPresetBinding(
                protocolType: binding.protocolType,
                channelIndex: binding.channelIndex,
                addressKey: binding.addressKey,
                name: binding.name,
                profileId: binding.profileId,
              ),
            )
            .toList();
    settings.fixedFrameChannelTypes = List.from(
      _parserConfig.fixedFrameChannelTypes,
    );
    settings.zobowProfileId = _profileService.selectedProfileId;
    settings.rProfileId = _rProfileService.selectedProfileId;
    // vCursorEnabled 不持久化
    settings.xMin = viewport.xMin;
    settings.xMax = viewport.xMax;
    settings.yMin = viewport.yMin;
    settings.yMax = viewport.yMax;
    settings.save();
  }

  // ========== 状态读取接口 ==========
  /// 当前绘图窗口的数据点列表（供 UI 读取）。
  ///
  /// 这里直接返回稳定窗口引用，避免每次 build 复制大列表。
  List<PlotDataPoint> get dataPoints => _dataPoints;
  bool get isPlotting => _sessionController.isRunning;
  bool get isStarting => _sessionController.isStarting;
  bool get isStopping => _sessionController.isStopping;
  bool get showGrid => _showGrid;
  bool get useRandomSource => _useRandomSource;
  int get refreshFps => _refreshFps;
  int get effectiveRefreshFps =>
      _highRateMode ? _highRateRefreshFps : _refreshFps;
  bool get highRateMode => _highRateMode;
  int get plotFontSizeDelta => _plotFontSizeDelta;
  bool get plotFontBold => _plotFontBold;
  String get gridDensity => _gridDensity;
  String get plotBackground => _plotBackground;
  double get floatingPanelOpacity => _floatingPanelOpacity;
  double get legendPanelRight => _legendPanelRight ?? 16;
  double get legendPanelTop => _legendPanelTop ?? 96;
  double get liveValuesPanelRight => _liveValuesPanelRight ?? 16;
  double liveValuesPanelTop({required bool legendVisible}) =>
      _liveValuesPanelTop ?? (legendVisible ? 240 : 96);
  bool get observationClickToPlace => _observationClickToPlace;
  bool get boxZoomEnabled => _boxZoomEnabled;
  bool get followEnabled => _followEnabled;
  double get followPositionRatio => _followPositionRatio;
  double get yFitDisplayRatio => _yFitDisplayRatio;
  List<MathChannelConfig> get enabledMathChannels =>
      mathChannels.where((channel) => channel.enabled).toList(growable: false);
  int get rawDisplayChannelCount {
    if (_parserType == ParserType.zobow) return _parserConfig.zobowChannelCount;
    if (_parserType == ParserType.fixedFrame) return _parserConfig.channelCount;
    if (effectiveSendProtocolType == SendProtocolType.rProtocol) {
      return math.max(_activeChannelCount, rAddressDisplayCount);
    }
    return _activeChannelCount > 0 ? _activeChannelCount : channels.length;
  }

  List<ChannelConfig> get displayChannels {
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    final key = [
      for (final channel in channels.take(rawCount))
        '${channel.visible}:${channel.alias}:${channel.color.toARGB32()}:${channel.showLine}:${channel.pointSize}:${channel.lineWidth}:${channel.yOffset}:${channel.offsetEnabled}:${channel.yScale}:${channel.offsetBindingGroupId}',
      for (final channel in mathChannels)
        '${channel.enabled}:${channel.expression}:${channel.display.visible}:${channel.display.color.toARGB32()}:${channel.display.showLine}:${channel.display.pointSize}:${channel.display.lineWidth}:${channel.display.yOffset}:${channel.display.offsetEnabled}:${channel.display.yScale}:${channel.display.offsetBindingGroupId}',
    ].join('|');
    if (_cachedDisplayChannels != null && _cachedDisplayChannelKey == key) {
      return _cachedDisplayChannels!;
    }
    _cachedDisplayChannelKey = key;
    _cachedDisplayChannels = [
      ...channels.take(rawCount),
      for (final channel in mathChannels)
        if (channel.enabled) channel.display,
    ];
    return _cachedDisplayChannels!;
  }

  List<ChannelConfig> get triggerCandidateChannels {
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    return [
      ...channels.take(rawCount).where((channel) => channel.visible),
      for (final channel in mathChannels)
        if (_canUseMathChannelForTrigger(channel)) channel.display,
    ];
  }

  bool _canUseMathChannelForTrigger(MathChannelConfig channel) {
    final expression = _mathEngine.expressionFor(channel.index);
    return channel.enabled &&
        channel.display.visible &&
        expression != null &&
        !expression.hasChannelOffset;
  }

  List<PlotDataPoint> get displayDataPoints {
    if (!mathChannels.any((channel) => channel.enabled)) return _dataPoints;
    final rawCount = rawDisplayChannelCount;
    final key =
        '$rawCount|${mathChannels.map((channel) => '${channel.enabled}:${channel.expression}').join('|')}';
    final futureLookahead = _mathDisplayFutureLookahead;
    var cache = _cachedDisplayDataPoints;
    final mustRebuild =
        cache == null ||
        _cachedDisplayDataKey != key ||
        (cache.isNotEmpty &&
            _dataPoints.isNotEmpty &&
            cache.first.index > _dataPoints.first.index) ||
        cache.length > _dataPoints.length;

    if (mustRebuild) {
      cache = <PlotDataPoint>[];
      _cachedDisplayDataPoints = cache;
      _cachedDisplayDataKey = key;
    } else {
      if (cache.isNotEmpty && _dataPoints.isNotEmpty) {
        final dropCount = _dataPoints.first.index - cache.first.index;
        if (dropCount > 0) {
          if (dropCount >= cache.length) {
            cache.clear();
          } else {
            cache.removeRange(0, dropCount);
          }
        }
      }
    }

    if (_dataPoints.isEmpty) {
      cache.clear();
      return cache;
    }

    final start =
        cache.isNotEmpty
            ? (cache.length - futureLookahead)
                .clamp(0, _dataPoints.length)
                .toInt()
            : 0;
    if (cache.length > start) {
      cache.removeRange(start, cache.length);
    }
    for (int i = start; i < _dataPoints.length; i++) {
      cache.add(_buildDisplayPoint(_dataPoints[i], i, _dataPoints));
    }
    return cache;
  }

  /// 全量历史中的最新显示点，不受当前视口窗口和跟随模式影响。
  ///
  /// 实时值浮窗必须持续展示最新接收数据。用户回看历史时，[_dataPoints]
  /// 会固定为当前加载窗口，因此不能从 [displayDataPoints] 的末尾取值。
  PlotDataPoint? get latestDisplayDataPoint {
    final historyCount = _historyPointCount;
    if (historyCount <= 0) return null;

    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    final mathKey = mathChannels
        .map((channel) => '${channel.enabled}:${channel.expression}')
        .join('|');
    final cacheKey = '$historyCount|$rawCount|$mathKey';
    if (_cachedLatestDisplayPointKey == cacheKey) {
      return _cachedLatestDisplayPoint;
    }

    final pointIndex = historyCount - 1;
    final rawValues = _rawValuesAtHistoryIndex(pointIndex);
    if (rawValues.isEmpty) return null;

    final mathValues = <double>[];
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      final value = _mathEngine.evaluateAt(
        channelIndex: channel.index,
        currentIndex: pointIndex,
        pointCount: historyCount,
        valueAt: _rawHistoryValueAt,
      );
      mathValues.add(value);
    }

    final timestamp =
        _dataPoints.isNotEmpty && _dataPoints.last.index == pointIndex
            ? _dataPoints.last.timestamp
            : pointIndex.toDouble();
    final point = PlotDataPoint(
      index: pointIndex,
      timestamp: timestamp,
      values:
          mathValues.isEmpty
              ? rawValues
              : _CombinedChannelValues(
                rawValues: rawValues,
                rawChannelCount: rawCount,
                mathValues: mathValues,
              ),
    );
    _cachedLatestDisplayPointKey = cacheKey;
    _cachedLatestDisplayPoint = point;
    return point;
  }

  int get displayActiveChannelCount => displayChannels.length;
  bool get vCursorEnabled => _vCursorEnabled;
  bool get xMeasurementEnabled => _xMeasurementEnabled;
  bool get yMeasurementEnabled => _yMeasurementEnabled;
  bool get statsEnabled => _statsEnabled;
  bool get statsRangeEnabled => _statsRangeEnabled;
  bool get statsToolbarEnabled => _statsToolbarEnabled;
  bool get triggerToolbarEnabled => _triggerToolbarEnabled;
  bool get previewToolbarEnabled => _previewToolbarEnabled;
  PlotLodQuality get lodQuality => _lodQuality;
  double? get statsX1 => _statsX1;
  double? get statsX2 => _statsX2;
  bool get antiAliasEnabled => _antiAliasEnabled;
  bool get snapHighlightEnabled => _snapHighlightEnabled;
  double get snapHighlightDiameter => _snapHighlightDiameter;

  ChannelConfig? displayChannelByIndex(int index) {
    for (final channel in displayChannels) {
      if (channel.index == index) return channel;
    }
    return null;
  }

  String displayChannelName(int index) {
    final channel = displayChannelByIndex(index);
    if (channel == null) return 'Ch$index';
    if (channel.alias.isNotEmpty) return channel.alias;
    return index >= PlotConfiguration.rawChannelCount
        ? 'Math${index - PlotConfiguration.rawChannelCount + 1}'
        : 'Ch$index';
  }

  bool canConfigureOffsetBinding(int index) {
    final channel = displayChannelByIndex(index);
    return channel != null && channel.visible && channel.offsetEnabled;
  }

  List<ChannelConfig> offsetBindingCandidates(int index) {
    return displayChannels
        .where(
          (channel) =>
              channel.index != index &&
              channel.visible &&
              channel.offsetEnabled,
        )
        .toList(growable: false);
  }

  List<int> offsetBindingMemberIndices(int index) {
    final channel = displayChannelByIndex(index);
    final groupId = channel?.offsetBindingGroupId;
    if (groupId == null) return const [];
    return displayChannels
        .where(
          (member) =>
              member.offsetBindingGroupId == groupId &&
              member.visible &&
              member.offsetEnabled,
        )
        .map((member) => member.index)
        .toList(growable: false);
  }

  String get snapHighlightColorMode => _snapHighlightColorMode;
  CursorState? get cursor => _cursor;
  List<PlotObservation> get observations => List.unmodifiable(_observations);
  bool get observationPlacementActive => _observationPlacementActive;
  CursorState? get observationPreview => _observationPreview;
  PlotTriggerConfig get triggerConfig => _triggerConfig.copy();
  bool get triggerEnabled => _triggerConfig.enabled;
  bool get triggerConfigured => _triggerConfigured;
  bool get keepPlotOnRestart => _keepPlotOnRestart;
  int get triggerHitCount => _triggerRuntime.hitCount;
  int get triggeredCount => _triggerRuntime.triggeredCount;
  int? get triggerStopPacketsRemaining => _triggerRuntime.stopItemsRemaining;
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
  SendProtocolType get sendProtocolType => _sendProtocolType;
  SendProtocolType get effectiveSendProtocolType =>
      _parserType == ParserType.zobow
          ? SendProtocolType.zobowBuiltIn
          : _sendProtocolType;
  List<String> get rChannelAddresses =>
      List.unmodifiable(_sendProtocolConfig.rChannelAddresses);
  bool get rProtocolLooseChannelSettings => _rProtocolLooseChannelSettings;
  PlotLodSource get lodIndex => _historyStore.lodSource;
  int get zobowRawFrameCount => _historyStore.zobowFrameCount;
  RetentionUsage get plotRetentionUsage {
    final used = _estimatedPlotAllocatedBytes;
    final ratio = used / _plotRetentionLimitBytes;
    final state =
        _plotRetentionLimitReached
            ? RetentionState.limitReached
            : ratio >= _retentionWarningRatio
            ? RetentionState.warning
            : RetentionState.normal;
    return RetentionUsage(
      usedBytes: used.clamp(0, _plotRetentionLimitBytes).toInt(),
      limitBytes: _plotRetentionLimitBytes,
      state: state,
    );
  }

  int get plotRetentionLimitGiB =>
      _plotRetentionLimitBytes ~/ PlotConfiguration.bytesPerGiB;

  /// 本次绘图接收到的数据点总数
  int get pointCount => _nextIndex;
  int? get minJumpXIndex => _nextIndex > 0 ? 0 : null;
  int? get maxJumpXIndex => _nextIndex > 0 ? _nextIndex - 1 : null;

  /// 当前窗口中的数据点数量
  int get visiblePointCount => _dataPoints.length;

  /// 当前窗口起始点序号
  int get visibleStartIndex => _windowProvider.visibleStartIndex;
  bool get isWindowLoading => _windowProvider.isLoading;

  /// 当前窗口点数上限
  int get maxVisiblePoints => _maxVisiblePoints;

  int get effectiveMaxVisiblePoints => _maxVisiblePoints;
  int get effectiveMaterializedPointLimit =>
      math.min(_maxVisiblePoints, _materializedPointLimit);

  /// 每次开始绘图时丢弃的前置有效数据包数量。
  int get discardInitialPacketCount => _discardInitialPacketCount;

  /// 当前窗口数据版本，用于窗口长度不变但内容滚动时触发重绘。
  int get dataRevision => _dataRevision;
  int get channelConfigRevision => _channelConfigRevision;
  int get viewportRevision => _viewportRevision;
  int get overlayRevision => _overlayRevision;

  bool get displayYValuesAreInteger {
    final currentChannels = displayChannels;
    var hasVisibleValues = false;
    for (int i = 0; i < currentChannels.length; i++) {
      final channel = currentChannels[i];
      if (!channel.visible) continue;
      if (channel.yScale != channel.yScale.roundToDouble() ||
          channel.yOffset != channel.yOffset.roundToDouble()) {
        return false;
      }
      if (i >= _observedChannelValues.length ||
          !_observedChannelValues[i] ||
          _observedFractionalValues[i]) {
        return false;
      }
      hasVisibleValues = true;
    }
    return hasVisibleValues;
  }

  @visibleForTesting
  int get notifyBatchSizeForTest => _notifyBatchSize;

  @visibleForTesting
  int get lodSampleStepForTest => _lodSampleStep;

  @visibleForTesting
  int get rateBucketCountForTest => _rateBuckets.length;

  @visibleForTesting
  int get parsedHistoryAllocatedValueSlotsForTest =>
      _historyStore.parsedAllocatedValueSlots;

  /// 当前数据中实际出现的最大通道数
  int get activeChannelCount => _activeChannelCount;

  /// 随机源频率（Hz），由间隔毫秒数换算
  double get randomFrequency => _sourceConfig.randomFrequencyHz;

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

  int get _visibleStartIndex => _windowProvider.visibleStartIndex;
  int get _visibleEndIndex => _windowProvider.visibleEndIndex;

  void _invalidateDisplayCaches() {
    _cachedDisplayDataPoints = null;
    _cachedDisplayDataKey = null;
    _cachedLatestDisplayPoint = null;
    _cachedLatestDisplayPointKey = null;
    _invalidateDisplayChannelCaches();
  }

  void _invalidateDisplayChannelCaches() {
    _cachedDisplayChannels = null;
    _cachedDisplayChannelKey = null;
    _cachedStatsKey = null;
    _cachedStatsText = null;
  }

  void _resetObservedValueMetadata() {
    _observedChannelValues.fillRange(0, _observedChannelValues.length, false);
    _observedFractionalValues.fillRange(
      0,
      _observedFractionalValues.length,
      false,
    );
  }

  void _recordObservedValues(List<double> values, {int startChannel = 0}) {
    for (int i = 0; i < values.length; i++) {
      final channelIndex = startChannel + i;
      if (channelIndex >= _observedChannelValues.length) return;
      final value = values[i];
      if (!value.isFinite) continue;
      _observedChannelValues[channelIndex] = true;
      if ((value - value.roundToDouble()).abs() > 1e-9) {
        _observedFractionalValues[channelIndex] = true;
      }
    }
  }

  void _rebuildObservedRawValueMetadata() {
    _resetObservedValueMetadata();
    for (final point in _dataPoints) {
      _recordObservedValues(point.values);
    }
  }

  void _setViewport(PlotViewport next) {
    viewport = next;
    _viewportRevision++;
  }

  void _markChannelConfigChanged() {
    _channelConfigRevision++;
  }

  static String _presetAddressKey(
    AddressProfileProtocolType protocolType,
    int address,
  ) {
    return '${protocolType.id}:${address & 0xFFFFFFFF}';
  }

  static String? _rPresetAddressKeyFromText(String text) {
    final value = rSendProtocol.parseAddress(text);
    if (value == null || value < 0) return null;
    return _presetAddressKey(AddressProfileProtocolType.rProtocol, value);
  }

  String? _currentPresetAddressKey(
    AddressProfileProtocolType protocolType,
    int channelIndex,
  ) {
    switch (protocolType) {
      case AddressProfileProtocolType.zobow:
        if (channelIndex < 0 ||
            channelIndex >= _parserConfig.zobowChannelIds.length) {
          return null;
        }
        return _presetAddressKey(
          protocolType,
          _parserConfig.zobowChannelIds[channelIndex],
        );
      case AddressProfileProtocolType.rProtocol:
        if (channelIndex < 0 ||
            channelIndex >= _sendProtocolConfig.rChannelAddresses.length) {
          return null;
        }
        return _rPresetAddressKeyFromText(
          _sendProtocolConfig.rChannelAddresses[channelIndex],
        );
    }
  }

  int _findPresetBindingIndex(
    AddressProfileProtocolType protocolType,
    int channelIndex,
  ) {
    return _channelPresetBindings.indexWhere(
      (binding) =>
          binding.protocolType == protocolType &&
          binding.channelIndex == channelIndex,
    );
  }

  void _setPresetBinding({
    required AddressProfileProtocolType protocolType,
    required int channelIndex,
    required int address,
    required String name,
    required String profileId,
  }) {
    _clearPresetBinding(protocolType, channelIndex);
    if (name.isEmpty) return;
    _channelPresetBindings.add(
      ChannelPresetBinding(
        protocolType: protocolType,
        channelIndex: channelIndex,
        addressKey: _presetAddressKey(protocolType, address),
        name: name,
        profileId: profileId,
      ),
    );
  }

  void _clearPresetBinding(
    AddressProfileProtocolType protocolType,
    int channelIndex,
  ) {
    _channelPresetBindings.removeWhere(
      (binding) =>
          binding.protocolType == protocolType &&
          binding.channelIndex == channelIndex,
    );
  }

  void _clearPresetAliasesForChangedAddress(
    AddressProfileProtocolType protocolType,
    int channelIndex,
    String? nextAddressKey,
  ) {
    final bindingIndex = _findPresetBindingIndex(protocolType, channelIndex);
    if (bindingIndex < 0) return;
    final binding = _channelPresetBindings[bindingIndex];
    if (binding.addressKey == nextAddressKey) return;
    _channelPresetBindings.removeAt(bindingIndex);
    if (channelIndex < channels.length) {
      channels[channelIndex].alias = '';
    }
  }

  void _restorePresetAliasesFromBindings() {
    _channelPresetBindings.removeWhere((binding) {
      final currentKey = _currentPresetAddressKey(
        binding.protocolType,
        binding.channelIndex,
      );
      if (currentKey != binding.addressKey) return true;
      if (binding.channelIndex < channels.length) {
        channels[binding.channelIndex].alias = binding.name;
      }
      return false;
    });
  }

  void _markOverlayChanged() {
    _overlayRevision++;
  }

  int get _mathDisplayFutureLookahead =>
      _mathEngine.futureLookahead(mathChannels);

  void _replaceMathChannels(
    List<MathChannelConfig> nextChannels, {
    bool save = true,
  }) {
    for (int i = 0; i < mathChannels.length; i++) {
      mathChannels[i] =
          i < nextChannels.length
              ? nextChannels[i]
              : MathChannelConfig(index: i);
      mathChannels[i].display.alias = mathChannels[i].name;
    }
    _mathEngine.rebuild(mathChannels);
    _invalidateDisplayCaches();
    if (save) _saveSettings();
  }

  void _compileMathChannel(MathChannelConfig channel) {
    _mathEngine.compile(channel);
  }

  double _evaluateMathChannel(
    MathChannelConfig channel,
    int pointPosition,
    List<PlotDataPoint> sourcePoints,
  ) {
    final historyIndex = sourcePoints[pointPosition].index;
    return _mathEngine.evaluateAt(
      channelIndex: channel.index,
      currentIndex: historyIndex,
      pointCount: _historyPointCount,
      valueAt: _rawHistoryValueAt,
    );
  }

  PlotDataPoint _buildDisplayPoint(
    PlotDataPoint point,
    int pointPosition,
    List<PlotDataPoint> sourcePoints,
  ) {
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    final mathValues = <double>[];
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      final value = _evaluateMathChannel(channel, pointPosition, sourcePoints);
      mathValues.add(value);
    }
    _recordObservedValues(mathValues, startChannel: rawCount);
    return PlotDataPoint(
      index: point.index,
      timestamp: point.timestamp,
      values: _CombinedChannelValues(
        rawValues: point.values,
        rawChannelCount: rawCount,
        mathValues: mathValues,
      ),
    );
  }

  /// 状态栏提示文本，根据当前状态给用户操作建议
  ///
  /// 提示场景：
  /// - 未连接串口且未使用随机源 → 提示先连接串口或启用随机源
  /// - 串口连接中 → 提示正在连接
  /// - 串口已连接但未开始绘图 → 提示点击开始按钮
  /// - 众邦电控模式下 → 提示地址在通道面板设置
  String get hintText {
    if (_plotRetentionLimitReached && !_isPlotting && !_isStopping) {
      return _plotRetentionStopReason ?? '绘图历史已达到容量上限，请清空后继续';
    }
    if (serialService.isConnecting) {
      return '正在连接串口...';
    }
    if (_isStarting) {
      return '正在启动绘图...';
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
    final pointsPerSecond = _calculatePointsPerSecond();
    if (pointsPerSecond != null) {
      buffer.write('点数: $_nextIndex (${pointsPerSecond.toStringAsFixed(1)}/s)');
    } else {
      buffer.write('点数: $_nextIndex');
    }
    if (_highRateMode) {
      buffer.write(' 高频模式 ${effectiveRefreshFps}fps');
    }
    if (_dataPoints.isNotEmpty && _dataPoints.length < _nextIndex) {
      buffer.write(' 窗口: $_visibleStartIndex-${_visibleEndIndex - 1}');
    }
    if (_isPlotting) {
      buffer.write(' [运行中]');
    }
    final usage = plotRetentionUsage;
    buffer.write(
      ' 历史: ${_formatRetentionBytes(usage.usedBytes)} / '
      '${_formatRetentionBytes(usage.limitBytes)} '
      '(${(usage.ratio * 100).toStringAsFixed(1)}%)',
    );
    if (usage.state == RetentionState.limitReached) {
      buffer.write(' [容量上限停止]');
    } else if (usage.state == RetentionState.warning) {
      buffer.write(' [容量预警]');
    }
    return buffer.toString();
  }

  /// 计算每秒点数，基于最近2s窗口并使用 EMA 平滑显示值。
  /// 使用计数器方式，避免遍历整个数据列表。
  double? _calculatePointsPerSecond({int? nowMs, bool force = false}) {
    if (_rateBuckets.isEmpty || _startTime == null) {
      _cachedPointsPerSecond = null;
      _cachedRawPointsPerSecond = null;
      _smoothedPointsPerSecond = null;
      return null;
    }
    final effectiveNowMs =
        nowMs ?? DateTime.now().difference(_startTime!).inMilliseconds;
    if (!force &&
        _lastRateCalculationMs != null &&
        effectiveNowMs - _lastRateCalculationMs! < _rateCalculationIntervalMs) {
      return _cachedPointsPerSecond;
    }

    final rawRate = _calculateRawPointsPerSecond(effectiveNowMs);
    _cachedRawPointsPerSecond = rawRate;
    _lastRateCalculationMs = effectiveNowMs;
    if (rawRate == null) {
      _cachedPointsPerSecond = null;
      return null;
    }
    _smoothedPointsPerSecond =
        _smoothedPointsPerSecond == null
            ? rawRate
            : _smoothedPointsPerSecond! * (1 - _rateDisplayEmaAlpha) +
                rawRate * _rateDisplayEmaAlpha;
    _cachedPointsPerSecond = _smoothedPointsPerSecond;
    return _cachedPointsPerSecond;
  }

  double? _calculateRawPointsPerSecond(int effectiveNowMs) {
    final cutoffMs = effectiveNowMs - _rateDisplayWindowMs;

    _RateBucket? first;
    _RateBucket? last;
    for (final bucket in _rateBuckets) {
      if (bucket.lastTimestampMs < cutoffMs) continue;
      first ??= bucket;
      last = bucket;
    }

    if (first == null || last == null) {
      return null;
    }
    final elapsedMs = last.lastTimestampMs - first.firstTimestampMs;
    if (elapsedMs <= 0) {
      return null;
    }
    return (last.lastIndex - first.firstIndex) * 1000.0 / elapsedMs;
  }

  void _recordRateSample(int pointIndex, int timestampMs) {
    final bucketStartMs =
        timestampMs ~/ _rateBucketDurationMs * _rateBucketDurationMs;
    final lastBucket = _rateBuckets.isEmpty ? null : _rateBuckets.last;
    if (lastBucket != null && lastBucket.startMs == bucketStartMs) {
      lastBucket.update(pointIndex, timestampMs);
    } else {
      _rateBuckets.add(
        _RateBucket(
          startMs: bucketStartMs,
          firstIndex: pointIndex,
          firstTimestampMs: timestampMs,
        ),
      );
    }
    final cutoffMs = timestampMs - _rateSampleWindowMs;
    while (_rateBuckets.isNotEmpty &&
        _rateBuckets.first.lastTimestampMs < cutoffMs) {
      _rateBuckets.removeFirst();
    }
    final rate = _calculateRawPointsPerSecond(timestampMs);
    _cachedRawPointsPerSecond = rate;
    _calculatePointsPerSecond(nowMs: timestampMs);
    _updateHighRateMode(rate, timestampMs);
  }

  void _resetRateState() {
    _rateBuckets.clear();
    _cachedPointsPerSecond = null;
    _cachedRawPointsPerSecond = null;
    _smoothedPointsPerSecond = null;
    _lastRateCalculationMs = null;
    _highRateMode = false;
    _belowHighRateSinceMs = null;
  }

  void _updateHighRateMode(double? pointsPerSecond, int timestampMs) {
    if (pointsPerSecond == null) return;
    if (pointsPerSecond > _highRateEnterThreshold) {
      _highRateMode = true;
      _belowHighRateSinceMs = null;
      return;
    }
    if (!_highRateMode) return;
    if (pointsPerSecond >= _highRateExitThreshold) {
      _belowHighRateSinceMs = null;
      return;
    }
    _belowHighRateSinceMs ??= timestampMs;
    if (timestampMs - _belowHighRateSinceMs! >= _highRateExitHoldMs) {
      _highRateMode = false;
      _belowHighRateSinceMs = null;
    }
  }

  /// 显示浮动临时提示。
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
  /// 同时同步更新 serialService 的随机源状态。
  void setUseRandomSource(bool value) {
    if (_useRandomSource == value) return;
    if (!_canModifyInputConfiguration()) return;
    _useRandomSource = value;
    _sourceConfig.useRandom = value && _parserType == ParserType.fireWater;
    _sourceConfig.useSerial = serialService.isConnected;
    // 根据 FireWater 配置的通道数设置随机数据源通道数
    // 如果 fireWaterChannelCount 为 0，则默认输出 4 通道
    _sourceConfig.randomChannelCount =
        _parserConfig.fireWaterChannelCount > 0
            ? _parserConfig.fireWaterChannelCount
            : 4;
    unawaited(_sessionController.updateConfig(_sourceConfig));
    _saveSettings();
    AppLogger().info(
      '随机源${value ? '启用' : '关闭'}，解析器=${_parserType.label}，'
      '接入当前解析链=${_sourceConfig.useRandom}',
      category: 'PLOT',
    );

    if (value && _parserType != ParserType.fireWater) {
      showStatusMessage('随机源已保留；随机源数据仅支持 FireWater 解析器');
    } else {
      showStatusMessage(value ? '随机源已启用' : '随机源已关闭');
    }

    unawaited(Future.microtask(() => notifyListeners()));
  }

  /// 设置随机源频率（Hz），范围 1~100000
  void setRandomFrequency(double hz) {
    final clampedHz = hz.roundToDouble().clamp(1.0, 100000.0);
    if (_sourceConfig.randomFrequencyHz == clampedHz) return;
    final intervalMs = (1000.0 / clampedHz).round().clamp(1, 1000).toInt();
    _sourceConfig.randomFrequencyHz = clampedHz;
    _sourceConfig.randomIntervalMs = intervalMs;
    unawaited(_sessionController.updateRandomFrequency(clampedHz));
    _saveSettings();
    AppLogger().info(
      '随机源频率设置为 ${clampedHz.toInt()} Hz，生成间隔=${intervalMs}ms',
      category: 'PLOT',
    );

    unawaited(Future.microtask(() => notifyListeners()));
  }

  // ========== 解析器控制 ==========
  /// 切换解析器类型（FireWater / 固定帧 / 众邦电控）
  ///
  /// 注意：随机数据源仅适用于 FireWater 协议，切换到其他解析器时保留开关
  /// 状态，但不会把随机源接入当前解析链。
  void setParserType(ParserType type) {
    if (_parserType == type) return;
    if (!_canModifyInputConfiguration()) return;
    final oldType = _parserType;
    _parserType = type;
    _markChannelConfigChanged();
    _resetObservedValueMetadata();
    _parserConfig
      ..type = type
      ..source = ProtocolSource.builtIn
      ..customProtocolId = null;
    if (type == ParserType.zobow &&
        _parserConfig.channelCount != ParserConfig.maxZobowChannelCount) {
      _parserConfig.channelCount = ParserConfig.minZobowChannelCount;
    } else if (type == ParserType.justFloat) {
      _parserConfig.channelCount =
          AppSettings().justFloatChannelCount
              .clamp(0, PlotConfiguration.rawChannelCount)
              .toInt();
    }

    if (type != ParserType.fireWater && _useRandomSource) {
      AppLogger().info('切换到非 FireWater 协议，保留随机源开关但不接入当前解析链', category: 'PLOT');
      showStatusMessage('随机源已保留；当前解析器仅使用串口数据');
    }
    AppLogger().info(
      '接收协议从 ${oldType.label} 切换为 ${type.label}',
      category: 'PLOT',
    );

    // 保存解析器类型到设置
    final settings = AppSettings();
    settings.parserType = type.name;
    if (type == ParserType.justFloat) {
      settings.justFloatChannelCount =
          _parserConfig.channelCount
              .clamp(0, PlotConfiguration.rawChannelCount)
              .toInt();
    }
    settings.save();

    Future.microtask(() => notifyListeners());
  }

  void setSendProtocolType(SendProtocolType type) {
    if (type == SendProtocolType.zobowBuiltIn) return;
    if (_sendProtocolType == type) return;
    if (!_canModifyInputConfiguration()) return;
    final oldType = _sendProtocolType;
    _sendProtocolType = type;
    _markChannelConfigChanged();
    _sendProtocolConfig
      ..type = type
      ..source = ProtocolSource.builtIn
      ..customProtocolId = null;
    _saveSettings();
    AppLogger().info(
      '发送协议从 ${oldType.label} 切换为 ${type.label}',
      category: 'PLOT',
    );
    Future.microtask(() => notifyListeners());
  }

  void setRChannelAddress(int index, String address) {
    if (_isPlotting || _isStopping) return;
    if (index < 0 || index >= SendProtocolConfig.maxChannelCount) return;
    final next = address.trim();
    if (_sendProtocolConfig.rChannelAddresses[index] == next) return;
    final nextKey = _rPresetAddressKeyFromText(next);
    _sendProtocolConfig.rChannelAddresses[index] = next;
    _clearPresetAliasesForChangedAddress(
      AddressProfileProtocolType.rProtocol,
      index,
      nextKey,
    );
    _markChannelConfigChanged();
    _saveSettings();
    AppLogger().info(
      'r协议 Ch$index 地址设置为 ${next.isEmpty ? '<空>' : next}',
      category: 'PLOT',
    );
    Future.microtask(() => notifyListeners());
  }

  void setRProtocolLooseChannelSettings(bool value) {
    if (_rProtocolLooseChannelSettings == value) return;
    if (!_canModifyInputConfiguration()) return;
    _rProtocolLooseChannelSettings = value;
    _saveSettings();
    AppLogger().info('r协议宽松通道设置${value ? '启用' : '关闭'}', category: 'PLOT');
    Future.microtask(() => notifyListeners());
  }

  /// r 协议地址槽位在通道面板中的显示数量。
  ///
  /// 规则和接收协议绑定，而不是单纯按用户已填写的地址数量：
  /// - 自动识别接收通道且未开始绘图时，显示全部 16 个槽位，方便预先配置。
  /// - JustFloat 自动识别运行中，按最新有效帧解析出的通道数显示。
  /// - 固定通道数协议严格按配置通道数显示，多填的 r 地址不撑大面板。
  /// - 只有 FireWater 自动识别运行中这类无法提前知道通道数的情况，
  ///   才按连续填写的 r 地址数量预留一个可继续填写的槽位。
  int get rAddressDisplayCount {
    if (!_isPlotting && _usesAutoDetectedReceiveChannels) {
      return SendProtocolConfig.maxChannelCount;
    }
    if (_isPlotting &&
        _parserType == ParserType.justFloat &&
        _parserConfig.channelCount == 0) {
      return _activeChannelCount.clamp(0, SendProtocolConfig.maxChannelCount);
    }
    final fixedCount = _fixedReceiveChannelCount;
    if (fixedCount != null) {
      return fixedCount.clamp(1, SendProtocolConfig.maxChannelCount);
    }
    final configured =
        _rProtocolLooseChannelSettings
            ? _rConfiguredAddressCount()
            : _rContinuousAddressCount(throwOnGap: false);
    return math.max(
      1,
      math.min(PlotConfiguration.rawChannelCount, configured + 1),
    );
  }

  bool get _usesAutoDetectedReceiveChannels {
    return switch (_parserType) {
      ParserType.fireWater => _parserConfig.fireWaterChannelCount == 0,
      ParserType.justFloat => _parserConfig.channelCount == 0,
      ParserType.fixedFrame || ParserType.zobow => false,
    };
  }

  int? get _fixedReceiveChannelCount {
    return switch (_parserType) {
      ParserType.fireWater =>
        _parserConfig.fireWaterChannelCount > 0
            ? _parserConfig.fireWaterChannelCount
            : null,
      ParserType.justFloat =>
        _parserConfig.channelCount > 0 ? _parserConfig.channelCount : null,
      ParserType.fixedFrame => _parserConfig.channelCount,
      ParserType.zobow => _parserConfig.zobowChannelCount,
    };
  }

  /// 更新解析器配置并同步到数据源
  ///
  /// 同时更新随机数据源的通道数以匹配 FireWater 配置。
  void updateParserConfig(ParserConfig config) {
    if (!_canModifyInputConfiguration()) return;
    if (config.type == ParserType.fixedFrame) {
      final error = config.fixedFrameValidationError;
      if (error != null) {
        throw ArgumentError(error);
      }
    }
    _markChannelConfigChanged();
    _resetObservedValueMetadata();
    final oldZobowFrameLength = ZobowParser.frameLengthForConfig(_parserConfig);
    final oldFixedFrameLength = _parserConfig.totalFrameLength;
    final oldFixedFrameTypeLayout = _fixedFrameTypeLayoutKey(_parserConfig);
    _parserConfig.type = config.type;
    _parserConfig.hasFrameHeader = config.hasFrameHeader;
    _parserConfig.frameHeaderLength = config.frameHeaderLength;
    _parserConfig.frameHeader = List.from(config.frameHeader);
    _parserConfig.dataType = config.dataType;
    _parserConfig.fixedFrameUniformDataType = config.fixedFrameUniformDataType;
    _parserConfig.fixedFrameChannelTypes = List.from(
      config.fixedFrameChannelTypes,
    );
    _parserConfig.channelCount = config.channelCount;
    _parserConfig.fireWaterChannelCount = config.fireWaterChannelCount;
    _parserConfig.hasChecksum = config.hasChecksum;
    _parserConfig.checksumType = config.checksumType;
    _parserConfig.checksumBytes = config.effectiveChecksumBytes;
    _parserConfig.checksumPosition = config.checksumPosition;
    _parserConfig.crcPolynomialName = config.crcPolynomialName;
    _parserConfig.checksumEndian = config.checksumEndian;
    _parserConfig.hasFrameTail = config.hasFrameTail;
    _parserConfig.frameTail =
        config.frameTail != null ? List.from(config.frameTail!) : null;
    _parserConfig.zobowChannelIds = List.from(config.zobowChannelIds);
    _parserConfig.zobowChannelTypes = List.from(config.zobowChannelTypes);
    final newZobowFrameLength = ZobowParser.frameLengthForConfig(_parserConfig);
    final zobowFrameLengthChanged = oldZobowFrameLength != newZobowFrameLength;
    final fixedFrameLengthChanged =
        oldFixedFrameLength != _parserConfig.totalFrameLength;
    final fixedFrameTypeLayoutChanged =
        oldFixedFrameTypeLayout != _fixedFrameTypeLayoutKey(_parserConfig);
    if (zobowFrameLengthChanged) {
      _resetZobowRawFrameBuffer();
    }
    if (fixedFrameLengthChanged || fixedFrameTypeLayoutChanged) {
      _resetFixedFrameRawFrameBuffer();
    }
    if (zobowFrameLengthChanged ||
        fixedFrameLengthChanged ||
        fixedFrameTypeLayoutChanged) {
      clearData();
    }

    // 更新随机数据源通道数以匹配 FireWater 配置
    _sourceConfig.randomChannelCount =
        config.fireWaterChannelCount > 0 ? config.fireWaterChannelCount : 4;
    unawaited(_sessionController.updateConfig(_sourceConfig));
    _saveSettings();
    AppLogger().info(
      '解析器配置已更新：协议=${_parserConfig.type.label}，'
      '通道数=${_parserConfig.channelCount}，FireWater通道=${_parserConfig.fireWaterChannelCount}，'
      '固定帧长度=${_parserConfig.totalFrameLength}，Zobow通道=${_parserConfig.zobowChannelCount}',
      category: 'PLOT',
    );

    Future.microtask(() => notifyListeners());
  }

  bool _canModifyInputConfiguration() {
    if (!_isPlotting && !_isStarting && !_isStopping) return true;
    AppLogger().info('绘图运行中，已拦截输入与协议配置修改', category: 'PLOT');
    showStatusMessage(AppStrings.plot.inputConfigurationDisabledWhilePlotting);
    return false;
  }

  String _fixedFrameTypeLayoutKey(ParserConfig config) {
    return '${config.fixedFrameUniformDataType}|${config.dataType.name}|'
        '${config.fixedFrameChannelTypes.take(config.channelCount).map((type) => type.name).join(',')}';
  }

  // ========== 绘图控制 ==========
  /// 开始绘图
  ///
  /// 流程：
  /// 1. 检查数据源可用性（串口已连接或随机源已启用）
  /// 2. 清空旧数据，重置视口和光标位置
  /// 3. 创建解析器并启动数据源
  /// 4. 连接数据流：DataSourceManager → Parser → _dataPoints
  /// 5. 启动定时刷新
  ///
  /// 注意启动顺序不能随意调整：
  /// - 协议初始化数据必须在数据源启动前发送，失败则不能进入绘图状态。
  /// - `_isPlotting` 只在数据源配置完成后置 true，避免 UI 显示“运行中”
  ///   但解析链实际没有启动。
  /// - 启动前清空所有历史缓存，避免上一轮自动识别通道数影响本轮显示。
  Future<void> startPlotting() {
    if (_isStopping) {
      showStatusMessage('正在停止绘图，请稍候', duration: const Duration(seconds: 1));
      return Future.value();
    }
    if (_isPlotting) return Future.value();

    return _sessionController.start(
      config: _sourceConfig,
      prepare: _preparePlotSessionStart,
      createParser: _createParser,
      initializeProtocol: () async {
        _protocolInitFailureMessage = null;
        return _sendProtocolInitData();
      },
      onData: (results, receivedAt) {
        for (final result in results) {
          _onParseResult(
            result,
            receivedAt: receivedAt,
            updateFollowViewport: false,
          );
        }
        if (_isPlotting && _followEnabled && _dataPoints.length > 1) {
          final lastIndex = _dataPoints.last.index;
          _setViewport(_followViewportForLatestIndex(lastIndex.toDouble()));
        }
      },
      onSourceError: (error) {
        AppLogger().error('数据源错误: $error', category: 'PLOT');
      },
      releaseActivity: () {
        serialService.releaseActivity(SerialActivityOwner.plot);
      },
      onStarted: () {
        Future.microtask(() => serialService.notifyListeners());
        _startRefreshTimer();
        AppLogger().info('开始绘图', category: 'PLOT');
        showStatusMessage('开始绘图', duration: const Duration(seconds: 1));
        Future.microtask(() => notifyListeners());
      },
      onStartRejected: () {
        _sourceConfig.useSerial = false;
        _sourceConfig.useRandom = false;
        final message = _protocolInitFailureMessage ?? '协议初始化失败，已停止绘图';
        showStatusMessage(message);
        AppLogger().warning(message, category: 'PLOT');
        Future.microtask(() => notifyListeners());
      },
      onStartFailed: (error, stackTrace) {
        _sourceConfig.useSerial = false;
        _sourceConfig.useRandom = false;
        AppLogger().error('绘图启动失败: $error\n$stackTrace', category: 'PLOT');
        showStatusMessage('绘图启动失败，已恢复页面操作');
        Future.microtask(() => notifyListeners());
      },
    );
  }

  bool _isPlotSessionCurrent(int generation) =>
      !_disposed && _sessionController.isCurrent(generation);

  Future<bool> _preparePlotSessionStart(int generation) async {
    AppLogger().info(
      '用户请求开始绘图：接收协议=${_parserType.label}，发送协议=${effectiveSendProtocolType.label}，'
      '串口连接=${serialService.isConnected}，随机源=$_useRandomSource，'
      '随机频率=${_sourceConfig.randomFrequencyHz.toInt()}Hz，丢弃前置包=$_discardInitialPacketCount',
      category: 'PLOT',
    );

    if (serialService.isConnected) {
      final connected = await serialService.refreshConnectionStatus();
      if (!_isPlotSessionCurrent(generation)) return false;
      if (!connected && !_useRandomSource) {
        const message = '检测到串口已断开，无法绘图；请重新连接串口';
        showStatusMessage(message);
        AppLogger().warning(message, category: 'PLOT');
        return false;
      }
    }

    final canUseRandom =
        _useRandomSource && _parserType == ParserType.fireWater;

    if (!serialService.isConnected &&
        canUseRandom &&
        _sendProtocolType == SendProtocolType.rProtocol) {
      _sendProtocolType = SendProtocolType.none;
      _sendProtocolConfig.type = SendProtocolType.none;
      _saveSettings();
      showStatusMessage('随机源未连接串口，发送协议已自动切换为无');
    }

    // 检查是否有数据源，尝试自动连接串口
    if (!serialService.isConnected && !_useRandomSource) {
      await _autoConnectSerial();
      if (!_isPlotSessionCurrent(generation)) return false;
      if (!serialService.isConnected) {
        const message = '串口未连接，无法绘图；请连接串口或启用随机源';
        showStatusMessage(message);
        AppLogger().warning(message, category: 'PLOT');
        return false;
      }
    }

    if (!serialService.isConnected && _useRandomSource && !canUseRandom) {
      const message = '随机源仅支持 FireWater 解析器，请切回 FireWater 或连接串口';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      return false;
    }

    if (_keepPlotOnRestart && _plotRetentionLimitReached) {
      const message = '保留历史已达到容量上限，请先清空绘图数据再继续';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      return false;
    }

    // 再次确认数据源配置与实际状态一致
    _sourceConfig.useSerial = serialService.isConnected;
    _sourceConfig.useRandom = canUseRandom;
    AppLogger().info(
      '绘图数据源确认：串口=${_sourceConfig.useSerial}，随机源=${_sourceConfig.useRandom}',
      category: 'PLOT',
    );

    if (!serialService.tryAcquireActivity(SerialActivityOwner.plot)) {
      const message = '其他页面正在接收数据，请先停止后再开始绘图';
      showStatusMessage(message);
      AppLogger().warning(message, category: 'PLOT');
      return false;
    }

    if (!_isPlotSessionCurrent(generation)) {
      serialService.releaseActivity(SerialActivityOwner.plot);
      return false;
    }
    _prepareHistoryForStart();
    _sourceConfig.randomChannelCount =
        _parserConfig.fireWaterChannelCount > 0
            ? _parserConfig.fireWaterChannelCount
            : 4;
    return true;
  }

  /// 停止绘图
  ///
  /// 会话控制器按订阅、数据源、解析器的固定顺序释放资源；ViewModel 只负责
  /// 业务状态、触发器和用户提示收尾。
  Future<void> stopPlotting() {
    if (_isStopping) {
      return _sessionController.pendingStop ?? Future.value();
    }
    if (!_isPlotting && _sessionController.pendingStart == null) {
      _resetRateState();
      return Future.value();
    }

    _resetRateState();
    AppLogger().info(
      '用户请求停止绘图：已接收点=$_nextIndex，当前显示点=${_dataPoints.length}',
      category: 'PLOT',
    );
    _startRefreshTimer();
    showStatusMessage('正在停止绘图...', duration: const Duration(seconds: 1));
    Future.microtask(() => serialService.notifyListeners());

    return _sessionController.stop(
      releaseActivity: () {
        serialService.releaseActivity(SerialActivityOwner.plot);
      },
      onStopped: () {
        _notifyTimer?.cancel();
        _notifyTimer = null;
        _pendingNotifyCount = 0;
        if (_triggerConfig.enabled) {
          _triggerConfig.enabled = false;
        }
        _resetTriggerRuntimeState();
        if (!_disposed) {
          showStatusMessage('已停止绘图', duration: const Duration(seconds: 1));
          AppLogger().info(
            '绘图已停止：总点数=$_nextIndex，Zobow原始帧=${_historyStore.zobowFrameCount}，'
            '固定帧原始帧=${_historyStore.fixedFrameCount}',
            category: 'PLOT',
          );
          Future.microtask(() {
            if (!_disposed) notifyListeners();
          });
        }
      },
    );
  }

  /// 开始绘图时自动尝试连接串口。
  ///
  /// 优先级：
  /// 1. 历史连接过的串口（settings.json 中的 lastPort）
  /// 2. 串口列表中唯一的串口
  Future<void> _autoConnectSerial() async {
    final settings = AppSettings();
    showStatusMessage('正在自动连接串口...', duration: const Duration(seconds: 2));

    // 历史端口直接尝试打开，不依赖枚举结果。部分 USB 串口驱动枚举可能很慢，
    // 但已保存端口的 CreateFile 可以在后台 isolate 中快速确认是否可用。
    final lastPort = settings.lastPort;
    if (lastPort != null && lastPort.isNotEmpty) {
      AppLogger().info('尝试连接历史串口: $lastPort', category: 'PLOT');
      serialService.config = serialService.config.copyWith(port: lastPort);
      await serialService.connect();
      if (serialService.isConnected) {
        showStatusMessage(
          '已自动连接 $lastPort',
          duration: const Duration(seconds: 2),
        );
        return;
      }
    }

    // 历史端口失败后只刷新一次；若当前只有另一个串口，则尝试该端口。
    final refreshed = await serialService.refreshPorts(reason: '自动连接唯一端口');
    if (refreshed && serialService.availablePorts.length == 1) {
      final solePort = serialService.availablePorts.first;
      if (solePort == lastPort) {
        AppLogger().warning('历史串口连接失败，不重复尝试: $solePort', category: 'PLOT');
        return;
      }
      AppLogger().info('尝试连接唯一串口: $solePort', category: 'PLOT');
      serialService.config = serialService.config.copyWith(port: solePort);
      await serialService.connect();
      if (serialService.isConnected) {
        showStatusMessage(
          '已自动连接 $solePort',
          duration: const Duration(seconds: 2),
        );
        return;
      }
    }

    AppLogger().warning('自动连接串口失败', category: 'PLOT');
  }

  @visibleForTesting
  Future<void> autoConnectSerialForTest() => _autoConnectSerial();

  /// 清空所有数据、速率统计、视口和光标
  void clearData() {
    AppLogger().info(
      '用户清空绘图数据：清空前总点数=$_nextIndex，显示点=${_dataPoints.length}',
      category: 'PLOT',
    );
    _cancelWindowLoad();
    _windowProvider.clear();
    _historyStore.clear();
    _resetPlotRetentionState();
    _importedChannelAddresses = null;
    _dataRevision++;
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();
    _resetRateState();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _retainedAutoChannelCount = null;
    _activeDiscardInitialPacketLimit = 0;
    _discardedInitialPacketCount = 0;
    _resetTriggerRuntimeState();
    _startTime = null;
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;
    _setViewport(viewport.reset());
    _viewportHistory.clear();
    _resetCursorPositions();
    Future.microtask(() => notifyListeners());
  }

  void _prepareHistoryForStart() {
    final retainedHistoryIsCompatible = _isRetainedHistoryCompatible();
    final clearIncompatibleHistory =
        _keepPlotOnRestart && !retainedHistoryIsCompatible;
    if (!_keepPlotOnRestart || clearIncompatibleHistory) {
      if (clearIncompatibleHistory) {
        const message = '接收协议已变化或历史来自导入，已清空不可续接的绘图数据';
        AppLogger().warning(message, category: 'PLOT');
        showStatusMessage(message);
      }
      _clearHistoryForRestart();
    } else {
      _importedChannelAddresses = null;
      _hasStartedPlottingOnce = true;
      _retainedAutoChannelCount =
          _nextIndex > 0 &&
                  _usesAutoDetectedReceiveChannels &&
                  _activeChannelCount > 0
              ? _activeChannelCount
              : null;
    }

    _resetRateState();
    _activeDiscardInitialPacketLimit = _discardInitialPacketCount;
    _discardedInitialPacketCount = 0;
    _resetTriggerRuntimeState();
    _startTime = DateTime.now();
    _lastRateLogTime = null;
    _lastRateLogIndex = _nextIndex;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;
  }

  bool _isRetainedHistoryCompatible() {
    if (_nextIndex == 0) return true;
    return _historyStore.isCompatible(_parserType, _nextIndex);
  }

  void _clearHistoryForRestart() {
    // 窗口、全量历史、LOD 和原始帧分别服务于绘制、回看、定位和导出，
    // 重开数据流时必须作为同一份历史一起清理。
    _cancelWindowLoad();
    _windowProvider.clear();
    _historyStore.clear();
    _resetPlotRetentionState();
    _importedChannelAddresses = null;
    _dataRevision++;
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _retainedAutoChannelCount = null;

    // 保留上一轮缩放比例；首次启动仍使用默认视口。
    if (_hasStartedPlottingOnce) {
      final xRange = viewport.xRange;
      _setViewport(viewport.copyWith(xMin: 0, xMax: xRange));
    } else {
      _setViewport(viewport.reset());
      _hasStartedPlottingOnce = true;
    }
    _viewportHistory.clear();
    _resetCursorPositions();
  }

  void _validateRetainedAutoChannelCount(int channelCount) {
    final retainedChannelCount = _retainedAutoChannelCount;
    _retainedAutoChannelCount = null;
    if (retainedChannelCount == null || retainedChannelCount == channelCount) {
      return;
    }

    final message = '自动识别通道数已从 $retainedChannelCount 变为 $channelCount，已清空旧历史';
    AppLogger().warning(message, category: 'PLOT');
    showStatusMessage(message);
    _clearHistoryForRestart();
    _resetRateState();
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;
  }

  // ========== 数据接收 ==========
  int get _estimatedPlotAllocatedBytes =>
      _historyStore.estimatedAllocatedBytes +
      _dataPoints.length * 192 +
      _windowProvider.pendingPointCount * 192 +
      (_cachedDisplayDataPoints?.length ?? 0) * 192;

  int _projectedAllocationFor(ParseResult result) {
    final values = result.values!;
    var additional = _historyStore.projectedAdditionalBytes(
      result: result,
      parserType: _parserType,
      pointIndex: _nextIndex,
      lodChannelCount:
          enabledMathChannels.isEmpty
              ? math.min(values.length, PlotLodIndex.maxChannels)
              : PlotLodIndex.maxChannels,
    );
    if ((_isViewingTail || _followEnabled) &&
        _dataPoints.length < PlotConfiguration.maxMaterializedPointCount) {
      additional += 192;
    }
    return _estimatedPlotAllocatedBytes + additional;
  }

  bool _canAcceptPlotPoint(ParseResult result) {
    if (_plotRetentionLimitReached) return false;
    final emergencyRssBytes = math.max(
      PlotConfiguration.baseEmergencyRssLimitBytes,
      _plotRetentionLimitBytes + PlotConfiguration.emergencyRssHeadroomBytes,
    );
    if (_nextIndex % 4096 == 0 && ProcessInfo.currentRss >= emergencyRssBytes) {
      _reachPlotRetentionLimit(
        '进程内存已达到 ${_formatRetentionBytes(emergencyRssBytes)} 紧急保护线，绘图已停止',
      );
      return false;
    }
    if (_projectedAllocationFor(result) > _plotRetentionLimitBytes) {
      _reachPlotRetentionLimit(
        '绘图历史已达到 ${_formatRetentionBytes(_plotRetentionLimitBytes)} 上限，绘图已停止',
      );
      return false;
    }
    return true;
  }

  void _updatePlotRetentionWarning() {
    if (_plotRetentionWarningShown || _plotRetentionLimitReached) return;
    final usage = plotRetentionUsage;
    if (usage.ratio < _retentionWarningRatio) return;
    _plotRetentionWarningShown = true;
    final message =
        '绘图历史已使用 ${(usage.ratio * 100).toStringAsFixed(1)}%，接近 '
        '${_formatRetentionBytes(usage.limitBytes)} 上限';
    AppLogger().warning(message, category: 'PLOT');
    AppNotifications.show(message, duration: const Duration(seconds: 8));
  }

  void _reachPlotRetentionLimit(String reason) {
    if (_plotRetentionLimitReached) return;
    _plotRetentionLimitReached = true;
    _plotRetentionStopReason = reason;
    _lastStatusMessage = reason;
    AppLogger().warning(reason, category: 'PLOT');
    AppNotifications.show(reason, duration: const Duration(seconds: 12));
    if (_isPlotting || _isStarting) {
      scheduleMicrotask(() {
        if (!_disposed) unawaited(stopPlotting());
      });
    }
    Future.microtask(() {
      if (!_disposed) notifyListeners();
    });
  }

  void _resetPlotRetentionState() {
    _plotRetentionWarningShown = false;
    _plotRetentionLimitReached = false;
    _plotRetentionStopReason = null;
  }

  String _formatRetentionBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GiB';
    return '${(bytes / mib).toStringAsFixed(1)} MiB';
  }

  List<double> _rawValuesAtHistoryIndex(int pointIndex) {
    return _historyStore.valuesAt(pointIndex, _parserType, _parserConfig);
  }

  double _rawHistoryValueAt(int pointIndex, int channelIndex) {
    return _historyStore.valueAt(
      pointIndex,
      channelIndex,
      _parserType,
      _parserConfig,
    );
  }

  void _appendReadyLodPoint(int currentPointIndex, List<double> currentValues) {
    // 速率测试可只推进计数器而不构造历史；生产采集始终连续。保留该
    // 测试入口的 LOD 长度语义，同时不让虚拟缺口触发历史随机读取。
    if (currentPointIndex != _historyPointCount - 1) {
      _historyStore.addSampledLod(
        currentPointIndex,
        currentValues,
        _lodSampleStep,
      );
      return;
    }
    final enabled = enabledMathChannels;
    if (enabled.isEmpty) {
      _historyStore.addSampledLod(
        currentPointIndex,
        currentValues,
        _lodSampleStep,
      );
      return;
    }
    final futureLookahead = _mathEngine.futureLookahead(enabled);
    final readyIndex = currentPointIndex - futureLookahead;
    if (readyIndex < 0 || readyIndex >= _historyPointCount) return;
    final rawValues = _rawValuesAtHistoryIndex(readyIndex);

    final lodValues = List<double>.filled(
      PlotLodIndex.maxChannels,
      double.nan,
      growable: false,
    );
    for (
      var i = 0;
      i < rawValues.length && i < PlotConfiguration.rawChannelCount;
      i++
    ) {
      lodValues[i] = rawValues[i];
    }
    for (final channel in enabled) {
      lodValues[PlotConfiguration.rawChannelCount + channel.index] = _mathEngine
          .evaluateAt(
            channelIndex: channel.index,
            currentIndex: readyIndex,
            pointCount: _historyPointCount,
            valueAt: _rawHistoryValueAt,
          );
    }
    _historyStore.addSampledLod(readyIndex, lodValues, _lodSampleStep);
  }

  @visibleForTesting
  void ingestParsedResultForTest(ParseResult result) {
    _onParseResult(result);
  }

  @visibleForTesting
  void ingestParsedResultForTestAt(ParseResult result, DateTime receivedAt) {
    _onParseResult(result, receivedAt: receivedAt);
  }

  @visibleForTesting
  void debugSetParsedHistoryForExportTest({
    required int pointCount,
    required int channelCount,
  }) {
    _parserType = ParserType.fireWater;
    _nextIndex = pointCount;
    _historyStore.debugSetParsedLength(
      pointCount,
      maxChannelCount: channelCount,
    );
  }

  @visibleForTesting
  void setPlottingForTest(bool value) {
    if (value && !_isPlotting) {
      _activeDiscardInitialPacketLimit = _discardInitialPacketCount;
      _discardedInitialPacketCount = 0;
      _resetTriggerRuntimeState();
    }
    _sessionController.debugSetRunning(value);
  }

  @visibleForTesting
  void recordRateSampleForTest(int pointIndex, int timestampMs) {
    _startTime ??= DateTime.now().subtract(Duration(milliseconds: timestampMs));
    if (pointIndex >= _nextIndex) {
      _nextIndex = pointIndex + 1;
    }
    _recordRateSample(pointIndex, timestampMs);
  }

  /// 处理解析器输出的数据包
  ///
  /// 每包数据都处理（不丢失），但 UI 刷新按 [_notifyBatchSize] 批量触发：
  /// - 追加到协议对应的全量历史缓存
  /// - 必要时添加到当前窗口，超限时从头部批量移除
  /// - 更新速率统计样本
  /// - 更新实际通道数
  /// - 跟随模式下自动平移视口
  /// - 批量计数达到阈值或 fallback 定时器到期时触发 notifyListeners()
  void _onParseResult(
    ParseResult result, {
    DateTime? receivedAt,
    bool updateFollowViewport = true,
  }) {
    if (!result.success || result.values == null || result.values!.isEmpty) {
      return;
    }

    if (_discardedInitialPacketCount < _activeDiscardInitialPacketLimit) {
      _discardedInitialPacketCount++;
      return;
    }

    _validateRetainedAutoChannelCount(result.values!.length);
    if (!_canAcceptPlotPoint(result)) return;

    final now = receivedAt ?? DateTime.now();
    final timestamp =
        _startTime != null
            ? now.difference(_startTime!).inMilliseconds.toDouble()
            : 0.0;

    final pointIndex = _nextIndex++;
    final point = PlotDataPoint(
      index: pointIndex,
      timestamp: timestamp,
      values: result.values!,
    );
    _recordObservedValues(point.values);

    final historyValues = _historyStore.appendResult(result, _parserType);
    final visiblePoint = PlotDataPoint(
      index: point.index,
      timestamp: point.timestamp,
      values: historyValues,
    );
    _appendReadyLodPoint(point.index, point.values);
    _updatePlotRetentionWarning();

    final appendToVisibleWindow = _isViewingTail || _followEnabled;
    if (appendToVisibleWindow) {
      _windowProvider.append(visiblePoint);
      _trimVisibleWindowToLimit();
      _dataRevision++;
    }

    // 统计接收字节数
    _totalReceivedBytes += result.bytesConsumed;

    // 记录速率统计样本
    _recordRateSample(_nextIndex - 1, timestamp.toInt());

    // 更新实际通道数。JustFloat 自动识别模式下以最新有效帧为准，
    // 避免上一帧较多通道遗留的偏置轴继续显示。
    //
    // 其它协议仍取运行期内最大通道数，因为这些协议的通道布局通常不会
    // 在同一轮绘图中变短；取最大值能避免偶发短帧导致通道面板闪烁。
    final nextActiveChannelCount =
        _parserType == ParserType.justFloat && _parserConfig.channelCount == 0
            ? point.channelCount
            : (point.channelCount > _activeChannelCount
                ? point.channelCount
                : _activeChannelCount);
    if (nextActiveChannelCount != _activeChannelCount) {
      _activeChannelCount = nextActiveChannelCount;
      _markChannelConfigChanged();
    }

    _handleTriggerForPoint(point, now);

    // 自动跟随最新数据（仅跟随模式开启时）
    if (updateFollowViewport &&
        _isPlotting &&
        _followEnabled &&
        _dataPoints.length > 1) {
      final lastIndex = _dataPoints.last.index;
      _setViewport(_followViewportForLatestIndex(lastIndex.toDouble()));
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
      // 兜底定时器：确保即使数据流中断也能刷新 UI。
      final delayMs = (1000 / effectiveRefreshFps).round();
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
    return _historyStore.pointCount(_parserType);
  }

  void _trimVisibleWindowToLimit() {
    _windowProvider.trimToLimit(
      limit: effectiveMaterializedPointLimit,
      trimBatchSize: _visibleTrimBatchSize,
    );
  }

  void _cancelWindowLoad() {
    _windowProvider.cancelLoad();
  }

  void _commitMaterializedWindow(int start, List<PlotDataPoint> points) {
    _windowProvider.replaceSynchronously(start, points);
  }

  void _loadWindowForViewport({bool force = false}) {
    final total = _historyPointCount;
    if (total <= 0) return;
    _windowProvider.loadViewport(
      xMin: viewport.xMin,
      xMax: viewport.xMax,
      total: total,
      materializedPointLimit: effectiveMaterializedPointLimit,
      allocatedBytes: _estimatedPlotAllocatedBytes,
      retentionLimitBytes: _plotRetentionLimitBytes,
      valuesAt:
          (pointIndex) =>
              _historyStore.valuesAt(pointIndex, _parserType, _parserConfig),
      force: force,
    );
  }

  void _loadTailWindow() {
    final total = _historyPointCount;
    if (total <= 0) return;
    _windowProvider.loadTail(
      total: total,
      materializedPointLimit: effectiveMaterializedPointLimit,
      allocatedBytes: _estimatedPlotAllocatedBytes,
      retentionLimitBytes: _plotRetentionLimitBytes,
      valuesAt:
          (pointIndex) =>
              _historyStore.valuesAt(pointIndex, _parserType, _parserConfig),
    );
  }

  Future<void> _rebuildParsedWindow(int start, int count) {
    return _rebuildHistoryWindowAsync(start, count);
  }

  Future<void> _rebuildZobowWindowAsync(
    int start,
    int count, {
    PlotImportProgressCallback? onProgress,
  }) {
    return _rebuildHistoryWindowAsync(start, count, onProgress: onProgress);
  }

  Future<void> _rebuildHistoryWindowAsync(
    int start,
    int count, {
    PlotImportProgressCallback? onProgress,
  }) async {
    final points = <PlotDataPoint>[];
    _resetObservedValueMetadata();

    const batchSize = 4096;
    for (var offset = 0; offset < count; offset++) {
      final pointIndex = start + offset;
      final values = _historyStore.valuesAt(
        pointIndex,
        _parserType,
        _parserConfig,
      );
      _recordObservedValues(values);
      points.add(
        PlotDataPoint(
          index: pointIndex,
          timestamp: pointIndex.toDouble(),
          values: values,
        ),
      );
      if ((offset + 1) % batchSize == 0 || offset + 1 == count) {
        onProgress?.call(
          PlotImportProgress(
            stage: '刷新绘图窗口',
            current: offset + 1,
            total: count,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }
    }
    _commitMaterializedWindow(start, points);
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

  // ========== 发送协议启动初始化 ==========

  /// 绘图启动时按当前发送协议发送初始化数据。
  ///
  /// 接收协议由 `_createParser` 创建对应解析器；发送协议只负责在数据源
  /// 启动前编码并发送设备初始化命令，两者保持独立。
  /// 返回是否发送成功，发送失败会阻止本次绘图启动。
  Future<bool> _sendProtocolInitData() async {
    final PlotProtocolInitializationResult result;
    switch (effectiveSendProtocolType) {
      case SendProtocolType.none:
        return true;
      case SendProtocolType.zobowBuiltIn:
        result = await _protocolInitializer.initialize(
          protocol: zobowDeviceSendProtocol,
          config: ZobowDeviceProtocolInitializationConfig(
            _parserConfig.zobowChannelIds
                .take(_parserConfig.zobowChannelCount)
                .toList(),
          ),
        );
        break;
      case SendProtocolType.rProtocol:
        result = await _protocolInitializer.initialize(
          protocol: rSendProtocol,
          config: RProtocolInitializationConfig(
            addresses: _normalizedRProtocolAddressesForStartup(),
            requiredChannelCount:
                _rProtocolLooseChannelSettings
                    ? null
                    : _fixedReceiveChannelCount,
            loose: _rProtocolLooseChannelSettings,
          ),
        );
        break;
    }
    _protocolInitFailureMessage = result.failureMessage;
    return result.succeeded;
  }

  List<String> _normalizedRProtocolAddressesForStartup() {
    if (!_rProtocolLooseChannelSettings) {
      return _sendProtocolConfig.rChannelAddresses;
    }
    final compacted = rSendProtocol.compactAddresses(
      _sendProtocolConfig.rChannelAddresses,
    );
    var changed =
        compacted.length != _sendProtocolConfig.rChannelAddresses.length;
    if (!changed) {
      for (var i = 0; i < compacted.length; i++) {
        if (compacted[i] != _sendProtocolConfig.rChannelAddresses[i]) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      _sendProtocolConfig.rChannelAddresses = compacted;
      _markChannelConfigChanged();
      _saveSettings();
    }
    return _sendProtocolConfig.rChannelAddresses;
  }

  int _rContinuousAddressCount({bool throwOnGap = true}) {
    return rSendProtocol.continuousAddressCount(
      _sendProtocolConfig.rChannelAddresses,
      throwOnGap: throwOnGap,
    );
  }

  int _rConfiguredAddressCount() {
    return rSendProtocol.configuredAddressCount(
      _sendProtocolConfig.rChannelAddresses,
    );
  }

  void _resetZobowRawFrameBuffer() {
    _historyStore.resetZobowFrames(
      ZobowParser.frameLengthForConfig(_parserConfig),
    );
  }

  void _resetFixedFrameRawFrameBuffer() {
    _historyStore.resetFixedFrames(_parserConfig.totalFrameLength);
  }

  // ========== x-x / y-y 光标控制 ==========
  /// 设置 X1 光标位置（拖动时使用）
  ///
  /// 同时保留 xCursor2 和 yCursor2，避免拖动时覆盖另一组测量线。
  List<SnapHighlightPoint> _snapHighlightsForX(double x, Color color) {
    if (!viewport.isVisibleX(x)) return const [];
    final point = _nearestVisiblePointByX(x);
    if (point == null) return const [];
    final highlights = <SnapHighlightPoint>[];
    final currentChannels = displayChannels;
    for (
      int i = 0;
      i < point.values.length && i < currentChannels.length;
      i++
    ) {
      final channel = currentChannels[i];
      if (!channel.visible) continue;
      if (!point.values[i].isFinite) continue;
      highlights.add(
        SnapHighlightPoint(
          x: point.index.toDouble(),
          y: point.values[i] * channel.yScale + channel.yOffset,
          color: _snapHighlightColor(channel, color),
        ),
      );
    }
    return highlights;
  }

  List<SnapHighlightPoint> _snapHighlightForY(double y, Color color) {
    final points = displayDataPoints;
    if (points.isEmpty) return const [];
    const maxScanPoints = 4096;
    final range = _dataPointRangeByX(viewport.xMin, viewport.xMax);
    if (range == null) return const [];
    final visibleCount = range.end - range.start;
    final step = (visibleCount / maxScanPoints).ceil().clamp(1, visibleCount);

    SnapHighlightPoint? best;
    var bestDistance = double.infinity;
    void visit(PlotDataPoint point) {
      final currentChannels = displayChannels;
      for (
        int i = 0;
        i < point.values.length && i < currentChannels.length;
        i++
      ) {
        final channel = currentChannels[i];
        if (!channel.visible) continue;
        if (!point.values[i].isFinite) continue;
        final pointY = point.values[i] * channel.yScale + channel.yOffset;
        final distance = (pointY - y).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = SnapHighlightPoint(
            x: point.index.toDouble(),
            y: pointY,
            color: _snapHighlightColor(channel, color),
          );
        }
      }
    }

    for (int i = range.start; i < range.end; i += step) {
      visit(points[i]);
    }
    if (step > 1) visit(points[range.end - 1]);
    return best == null ? const [] : [best!];
  }

  List<SnapHighlightPoint> _observationSnapHighlights() {
    final highlights = <SnapHighlightPoint>[];
    for (final observation in _observations) {
      final values = observation.channelValues;
      if (!observation.hasData || values == null) continue;
      final currentChannels = displayChannels;
      for (int i = 0; i < values.length && i < currentChannels.length; i++) {
        final channel = currentChannels[i];
        if (!channel.visible) continue;
        if (!values[i].isFinite) continue;
        highlights.add(
          SnapHighlightPoint(
            x: observation.x,
            y: values[i] * channel.yScale + channel.yOffset,
            color: _snapHighlightColor(channel, Colors.amber),
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

  Color _snapHighlightColor(ChannelConfig channel, Color cursorColor) {
    return _snapHighlightColorMode == 'channel' ? channel.color : cursorColor;
  }

  void _refreshSnapHighlightColors() {
    if (_xCursor1 != null) {
      _xCursor1SnapHighlights = _snapHighlightsForX(_xCursor1!, Colors.cyan);
    }
    if (_xCursor2 != null) {
      _xCursor2SnapHighlights = _snapHighlightsForX(_xCursor2!, Colors.yellow);
    }
    if (_yCursor1 != null) {
      _yCursor1SnapHighlights = _snapHighlightForY(_yCursor1!, Colors.cyan);
    }
    if (_yCursor2 != null) {
      _yCursor2SnapHighlights = _snapHighlightForY(_yCursor2!, Colors.yellow);
    }
  }

  void _notifyLater() {
    Future.microtask(() => notifyListeners());
  }

  void _resetCursorPositions() {
    _cursor = null;
    _observations.clear();
    _observationPlacementActive = false;
    _observationPreview = null;
    _xMeasurementEnabled = false;
    _yMeasurementEnabled = false;
    _statsEnabled = false;
    _statsRangeEnabled = false;
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _statsX1 = null;
    _statsX2 = null;
    _clearSnapHighlights();
    _markOverlayChanged();
  }

  void setXCursor1(double x) {
    _xCursor1 = _snapXToNearestVisiblePoint(x);
    _xCursor1SnapHighlights = _snapHighlightsForX(_xCursor1!, Colors.cyan);
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 X2 光标位置（拖动时使用）
  void setXCursor2(double x) {
    _xCursor2 = _snapXToNearestVisiblePoint(x);
    _xCursor2SnapHighlights = _snapHighlightsForX(_xCursor2!, Colors.yellow);
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y1 光标位置（拖动时使用）
  void setYCursor1(double y) {
    _yCursor1 = y;
    _yCursor1SnapHighlights = _snapHighlightForY(y, Colors.cyan);
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y2 光标位置（拖动时使用）
  void setYCursor2(double y) {
    _yCursor2 = y;
    _yCursor2SnapHighlights = _snapHighlightForY(y, Colors.yellow);
    _markOverlayChanged();
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
    _markOverlayChanged();
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
    final currentChannels = displayChannels;
    if (!_statsEnabled || _historyPointCount == 0) return null;

    final xMin =
        _statsRangeEnabled && _statsX1 != null && _statsX2 != null
            ? (_statsX1! < _statsX2! ? _statsX1! : _statsX2!)
            : viewport.xMin;
    final xMax =
        _statsRangeEnabled && _statsX1 != null && _statsX2 != null
            ? (_statsX1! > _statsX2! ? _statsX1! : _statsX2!)
            : viewport.xMax;
    final visibleChannelKey =
        currentChannels.map((channel) => channel.visible ? '1' : '0').join();
    final cacheKey =
        '$_dataRevision|$_channelConfigRevision|$xMin|$xMax|'
        '$_statsRangeEnabled|$visibleChannelKey|$_activeChannelCount';
    if (_cachedStatsKey == cacheKey) return _cachedStatsText;

    final rangeStart = math.max(0, xMin.ceil());
    final rangeEnd = math.min(_historyPointCount - 1, xMax.floor());
    if (rangeStart > rangeEnd) {
      _cachedStatsKey = cacheKey;
      _cachedStatsText = null;
      return null;
    }

    final buffer = StringBuffer();
    final result = _statisticsCalculator.calculate(
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      channelCount: currentChannels.length,
      isChannelVisible: (index) => currentChannels[index].visible,
      valuesAt: (index) => _displayPointAtHistoryIndex(index)?.values,
    );
    final statPrefix = result.approximate ? '约' : '';

    var hasVisibleChannel = false;
    for (var i = 0; i < currentChannels.length; i++) {
      final channelStats = result.channels[i];
      if (channelStats == null) continue;
      if (hasVisibleChannel) buffer.writeln('---');
      hasVisibleChannel = true;

      final name =
          currentChannels[i].alias.isNotEmpty
              ? currentChannels[i].alias
              : 'Ch$i';
      buffer.writeln('$name:');
      buffer.writeln(
        '  Max: $statPrefix${_formatDisplayNumber(channelStats.maximum)}',
      );
      buffer.writeln(
        '  Min: $statPrefix${_formatDisplayNumber(channelStats.minimum)}',
      );
      buffer.writeln(
        '  Avg: $statPrefix${_formatDisplayNumber(channelStats.average)}',
      );
    }

    if (!hasVisibleChannel) {
      _cachedStatsKey = cacheKey;
      _cachedStatsText = null;
      return null;
    }

    // 统一显示 N 和 Range
    buffer.writeln('---');
    buffer.writeln('N: ${result.rangePointCount}');
    if (result.approximate) {
      buffer.writeln('Mode: 约 ${result.sampleLimit} samples');
    }
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

  @override
  void dispose() {
    _disposed = true;
    _windowProvider.dispose();
    _cancelPendingDragViewportNotification();
    unawaited(_sessionController.dispose());
    _resetRateState();
    serialService.releaseActivity(SerialActivityOwner.plot);
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _pendingNotifyCount = 0;
    _stopRefreshTimer();
    super.dispose();
  }
}
