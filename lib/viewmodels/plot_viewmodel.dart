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
import '../core/utils/crc.dart';
import '../core/utils/math_expression.dart';
import '../core/utils/plot_value_formatter.dart';
import '../core/utils/plot_performance_metrics.dart';
import '../data/models/channel_config.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/data_source_config.dart';
import '../data/models/math_channel_config.dart';
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
import '../data/models/address_config_profile.dart';
import '../services/app_notifications.dart';
import '../services/app_settings.dart';
import '../services/serial_service.dart';
import '../services/address_profile_service.dart';
import '../views/plot/plot_painter.dart';
import '../views/plot/plot_viewport.dart';
import 'base_viewmodel.dart';

part 'plot_viewmodel/plot_import_export.dart';
part 'plot_viewmodel/plot_profiles.dart';
part 'plot_viewmodel/plot_support_models.dart';

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
/// - 文本/浮点协议的历史值进入 `_parsedHistory`，按视口重建窗口。
/// - Zobow/FixedFrame 的历史以原始固定帧保存，导出和回看都能复用原始字节。
/// - `_lodIndex` 始终跟随全量历史更新，用于大范围拖动/缩放时快速预览。
///
/// UI 刷新：通过 notifyListeners() 驱动 Consumer[PlotViewModel] 重建。
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
  static const int maxObservationCount = PlotConfiguration.maxObservationCount;
  static const int minVisiblePoints = PlotConfiguration.minVisiblePointCount;
  static const int defaultVisiblePoints =
      PlotConfiguration.defaultVisiblePointCount;
  static const int maxVisiblePointsLimit =
      PlotConfiguration.maxVisiblePointCount;
  static const int maxDiscardInitialPacketCount =
      PlotConfiguration.maxDiscardInitialPacketCount;
  int _maxVisiblePoints = defaultVisiblePoints;
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

  /// 众邦电控有效原始帧缓存（本次运行内全量保留）。
  ///
  /// 固定帧类协议需要支持基于原始帧导出，并且能在视口变化时按帧序号
  /// 重新解析窗口数据，因此不只保存解析后的 double 值。
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
  final Map<int, MathExpression> _compiledMathExpressions = {};
  int _nextOffsetBindingGroupId = 1;
  List<PlotDataPoint>? _cachedDisplayDataPoints;
  String? _cachedDisplayDataKey;
  List<ChannelConfig>? _cachedDisplayChannels;
  String? _cachedDisplayChannelKey;
  List<int>? _importedChannelAddresses;
  List<ChannelPresetBinding> _channelPresetBindings = [];
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
  final List<PlotDataPoint> _triggerHitPoints = [];
  double? _triggerPreviousValue;
  int _triggerHitCount = 0;
  int _triggeredCount = 0;
  int? _triggerStopPacketsRemaining;
  bool _triggerStopRequested = false;
  bool _triggerConfigured = false;

  /// 当前解析器类型
  ParserType _parserType = ParserType.fireWater;

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
    final byRatio = (_maxVisiblePoints / 32).round();
    return byRatio.clamp(4096, 65536).toInt();
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
  PlotViewModel(super.serialService) {
    _sourceManager = DataSourceManager(serialService);
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
    Future.microtask(() {
      if (!_disposed) notifyListeners();
    });
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
    final expression = _compiledMathExpressions[channel.index];
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
  int get triggerHitCount => _triggerHitCount;
  int get triggeredCount => _triggeredCount;
  int? get triggerStopPacketsRemaining => _triggerStopPacketsRemaining;
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
  PlotLodIndex get lodIndex => _lodIndex;
  int get zobowRawFrameCount => _zobowRawFrames.packetCount;

  /// 本次绘图接收到的数据点总数
  int get pointCount => _nextIndex;
  int? get minJumpXIndex => _nextIndex > 0 ? 0 : null;
  int? get maxJumpXIndex => _nextIndex > 0 ? _nextIndex - 1 : null;

  /// 当前窗口中的数据点数量
  int get visiblePointCount => _dataPoints.length;

  /// 当前窗口起始点序号
  int get visibleStartIndex => _visibleStartIndex;

  /// 当前窗口点数上限
  int get maxVisiblePoints => _maxVisiblePoints;

  int get effectiveMaxVisiblePoints => _maxVisiblePoints;

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
      _parsedHistory.allocatedValueSlots;

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

  int get _visibleEndIndex => _visibleStartIndex + _dataPoints.length;

  void _invalidateDisplayCaches() {
    _cachedDisplayDataPoints = null;
    _cachedDisplayDataKey = null;
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
    final value = parseRProtocolAddress(text);
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

  int get _mathDisplayFutureLookahead {
    var lookahead = 0;
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      final expression = _compiledMathExpressions[channel.index];
      if (expression == null) continue;
      if (expression.futureLookahead > lookahead) {
        lookahead = expression.futureLookahead;
      }
    }
    return lookahead;
  }

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
    _compiledMathExpressions.clear();
    for (final channel in mathChannels) {
      _compileMathChannel(channel);
    }
    _invalidateDisplayCaches();
    if (save) _saveSettings();
  }

  void _compileMathChannel(MathChannelConfig channel) {
    _compiledMathExpressions.remove(channel.index);
    if (!channel.enabled || channel.expression.trim().isEmpty) return;
    try {
      _compiledMathExpressions[channel.index] = MathExpression.parse(
        channel.expression,
      );
    } catch (_) {
      // 表达式语法错误时保持通道启用，但运行时显示为无效点。
    }
  }

  double _evaluateMathChannel(
    MathChannelConfig channel,
    int pointPosition,
    List<PlotDataPoint> sourcePoints,
  ) {
    final expression = _compiledMathExpressions[channel.index];
    if (expression == null) return double.nan;
    return expression.evaluateWithContext(
      MathEvalContext(
        currentIndex: pointPosition,
        pointCount: sourcePoints.length,
        valueAt: (pointIndex, channelIndex) {
          if (pointIndex < 0 || pointIndex >= sourcePoints.length) {
            return double.nan;
          }
          final values = sourcePoints[pointIndex].values;
          if (channelIndex < 0 || channelIndex >= values.length) {
            return double.nan;
          }
          return values[channelIndex];
        },
      ),
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
    _sourceManager.updateConfig(_sourceConfig);
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

    Future.microtask(() => notifyListeners());
  }

  /// 设置随机源频率（Hz），范围 1~100000
  void setRandomFrequency(double hz) {
    final clampedHz = hz.roundToDouble().clamp(1.0, 100000.0);
    if (_sourceConfig.randomFrequencyHz == clampedHz) return;
    final intervalMs = (1000.0 / clampedHz).round().clamp(1, 1000).toInt();
    _sourceConfig.randomFrequencyHz = clampedHz;
    _sourceConfig.randomIntervalMs = intervalMs;
    _sourceManager.updateConfig(_sourceConfig);
    _saveSettings();
    AppLogger().info(
      '随机源频率设置为 ${clampedHz.toInt()} Hz，生成间隔=${intervalMs}ms',
      category: 'PLOT',
    );

    // 如果正在绘图，重启数据源以应用新频率
    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
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
    _sourceManager.updateConfig(_sourceConfig);
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
    if (!_isPlotting && !_isStopping) return true;
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
  Future<void> startPlotting() async {
    if (_isStopping) {
      showStatusMessage('正在停止绘图，请稍候', duration: const Duration(seconds: 1));
      return;
    }
    if (_isPlotting) return;
    AppLogger().info(
      '用户请求开始绘图：接收协议=${_parserType.label}，发送协议=${effectiveSendProtocolType.label}，'
      '串口连接=${serialService.isConnected}，随机源=$_useRandomSource，'
      '随机频率=${_sourceConfig.randomFrequencyHz.toInt()}Hz，丢弃前置包=$_discardInitialPacketCount',
      category: 'PLOT',
    );

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
      if (!serialService.isConnected) {
        const message = '串口未连接，无法绘图；请连接串口或启用随机源';
        showStatusMessage(message);
        AppLogger().warning(message, category: 'PLOT');
        return;
      }
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
    AppLogger().info(
      '绘图数据源确认：串口=${_sourceConfig.useSerial}，随机源=${_sourceConfig.useRandom}',
      category: 'PLOT',
    );

    _prepareHistoryForStart();

    // 创建解析器
    _parser = _createParser();

    // 发送协议初始化数据（如果有）。初始化失败时不能继续启动绘图，
    // 否则串口物理断开后会进入“看似绘图中但没有数据”的错误状态。
    _protocolInitFailureMessage = null;
    if (!_sendProtocolInitData()) {
      _parser?.dispose();
      _parser = null;
      _sourceConfig.useSerial = false;
      _sourceConfig.useRandom = false;
      serialService.isPlotting = false;
      final message = _protocolInitFailureMessage ?? '协议初始化失败，已停止绘图';
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

    // 连接数据源 → 解析器 → 数据缓冲区。
    // 一个原始字节块内的多帧结果直接批量消费，避免每包经过一次 Stream 调度。
    _parseSubscription = _sourceManager.byteStream.listen(
      (data) {
        final parser = _parser;
        if (parser == null) return;
        final results = parser.feedBatch(data);
        if (results.isEmpty) return;
        final receivedAt = DateTime.now();
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
      onError: (error) {
        AppLogger().error('数据源错误: $error', category: 'PLOT');
      },
    );

    // 开始绘图时自动停止原始数据接收
    if (serialService.isRawReceiving) {
      serialService.stopRawReceiving();
    }
    Future.microtask(() => serialService.notifyListeners());
    _startRefreshTimer();
    AppLogger().info('开始绘图', category: 'PLOT');
    showStatusMessage('开始绘图', duration: const Duration(seconds: 1));
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
    if (!_isPlotting) {
      _resetRateState();
      return Future.value();
    }

    _isStopping = true;
    _isPlotting = false;
    _resetRateState();
    serialService.isPlotting = false;
    AppLogger().info(
      '用户请求停止绘图：已接收点=$_nextIndex，当前显示点=${_dataPoints.length}',
      category: 'PLOT',
    );
    // 停止绘图后保持定时刷新，确保交互响应及时
    _startRefreshTimer();
    showStatusMessage('正在停止绘图...', duration: const Duration(seconds: 1));
    Future.microtask(() => serialService.notifyListeners());
    Future.microtask(() => notifyListeners());

    _stopFuture = Future<void>(() async {
      try {
        await _parseSubscription?.cancel();
        _parseSubscription = null;
        _sourceManager.stop();
        _parser?.dispose();
        _parser = null;
      } catch (e) {
        AppLogger().error('停止绘图清理失败: $e', category: 'PLOT');
      } finally {
        _notifyTimer?.cancel();
        _notifyTimer = null;
        _pendingNotifyCount = 0;
        _isStopping = false;
        if (_triggerConfig.enabled) {
          _triggerConfig.enabled = false;
        }
        _resetTriggerRuntimeState();
        if (!_disposed) {
          showStatusMessage('已停止绘图', duration: const Duration(seconds: 1));
          AppLogger().info(
            '绘图已停止：总点数=$_nextIndex，Zobow原始帧=${_zobowRawFrames.packetCount}，'
            '固定帧原始帧=${_fixedFrameRawFrames.packetCount}',
            category: 'PLOT',
          );
          Future.microtask(() {
            if (!_disposed) notifyListeners();
          });
        }
      }
    }).whenComplete(() {
      _stopFuture = null;
    });
    return _stopFuture!;
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

  /// 重启绘图（用于配置变更时）
  void _restartPlotting() {
    AppLogger().info('配置变更触发绘图重启', category: 'PLOT');
    stopPlotting().then((_) {
      if (!_disposed) unawaited(startPlotting());
    });
  }

  /// 清空所有数据、速率统计、视口和光标
  void clearData() {
    AppLogger().info(
      '用户清空绘图数据：清空前总点数=$_nextIndex，显示点=${_dataPoints.length}',
      category: 'PLOT',
    );
    _dataPoints.clear();
    _parsedHistory.clear();
    _lodIndex.clear();
    _zobowRawFrames.clear();
    _fixedFrameRawFrames.clear();
    _importedChannelAddresses = null;
    _visibleStartIndex = 0;
    _dataRevision++;
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();
    _resetRateState();
    _nextIndex = 0;
    _activeChannelCount = 0;
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
        const message = '接收协议已变化，已清空不兼容的历史绘图数据';
        AppLogger().warning(message, category: 'PLOT');
        showStatusMessage(message);
      }
      // 清空旧数据。这里必须同时清理窗口、全量历史、LOD 和原始帧缓存；
      // 它们分别服务于绘制、回看、预览和导出，缺一项都会留下上一轮状态。
      _dataPoints.clear();
      _parsedHistory.clear();
      _lodIndex.clear();
      _zobowRawFrames.clear();
      _fixedFrameRawFrames.clear();
      _importedChannelAddresses = null;
      _visibleStartIndex = 0;
      _dataRevision++;
      _invalidateDisplayCaches();
      _resetObservedValueMetadata();
      _nextIndex = 0;
      _activeChannelCount = 0;

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
    } else {
      _importedChannelAddresses = null;
      _hasStartedPlottingOnce = true;
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
    return switch (_parserType) {
      ParserType.fireWater || ParserType.justFloat =>
        _parsedHistory.length == _nextIndex &&
            _zobowRawFrames.isEmpty &&
            _fixedFrameRawFrames.isEmpty,
      ParserType.zobow =>
        _zobowRawFrames.packetCount == _nextIndex &&
            _parsedHistory.isEmpty &&
            _fixedFrameRawFrames.isEmpty,
      ParserType.fixedFrame =>
        _fixedFrameRawFrames.packetCount == _nextIndex &&
            _parsedHistory.isEmpty &&
            _zobowRawFrames.isEmpty,
    };
  }

  // ========== 数据接收 ==========
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
    _parsedHistory.debugSetLengthForTest(
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
    _isPlotting = value;
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

    final now = receivedAt ?? DateTime.now();
    final timestamp =
        _startTime != null
            ? now.difference(_startTime!).inMilliseconds.toDouble()
            : 0.0;

    final point = PlotDataPoint(
      index: _nextIndex++,
      timestamp: timestamp,
      values: result.values!,
    );
    _recordObservedValues(point.values);

    // 历史缓存按协议分流：
    // - Zobow/FixedFrame 保留原始帧，导出和视口重建都从原始帧重新解析。
    // - 其他协议只保存解析后的紧凑 double 块，降低大数据量下的对象开销。
    var visiblePoint = point;
    if (_parserType == ParserType.zobow && result.rawBytes != null) {
      _zobowRawFrames.appendPacket(result.rawBytes!);
    } else if (_parserType == ParserType.fixedFrame &&
        result.rawBytes != null) {
      _fixedFrameRawFrames.appendPacket(result.rawBytes!);
    } else {
      final historyIndex = _parsedHistory.length;
      _parsedHistory.add(point.values);
      visiblePoint = PlotDataPoint(
        index: point.index,
        timestamp: point.timestamp,
        values: _ParsedHistoryValues(_parsedHistory, historyIndex),
      );
    }
    _lodIndex.addSampled(point.index, point.values, _lodSampleStep);

    final appendToVisibleWindow = _isViewingTail || _followEnabled;
    if (appendToVisibleWindow) {
      _dataPoints.add(visiblePoint);
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
    if (_parserType == ParserType.zobow) return _zobowRawFrames.packetCount;
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return _fixedFrameRawFrames.packetCount;
    }
    return _parsedHistory.length;
  }

  void _trimVisibleWindowToLimit() {
    final limit = effectiveMaxVisiblePoints;
    final trimThreshold = limit + _visibleTrimBatchSize;
    if (_dataPoints.length <= trimThreshold) {
      _visibleStartIndex = _dataPoints.isEmpty ? 0 : _dataPoints.first.index;
      return;
    }

    final removeCount = _dataPoints.length - limit;
    _dataPoints.removeRange(0, removeCount);
    _visibleStartIndex = _dataPoints.first.index;
  }

  void _loadZobowWindowForViewport({bool force = false}) {
    if (_parserType != ParserType.zobow || _zobowRawFrames.isEmpty) return;

    var start =
        viewport.xMin.floor().clamp(0, _zobowRawFrames.packetCount).toInt();
    var end =
        viewport.xMax.ceil().clamp(start, _zobowRawFrames.packetCount).toInt();
    final limit = effectiveMaxVisiblePoints;
    if (end - start > limit) {
      end = start + limit;
      _setViewport(
        viewport.copyWith(xMin: start.toDouble(), xMax: end.toDouble()),
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
    final limit = effectiveMaxVisiblePoints;
    if (end - start > limit) {
      end = start + limit;
      _setViewport(
        viewport.copyWith(xMin: start.toDouble(), xMax: end.toDouble()),
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
    final limit = effectiveMaxVisiblePoints;
    if (end - start > limit) {
      end = start + limit;
      _setViewport(
        viewport.copyWith(xMin: start.toDouble(), xMax: end.toDouble()),
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
        final count =
            _parsedHistory.length.clamp(0, effectiveMaxVisiblePoints).toInt();
        final start = _parsedHistory.length - count;
        _rebuildParsedWindow(start, count);
        break;
      case ParserType.fixedFrame:
        if (_fixedFrameRawFrames.isNotEmpty) {
          _loadFixedFrameTailWindow();
        } else {
          final count =
              _parsedHistory.length.clamp(0, effectiveMaxVisiblePoints).toInt();
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
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();
    if (count <= 0) return;

    for (int i = 0; i < count; i++) {
      final pointIndex = start + i;
      final values = _ParsedHistoryValues(_parsedHistory, pointIndex);
      _recordObservedValues(values);
      _dataPoints.add(
        PlotDataPoint(
          index: pointIndex,
          timestamp: pointIndex.toDouble(),
          values: values,
        ),
      );
    }
  }

  void _loadZobowTailWindow() {
    if (_parserType != ParserType.zobow || _zobowRawFrames.isEmpty) return;
    final count =
        _zobowRawFrames.packetCount.clamp(0, effectiveMaxVisiblePoints).toInt();
    final start = _zobowRawFrames.packetCount - count;
    _rebuildZobowWindow(start, count);
  }

  void _rebuildZobowWindow(int start, int count) {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();

    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _zobowRawFrames.readPacket(packetIndex);
      final values = ZobowParser.decodeFrameValues(frame, _parserConfig);
      _recordObservedValues(values);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: values,
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
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();

    const batchSize = 4096;
    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _zobowRawFrames.readPacket(packetIndex);
      final values = ZobowParser.decodeFrameValues(frame, _parserConfig);
      _recordObservedValues(values);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: values,
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
    switch (effectiveSendProtocolType) {
      case SendProtocolType.zobowBuiltIn:
        return _sendJackFourChannelInitData();
      case SendProtocolType.rProtocol:
        return _sendRProtocolInitData();
      case SendProtocolType.none:
        return true;
    }
  }

  bool _sendRProtocolInitData() {
    if (!serialService.isConnected) {
      _protocolInitFailureMessage =
          'r协议初始化失败：串口未连接，无法发送初始化命令。'
          '已停止绘图，请重新连接串口后重试。';
      AppLogger().debug(_protocolInitFailureMessage!, category: 'PLOT');
      return false;
    }
    try {
      final bytes = buildRProtocolCommand(
        validateRProtocolAddresses(
          _normalizedRProtocolAddressesForStartup(),
          requiredCount: _fixedReceiveChannelCount,
          loose: _rProtocolLooseChannelSettings,
        ),
      );
      serialService.send(
        bytes,
        displaySource: SendDisplaySource.plot,
        displayAsHex: false,
      );
      AppLogger().info(
        'r协议初始化数据已发送: ${utf8.decode(bytes).trim()}',
        category: 'PLOT',
      );
      return true;
    } on FormatException catch (e) {
      _protocolInitFailureMessage =
          'r协议初始化失败：通道地址配置错误，${e.message}。'
          '请检查地址是否从 Ch0 开始连续填写；空地址会中断发送，0 会按有效地址发送。';
      AppLogger().error('r协议初始化数据配置错误: $e', category: 'PLOT');
      return false;
    } on StateError catch (e) {
      _protocolInitFailureMessage =
          'r协议初始化失败：串口发送失败，${e.message}。'
          '已停止绘图并断开串口，请检查设备连接后重试。';
      AppLogger().error('r协议初始化数据发送失败: $e', category: 'PLOT');
      return false;
    } catch (e) {
      _protocolInitFailureMessage =
          'r协议初始化失败：初始化命令发送异常，$e。'
          '已停止绘图，请检查串口连接和通道地址配置。';
      AppLogger().error('r协议初始化数据发送失败: $e', category: 'PLOT');
      return false;
    }
  }

  List<String> _normalizedRProtocolAddressesForStartup() {
    if (!_rProtocolLooseChannelSettings) {
      return _sendProtocolConfig.rChannelAddresses;
    }
    final compacted = compactRProtocolAddresses(
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
    int count = 0;
    bool foundEmpty = false;
    for (final text in _sendProtocolConfig.rChannelAddresses) {
      final address = text.trim();
      if (address.isEmpty) {
        foundEmpty = true;
        continue;
      }
      final value = parseRProtocolAddress(address);
      if (value == null || value < 0) {
        if (throwOnGap) {
          throw FormatException('r协议地址无效: $text');
        }
        break;
      }
      if (foundEmpty) {
        if (throwOnGap) {
          throw const FormatException('r协议地址必须从 Ch0 开始连续填写，中间不能留空');
        }
        break;
      }
      count++;
    }
    return count;
  }

  static List<String> validateRProtocolAddresses(
    List<String> addresses, {
    int? requiredCount,
    bool loose = false,
  }) {
    if (loose) {
      return validateRProtocolAddresses(compactRProtocolAddresses(addresses));
    }
    if (requiredCount != null) {
      final requiredAddresses =
          addresses.take(requiredCount).map((address) {
            final text = address.trim();
            final value = parseRProtocolAddress(text);
            if (value == null || value < 0) {
              throw FormatException('r协议地址无效或未填写: $address');
            }
            return text;
          }).toList();
      if (requiredAddresses.length < requiredCount) {
        throw FormatException(
          'r协议地址数量不足：接收协议需要 $requiredCount 个通道，'
          '当前仅填写 ${requiredAddresses.length} 个',
        );
      }
      return requiredAddresses;
    }
    final continuousAddresses = <String>[];
    bool foundEmpty = false;
    for (final rawAddress in addresses) {
      final address = rawAddress.trim();
      final value = parseRProtocolAddress(address);
      if (address.isEmpty) {
        foundEmpty = true;
        continue;
      }
      if (value == null || value < 0) {
        throw FormatException('r协议地址无效: $rawAddress');
      }
      if (foundEmpty) {
        throw const FormatException('r协议地址必须从 Ch0 开始连续填写，中间不能留空');
      }
      continuousAddresses.add(address);
    }
    if (continuousAddresses.isEmpty) {
      throw const FormatException('r协议至少需要填写一个通道地址');
    }
    if (requiredCount != null && continuousAddresses.length < requiredCount) {
      throw FormatException(
        'r协议地址数量不足：接收协议需要 $requiredCount 个通道，'
        '当前仅填写 ${continuousAddresses.length} 个',
      );
    }
    return continuousAddresses
        .take(requiredCount ?? continuousAddresses.length)
        .toList();
  }

  int _rConfiguredAddressCount() {
    var count = 0;
    for (final text in _sendProtocolConfig.rChannelAddresses) {
      final address = text.trim();
      if (address.isEmpty) continue;
      final value = parseRProtocolAddress(address);
      if (value == null || value < 0) continue;
      count++;
    }
    return count;
  }

  static List<String> compactRProtocolAddresses(List<String> addresses) {
    final compacted = <String>[];
    for (final rawAddress in addresses) {
      final address = rawAddress.trim();
      if (address.isEmpty) continue;
      final value = parseRProtocolAddress(address);
      if (value == null || value < 0) {
        throw FormatException('r协议地址无效: $rawAddress');
      }
      compacted.add(address);
    }
    if (compacted.isEmpty) {
      throw const FormatException('r协议至少需要填写一个通道地址');
    }
    final limited = compacted.take(SendProtocolConfig.maxChannelCount).toList();
    return [
      ...limited,
      ...List.filled(
        math.max(0, SendProtocolConfig.maxChannelCount - limited.length),
        '',
      ),
    ];
  }

  static int? parseRProtocolAddress(String text) {
    return AddressChannelPreset.tryParseAddress(
      name: '',
      text: text,
      protocolType: AddressProfileProtocolType.rProtocol,
    )?.address;
  }

  static Uint8List buildRProtocolCommand(List<String> addresses) {
    if (addresses.isEmpty) {
      throw ArgumentError.value(addresses, 'addresses', 'must not be empty');
    }
    final normalized = <String>[];
    for (final address in addresses) {
      final text = address.trim();
      final value = parseRProtocolAddress(text);
      if (value == null || value < 0) {
        throw FormatException('无效的 r 协议地址: $address');
      }
      normalized.add(text);
    }
    return Uint8List.fromList(utf8.encode('r ${normalized.join(' ')}\n'));
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
      serialService.send(
        bytes,
        displaySource: SendDisplaySource.plot,
        displayAsHex: true,
      );

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
    // 保存当前的偏移通道列宽，避免 copy() 丢失
    final offsetAxisColumnWidths = viewport.offsetAxisColumnWidths;
    if (!fromDrag) _cancelPendingDragViewportNotification();
    if (fromDrag && _followEnabled) {
      _followEnabled = false;
    }
    if (!fromDrag) {
      _saveViewport();
    }
    _setViewport(_limitXRange(newViewport, previous: viewport).copy());
    viewport.setOffsetAxisColumnWidths(offsetAxisColumnWidths);
    if (!fromDrag) {
      _loadWindowForViewport();
    }
    if (!fromDrag) _refreshSnapHighlightColors();
    if (!fromDrag) {
      _saveSettings();
      AppLogger().trace(
        'updateViewport: xMin=${viewport.xMin.toStringAsFixed(1)} | fromDrag=$fromDrag',
        category: 'PLOT',
      );
    }
    if (fromDrag) {
      _notifyDragViewportAtNextFrame();
    } else {
      Future.microtask(() => notifyListeners());
    }
  }

  /// 拖动结束后保存视口配置
  ///
  /// 在 PlotGestureHandler._handlePointerUp 中调用，将拖动期间的
  /// 最终视口保存到配置和历史记录。
  void saveDragViewport() {
    _cancelPendingDragViewportNotification();
    _saveViewport();
    _loadWindowForViewport();
    _refreshSnapHighlightColors();
    _saveSettings();
    AppLogger().trace(
      'saveDragViewport: xMin=${viewport.xMin.toStringAsFixed(1)}',
      category: 'PLOT',
    );
    Future.microtask(() => notifyListeners());
  }

  /// 指针事件可能高于显示器刷新率；拖动时只在下一帧通知 UI，
  /// 始终使用此帧收到的最新视口，避免主图重绘任务堆积。
  void _notifyDragViewportAtNextFrame() {
    if (_dragViewportNotifyScheduled) return;
    _dragViewportNotifyScheduled = true;
    final generation = _dragViewportNotifyGeneration;
    final SchedulerBinding binding;
    try {
      binding = SchedulerBinding.instance;
    } on FlutterError {
      // 纯 ViewModel 测试不会创建 Flutter binding，保留视口更新语义。
      _dragViewportNotifyScheduled = false;
      notifyListeners();
      return;
    }
    binding.scheduleFrame();
    binding.addPostFrameCallback((_) {
      if (_disposed ||
          generation != _dragViewportNotifyGeneration ||
          !_dragViewportNotifyScheduled) {
        return;
      }
      _dragViewportNotifyScheduled = false;
      notifyListeners();
    });
  }

  void _cancelPendingDragViewportNotification() {
    _dragViewportNotifyGeneration++;
    _dragViewportNotifyScheduled = false;
  }

  /// 重置视口到默认值并保存历史记录
  void resetViewport() {
    _saveViewport();
    _setViewport(viewport.reset());
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 撤回上次缩放
  void undoZoom() {
    if (_viewportHistory.isEmpty) return;
    final previous = _viewportHistory.removeLast();
    _setViewport(_limitXRange(previous).copy());
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  PlotViewport _limitXRange(PlotViewport candidate, {PlotViewport? previous}) {
    final limit = effectiveMaxVisiblePoints;
    if (candidate.xRange <= limit) return candidate;
    if (previous != null && previous.xRange >= limit) {
      return previous;
    }
    return candidate.copyWith(xMax: candidate.xMin + limit);
  }

  PlotViewport _followViewportForLatestIndex(double latestIndex) {
    final range = viewport.xRange;
    final ratio = _followPositionRatio.clamp(0.5, 0.95);
    return viewport.copyWith(
      xMin: latestIndex - range * ratio,
      xMax: latestIndex + range * (1 - ratio),
    );
  }

  double _latestFollowIndex() {
    if (_dataPoints.isNotEmpty) return _dataPoints.last.index.toDouble();
    if (_nextIndex > 0) return (_nextIndex - 1).toDouble();
    return _nextIndex.toDouble();
  }

  (double, double) _fitYRange(double minY, double maxY) {
    final dataRange = maxY - minY;
    final displayRatio = _yFitDisplayRatio.clamp(0.5, 0.95);
    final targetRange = dataRange / displayRatio;
    final padding = (targetRange - dataRange) / 2;
    return (minY - padding, maxY + padding);
  }

  /// X 轴放大
  void zoomXIn() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    _setViewport(
      _limitXRange(viewport.zoomX(0.8, centerX), previous: viewport),
    );
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X 轴缩小
  void zoomXOut() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    _setViewport(
      _limitXRange(viewport.zoomX(1.25, centerX), previous: viewport),
    );
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴放大
  void zoomYIn() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    _setViewport(viewport.zoomY(0.8, centerY));
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴缩小
  void zoomYOut() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    _setViewport(viewport.zoomY(1.25, centerY));
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
        displayDataPoints.where((p) {
          return p.index >= viewport.xMin && p.index <= viewport.xMax;
        }).toList();
    if (visiblePoints.isEmpty) return;

    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    final currentChannels = displayChannels;
    for (final point in visiblePoints) {
      for (
        int i = 0;
        i < point.values.length && i < currentChannels.length;
        i++
      ) {
        if (!currentChannels[i].visible) continue;
        if (currentChannels[i].offsetEnabled) continue;
        if (!point.values[i].isFinite) continue;
        final v =
            point.values[i] * currentChannels[i].yScale +
            currentChannels[i].yOffset;
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
        final (yMin, yMax) = _fitYRange(minY, maxY);
        _setViewport(viewport.copyWith(yMin: yMin, yMax: yMax));
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
    final minX = (maxX - effectiveMaxVisiblePoints).clamp(0, maxX).toDouble();

    _saveViewport();
    _setViewport(viewport.copyWith(xMin: minX, xMax: maxX));
    _loadTailWindow();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void _loadFixedFrameTailWindow() {
    if (_fixedFrameRawFrames.isEmpty) return;
    final count =
        _fixedFrameRawFrames.packetCount
            .clamp(0, effectiveMaxVisiblePoints)
            .toInt();
    final start = _fixedFrameRawFrames.packetCount - count;
    _rebuildFixedFrameWindow(start, count);
  }

  void _rebuildFixedFrameWindow(int start, int count) {
    _dataPoints.clear();
    _visibleStartIndex = start;
    _dataRevision++;
    _invalidateDisplayCaches();
    _resetObservedValueMetadata();

    for (int i = 0; i < count; i++) {
      final packetIndex = start + i;
      final frame = _fixedFrameRawFrames.readPacket(packetIndex);
      final values = FixedFrameParser.decodeFrameValues(frame, _parserConfig);
      _recordObservedValues(values);
      _dataPoints.add(
        PlotDataPoint(
          index: packetIndex,
          timestamp: packetIndex.toDouble(),
          values: values,
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
    final minX = (maxX - effectiveMaxVisiblePoints).clamp(0, maxX).toDouble();

    // Y范围（只计算可见通道）
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    final currentData = displayDataPoints;
    final currentChannels = displayChannels;
    for (final point in currentData) {
      for (
        int i = 0;
        i < point.values.length && i < currentChannels.length;
        i++
      ) {
        if (!currentChannels[i].visible) continue;
        if (currentChannels[i].offsetEnabled) continue;
        if (!point.values[i].isFinite) continue;
        final v =
            point.values[i] * currentChannels[i].yScale +
            currentChannels[i].yOffset;
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }

    _saveViewport();
    if (minY != double.infinity && maxY != double.negativeInfinity) {
      if (minY == maxY) {
        _setViewport(viewport.copyWith(xMin: minX, xMax: maxX));
        showStatusMessage('默认Y轴数据范围为0，仅自适应X轴');
      }
      if (minY != maxY) {
        final (yMin, yMax) = _fitYRange(minY, maxY);
        _setViewport(
          viewport.copyWith(xMin: minX, xMax: maxX, yMin: yMin, yMax: yMax),
        );
      }
    } else {
      _setViewport(viewport.copyWith(xMin: minX, xMax: maxX));
    }
    _fitOffsetChannelsY(currentData);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  bool _fitOffsetChannelsY(Iterable<PlotDataPoint> points) {
    final valuesByTarget = <int, (double, double)>{};
    final representativeByTarget = <int, int>{};
    final groupIdByTarget = <int, int?>{};
    final currentChannels = displayChannels;
    final activeLimit = displayActiveChannelCount;
    for (final point in points) {
      for (
        int i = 0;
        i < point.values.length &&
            i < currentChannels.length &&
            i < activeLimit;
        i++
      ) {
        final channel = currentChannels[i];
        if (!channel.visible || !channel.offsetEnabled) continue;
        final value = point.values[i];
        if (!value.isFinite) continue;
        final groupId = channel.offsetBindingGroupId;
        final targetKey = groupId ?? (-channel.index - 1);
        representativeByTarget.putIfAbsent(targetKey, () => i);
        groupIdByTarget.putIfAbsent(targetKey, () => groupId);
        final current = valuesByTarget[targetKey];
        if (current == null) {
          valuesByTarget[targetKey] = (value, value);
        } else {
          valuesByTarget[targetKey] = (
            value < current.$1 ? value : current.$1,
            value > current.$2 ? value : current.$2,
          );
        }
      }
    }

    var changed = false;
    final marginRatio = (1 - _yFitDisplayRatio.clamp(0.5, 0.95)) / 2;
    final targetMin = viewport.yMin + viewport.yRange * marginRatio;
    final targetMax = viewport.yMax - viewport.yRange * marginRatio;
    final targetRange = targetMax - targetMin;
    if (targetRange <= 0) return false;

    for (final entry in valuesByTarget.entries) {
      final minY = entry.value.$1;
      final maxY = entry.value.$2;
      final channelIndex = representativeByTarget[entry.key];
      if (channelIndex == null || channelIndex >= currentChannels.length) {
        continue;
      }
      final groupId = groupIdByTarget[entry.key];
      final channel = currentChannels[channelIndex];
      late final double nextScale;
      late final double nextOffset;
      if (minY == maxY) {
        nextScale = 1.0;
        nextOffset = (targetMin + targetMax) / 2 - minY;
      } else {
        nextScale = targetRange / (maxY - minY);
        nextOffset = targetMin - minY * nextScale;
      }
      if (groupId == null) {
        channel.yScale = nextScale;
        channel.yOffset = nextOffset;
      } else {
        _setOffsetBindingGroupTransform(
          groupId,
          scale: nextScale,
          offset: nextOffset,
        );
      }
      changed = true;
    }

    return changed;
  }

  /// 设置跟随开关
  void setFollowEnabled(bool value) {
    _followEnabled = value;
    if (value && _historyPointCount > 0) {
      _setViewport(_followViewportForLatestIndex(_latestFollowIndex()));
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
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  void updateTriggerConfig(PlotTriggerConfig config) {
    final candidates = triggerCandidateChannels;
    final normalizedChannelIndex =
        candidates.any((channel) => channel.index == config.channelIndex)
            ? config.channelIndex
            : (candidates.isNotEmpty ? candidates.first.index : 0);
    _triggerConfig
      ..enabled = config.enabled && candidates.isNotEmpty
      ..channelIndex = normalizedChannelIndex
      ..comparison = config.comparison
      ..targetValue = config.targetValue
      ..hitThreshold = math.max(1, config.hitThreshold)
      ..triggerLimit = math.max(1, config.triggerLimit)
      ..action = config.action
      ..postTriggerPacketCount = math.max(0, config.postTriggerPacketCount)
      ..observationMode = config.observationMode
      ..includeSystemTimeInNote = config.includeSystemTimeInNote;
    _triggerConfigured = true;
    _resetTriggerRuntimeState();
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  void setTriggerEnabled(bool value) {
    if (value && !_triggerConfigured) {
      showStatusMessage('请先右键触发按钮配置触发条件');
      return;
    }
    if (value && !_canUseTriggerChannel(_triggerConfig.channelIndex)) {
      final candidates = triggerCandidateChannels;
      if (candidates.isEmpty) {
        showStatusMessage('当前没有可用的普通或数学通道，无法开启触发');
        return;
      }
      _triggerConfig.channelIndex = candidates.first.index;
    }
    if (_triggerConfig.enabled == value) return;
    _triggerConfig.enabled = value;
    _resetTriggerRuntimeState();
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  // ========== 通道控制 ==========
  void setOffsetBindingGroup(int index, Set<int> selectedIndices) {
    final primary = displayChannelByIndex(index);
    if (primary == null || !primary.visible || !primary.offsetEnabled) return;

    final selected = <int>{index};
    for (final candidate in offsetBindingCandidates(index)) {
      if (selectedIndices.contains(candidate.index)) {
        selected.add(candidate.index);
      }
    }

    if (selected.length < 2) {
      clearOffsetBinding(index);
      return;
    }

    final oldPrimaryGroupId = primary.offsetBindingGroupId;
    final newGroupId = oldPrimaryGroupId ?? _nextOffsetBindingGroupId++;
    final primaryScale = primary.yScale;
    final primaryOffset = primary.yOffset;

    for (final channel in displayChannels) {
      final wasInPrimaryGroup =
          oldPrimaryGroupId != null &&
          channel.offsetBindingGroupId == oldPrimaryGroupId;
      if (selected.contains(channel.index)) {
        channel.offsetBindingGroupId = newGroupId;
        channel.yScale = primaryScale;
        channel.yOffset = primaryOffset;
      } else if (wasInPrimaryGroup) {
        channel.offsetBindingGroupId = null;
      }
    }

    _cleanupOffsetBindingGroups();
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  void clearOffsetBinding(int index) {
    final channel = displayChannelByIndex(index);
    final groupId = channel?.offsetBindingGroupId;
    if (groupId == null) return;
    for (final member in displayChannels) {
      if (member.offsetBindingGroupId == groupId) {
        member.offsetBindingGroupId = null;
      }
    }
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  void _cleanupOffsetBindingGroups() {
    final counts = <int, int>{};
    for (final channel in displayChannels) {
      final groupId = channel.offsetBindingGroupId;
      if (groupId == null) continue;
      if (!channel.visible || !channel.offsetEnabled) {
        channel.offsetBindingGroupId = null;
        continue;
      }
      counts[groupId] = (counts[groupId] ?? 0) + 1;
    }
    for (final channel in displayChannels) {
      final groupId = channel.offsetBindingGroupId;
      if (groupId != null && (counts[groupId] ?? 0) < 2) {
        channel.offsetBindingGroupId = null;
      }
    }
  }

  void _setOffsetBindingGroupOffset(int groupId, double offset) {
    for (final channel in displayChannels) {
      if (channel.offsetBindingGroupId == groupId) {
        channel.yOffset = offset;
      }
    }
  }

  void _setOffsetBindingGroupScale(int groupId, double scale) {
    for (final channel in displayChannels) {
      if (channel.offsetBindingGroupId == groupId) {
        channel.yScale = scale;
      }
    }
  }

  void _setOffsetBindingGroupTransform(
    int groupId, {
    required double scale,
    required double offset,
  }) {
    for (final channel in displayChannels) {
      if (channel.offsetBindingGroupId == groupId) {
        channel.yScale = scale;
        channel.yOffset = offset;
      }
    }
  }

  /// 设置通道可见性
  void setChannelVisible(int index, bool visible) {
    if (index < 0 || index >= channels.length) return;
    channels[index].visible = visible;
    if (!visible) {
      channels[index].offsetBindingGroupId = null;
      _cleanupOffsetBindingGroups();
    }
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道颜色
  void setChannelColor(int index, Color color) {
    if (index < 0 || index >= channels.length) return;
    channels[index].color = color;
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道是否显示连线
  void setChannelShowLine(int index, bool show) {
    if (index < 0 || index >= channels.length) return;
    channels[index].showLine = show;
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道点半径
  void setChannelPointSize(int index, double size) {
    if (index < 0 || index >= channels.length) return;
    channels[index].pointSize = size.clamp(0.5, 12.0);
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道线宽
  void setChannelLineWidth(int index, double width) {
    if (index < 0 || index >= channels.length) return;
    channels[index].lineWidth = width.clamp(0.5, 8.0);
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 一键设置所有通道的显示状态
  void setAllChannelsVisible(bool visible) {
    for (final ch in channels) {
      ch.visible = visible;
      if (!visible) ch.offsetBindingGroupId = null;
    }
    for (final channel in mathChannels) {
      if (channel.enabled) channel.display.visible = visible;
      if (!visible) channel.display.offsetBindingGroupId = null;
    }
    if (!visible) _cleanupOffsetBindingGroups();
    _markChannelConfigChanged();
    _invalidateDisplayCaches();
    Future.microtask(() => notifyListeners());
  }

  MathChannelConfig? firstAvailableMathChannel() {
    for (final channel in mathChannels) {
      if (!channel.enabled) return channel;
    }
    return null;
  }

  String? validateMathExpression(String expression) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) return '表达式不能为空';
    try {
      MathExpression.parse(trimmed);
      return null;
    } catch (e) {
      return e is FormatException ? e.message : '表达式格式错误';
    }
  }

  bool enableMathChannel(int index, String expression) {
    if (index < 0 || index >= mathChannels.length) return false;
    return configureMathChannel(index, expression, mathChannels[index].display);
  }

  bool configureMathChannel(
    int index,
    String expression,
    ChannelConfig display,
  ) {
    if (index < 0 || index >= mathChannels.length) return false;
    final error = validateMathExpression(expression);
    if (error != null) {
      showStatusMessage(error);
      return false;
    }
    final channel = mathChannels[index];
    channel.enabled = true;
    channel.expression = expression.trim();
    channel.display = display.copyWith(alias: channel.name);
    channel.display.visible = true;
    _compileMathChannel(channel);
    _invalidateDisplayCaches();
    _rebuildObservedRawValueMetadata();
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
    return true;
  }

  void updateMathChannelDisplay(int index, ChannelConfig display) {
    if (index < 0 || index >= mathChannels.length) return;
    mathChannels[index].display = display.copyWith(
      alias: mathChannels[index].name,
    );
    if (!mathChannels[index].display.visible ||
        !mathChannels[index].display.offsetEnabled) {
      mathChannels[index].display.offsetBindingGroupId = null;
      _cleanupOffsetBindingGroups();
    }
    _invalidateDisplayChannelCaches();
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void disableMathChannel(int index) {
    if (index < 0 || index >= mathChannels.length) return;
    final old = mathChannels[index];
    old.display.offsetBindingGroupId = null;
    mathChannels[index] = MathChannelConfig(index: old.index);
    _cleanupOffsetBindingGroups();
    _compiledMathExpressions.remove(index);
    _invalidateDisplayCaches();
    _rebuildObservedRawValueMetadata();
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void resetMathChannel(int index) {
    disableMathChannel(index);
  }

  bool resetAllChannels() {
    if (_isPlotting || _isStopping) {
      showStatusMessage('请停止绘图后再重置全部通道');
      return false;
    }

    for (int i = 0; i < channels.length; i++) {
      channels[i] = ChannelConfig(
        index: i,
        color: ChannelConfig.colorForIndex(i, _plotBackground),
      );
    }
    for (int i = 0; i < mathChannels.length; i++) {
      mathChannels[i] = MathChannelConfig(index: i);
    }
    _invalidateDisplayCaches();
    _cleanupOffsetBindingGroups();
    _compiledMathExpressions.clear();
    _sendProtocolConfig.rChannelAddresses = List.filled(
      SendProtocolConfig.maxChannelCount,
      '',
    );
    _channelPresetBindings.clear();
    _parserConfig.zobowChannelIds = List.generate(
      ParserConfig.maxZobowChannelCount,
      (index) => index + 1,
    );
    _parserConfig.zobowChannelTypes = List.filled(
      ParserConfig.maxZobowChannelCount,
      DataType.int16,
    );
    _parserConfig.fixedFrameChannelTypes = List.filled(
      SendProtocolConfig.maxChannelCount,
      DataType.uint16,
    );
    _rebuildObservedRawValueMetadata();
    _refreshSnapHighlightColors();
    _markChannelConfigChanged();
    _saveSettings();
    AppLogger().info('已重置全部通道设置', category: 'PLOT');
    Future.microtask(() => notifyListeners());
    return true;
  }

  /// 设置通道别名
  void setChannelAlias(int index, String alias) {
    if (index < 0 || index >= channels.length) return;
    _clearPresetBinding(AddressProfileProtocolType.zobow, index);
    _clearPresetBinding(AddressProfileProtocolType.rProtocol, index);
    channels[index].alias = alias;
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴偏移
  void setChannelYOffset(int index, double offset) {
    if (index >= PlotConfiguration.rawChannelCount &&
        index < PlotConfiguration.rawChannelCount + mathChannels.length) {
      final mathChannel =
          mathChannels[index - PlotConfiguration.rawChannelCount];
      final groupId = mathChannel.display.offsetBindingGroupId;
      if (groupId != null) {
        _setOffsetBindingGroupOffset(groupId, offset);
      } else {
        mathChannel.display.yOffset = offset;
      }
      _invalidateDisplayChannelCaches();
      _markChannelConfigChanged();
      Future.microtask(() => notifyListeners());
      return;
    }
    if (index < 0 || index >= channels.length) return;
    final groupId = channels[index].offsetBindingGroupId;
    if (groupId != null) {
      _setOffsetBindingGroupOffset(groupId, offset);
    } else {
      channels[index].yOffset = offset;
    }
    _markChannelConfigChanged();
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
      channels[index].offsetBindingGroupId = null;
      _cleanupOffsetBindingGroups();
    }
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴缩放
  void setChannelYScale(int index, double scale) {
    if (index < 0 || index >= channels.length) return;
    final groupId = channels[index].offsetBindingGroupId;
    if (groupId != null) {
      _setOffsetBindingGroupScale(groupId, scale);
    } else {
      channels[index].yScale = scale;
    }
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 缩放通道 Y 轴（滚轮缩放，按比例调整）
  void zoomChannelYScale(int index, double scaleDelta) {
    if (index >= PlotConfiguration.rawChannelCount &&
        index < PlotConfiguration.rawChannelCount + mathChannels.length) {
      final display =
          mathChannels[index - PlotConfiguration.rawChannelCount].display;
      final newScale = (display.yScale * scaleDelta).clamp(0.001, 1000.0);
      final groupId = display.offsetBindingGroupId;
      if (groupId != null) {
        _setOffsetBindingGroupScale(groupId, newScale);
      } else {
        display.yScale = newScale;
      }
      _invalidateDisplayChannelCaches();
      _markChannelConfigChanged();
      Future.microtask(() => notifyListeners());
      return;
    }
    if (index < 0 || index >= channels.length) return;
    final newScale = (channels[index].yScale * scaleDelta).clamp(0.001, 1000.0);
    final groupId = channels[index].offsetBindingGroupId;
    if (groupId != null) {
      _setOffsetBindingGroupScale(groupId, newScale);
    } else {
      channels[index].yScale = newScale;
    }
    _markChannelConfigChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 众邦电控的通道号
  void setZobowChannelId(int index, int channelId) {
    if (_isPlotting || _isStopping) return;
    if (index < 0 || index >= _parserConfig.zobowChannelCount) return;
    final normalized = channelId & 0xFFFFFFFF;
    final nextKey = _presetAddressKey(
      AddressProfileProtocolType.zobow,
      normalized,
    );
    _parserConfig.zobowChannelIds[index] = normalized;
    _clearPresetAliasesForChangedAddress(
      AddressProfileProtocolType.zobow,
      index,
      nextKey,
    );
    _markChannelConfigChanged();
    _saveSettings();
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
    _markChannelConfigChanged();
    _resetObservedValueMetadata();
    if (_parserConfig.zobowChannelTypes[index] == type) return true;

    _parserConfig.zobowChannelTypes[index] = type;
    _saveSettings();

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

  Future<bool> setFixedFrameChannelType(int index, DataType type) async {
    if (index < 0 || index >= _parserConfig.channelCount) return false;
    if (_isPlotting || _isStopping) {
      showStatusMessage('请停止绘图后再修改固定帧通道数据类型');
      return false;
    }
    channels[index].dataType = type;
    _markChannelConfigChanged();
    _resetObservedValueMetadata();
    if (_parserConfig.fixedFrameChannelTypes[index] == type) return true;

    _parserConfig.fixedFrameChannelTypes[index] = type;
    _saveSettings();
    _resetFixedFrameRawFrameBuffer();
    clearData();
    Future.microtask(() => notifyListeners());
    return true;
  }

  // ========== 显示控制 ==========
  /// 设置网格显示开关
  void setShowGrid(bool show) {
    _showGrid = show;
    _markChannelConfigChanged();
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
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setSnapHighlightDiameter(double value) {
    final next = value.clamp(6.0, 12.0).toDouble();
    if ((_snapHighlightDiameter - next).abs() < 1e-9) return;
    _snapHighlightDiameter = next;
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setSnapHighlightColorMode(String value) {
    final next = value == 'channel' ? 'channel' : 'cursor';
    if (_snapHighlightColorMode == next) return;
    _snapHighlightColorMode = next;
    _refreshSnapHighlightColors();
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setStatsToolbarEnabled(bool value) {
    if (_statsToolbarEnabled == value) return;
    _statsToolbarEnabled = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setTriggerToolbarEnabled(bool value) {
    if (_triggerToolbarEnabled == value) return;
    _triggerToolbarEnabled = value;
    if (!value && _triggerConfig.enabled) {
      _triggerConfig.enabled = false;
      _resetTriggerRuntimeState();
      _markOverlayChanged();
    }
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setPreviewToolbarEnabled(bool value) {
    if (_previewToolbarEnabled == value) return;
    _previewToolbarEnabled = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setLodQuality(PlotLodQuality value) {
    if (_lodQuality == value) return;
    _lodQuality = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void movePreviewViewportTo(double centerX, {bool fromDrag = false}) {
    final maxX = math.max(0, _historyPointCount - 1).toDouble();
    final range = math.min(viewport.xRange, math.max(1.0, maxX));
    final minX =
        (centerX - range / 2)
            .clamp(0.0, math.max(0.0, maxX - range))
            .toDouble();
    final next = viewport.copyWith(xMin: minX, xMax: minX + range);
    if (_followEnabled) _followEnabled = false;
    updateViewport(next, fromDrag: fromDrag);
  }

  void setKeepPlotOnRestart(bool value) {
    if (_keepPlotOnRestart == value) return;
    _keepPlotOnRestart = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setFollowPositionRatio(double value) {
    final next = value.clamp(0.5, 0.95).toDouble();
    if ((_followPositionRatio - next).abs() < 1e-9) return;
    _followPositionRatio = next;
    if (_followEnabled && _historyPointCount > 0) {
      _setViewport(_followViewportForLatestIndex(_latestFollowIndex()));
      _loadWindowForViewport(force: true);
    }
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setYFitDisplayRatio(double value) {
    final next = value.clamp(0.5, 0.95).toDouble();
    if ((_yFitDisplayRatio - next).abs() < 1e-9) return;
    _yFitDisplayRatio = next;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置绘图界面字体大小偏移（-3~+6，基于默认字号）
  void setPlotFontSizeDelta(int delta) {
    _plotFontSizeDelta = delta.clamp(-3, 6);
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setPlotFontBold(bool enabled) {
    if (_plotFontBold == enabled) return;
    _plotFontBold = enabled;
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置绘图窗口点数上限，范围由 [PlotConfiguration] 统一约束。
  void setMaxVisiblePoints(int points) {
    final next = points.clamp(minVisiblePoints, maxVisiblePointsLimit).toInt();
    if (next == _maxVisiblePoints) return;
    _maxVisiblePoints = next;

    if (_historyPointCount > 0) {
      _setViewport(_limitXRange(viewport).copy());
      _loadWindowForViewport(force: true);
    }

    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置每次开始绘图时丢弃的前置有效数据包数量。
  ///
  /// 该设置只影响下一次 startPlotting 后新进入解析链的数据，不处理导入文件。
  void setDiscardInitialPacketCount(int count) {
    final next = count.clamp(0, maxDiscardInitialPacketCount).toInt();
    if (next == _discardInitialPacketCount) return;
    _discardInitialPacketCount = next;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置网格密度（sparse/normal/dense）
  void setGridDensity(String density) {
    const valid = {'sparse', 'normal', 'dense'};
    if (valid.contains(density)) {
      _gridDensity = density;
      _markChannelConfigChanged();
      _saveSettings();
      Future.microtask(() => notifyListeners());
    }
  }

  void setPlotBackground(String background) {
    final next = background == 'light' ? 'light' : 'dark';
    if (_plotBackground == next) return;
    _plotBackground = next;
    _applyPlotBackgroundPalette();
    _markChannelConfigChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setFloatingPanelOpacity(double opacity) {
    final next = opacity.clamp(0.0, 1.0);
    if ((_floatingPanelOpacity - next).abs() < 0.0001) return;
    _floatingPanelOpacity = next;
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setLegendPanelPosition({required double right, required double top}) {
    final nextRight = _normalizeFloatingPanelPosition(right);
    final nextTop = _normalizeFloatingPanelPosition(top);
    if (nextRight == null || nextTop == null) return;
    if (_legendPanelRight == nextRight && _legendPanelTop == nextTop) return;
    _legendPanelRight = nextRight;
    _legendPanelTop = nextTop;
    _saveSettings();
  }

  void setLiveValuesPanelPosition({
    required double right,
    required double top,
  }) {
    final nextRight = _normalizeFloatingPanelPosition(right);
    final nextTop = _normalizeFloatingPanelPosition(top);
    if (nextRight == null || nextTop == null) return;
    if (_liveValuesPanelRight == nextRight && _liveValuesPanelTop == nextTop) {
      return;
    }
    _liveValuesPanelRight = nextRight;
    _liveValuesPanelTop = nextTop;
    _saveSettings();
  }

  double? _normalizeFloatingPanelPosition(double value) {
    if (!value.isFinite || value < 0) return null;
    return double.parse(value.toStringAsFixed(1));
  }

  void setObservationClickToPlace(bool value) {
    if (_observationClickToPlace == value) return;
    _observationClickToPlace = value;
    if (!value) {
      _observationPlacementActive = false;
      _observationPreview = null;
      _markOverlayChanged();
    }
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void _applyPlotBackgroundPalette() {
    for (final channel in channels) {
      channel.color = ChannelConfig.colorForBackground(
        channel.color,
        _plotBackground,
      );
    }
    for (final channel in mathChannels) {
      channel.display.color = ChannelConfig.colorForBackground(
        channel.display.color,
        _plotBackground,
      );
    }
    _invalidateDisplayChannelCaches();
    _refreshSnapHighlightColors();
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
    _markOverlayChanged();
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
    _markOverlayChanged();
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
    _markOverlayChanged();
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
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围左边界
  void setStatsX1(double x) {
    _statsX1 = x;
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围右边界
  void setStatsX2(double x) {
    _statsX2 = x;
    _markOverlayChanged();
    Future.microtask(() => notifyListeners());
  }

  void _handleTriggerForPoint(PlotDataPoint point, DateTime now) {
    final triggerChannelIndex = _triggerConfig.channelIndex;
    final currentValue = _triggerValueForPoint(point, triggerChannelIndex);
    final previousValue = _triggerPreviousValue;

    if (_triggerStopPacketsRemaining != null) {
      _recordTriggerPreviousValue(currentValue);
      final remaining = _triggerStopPacketsRemaining! - 1;
      if (remaining <= 0) {
        _triggerStopPacketsRemaining = null;
        _requestTriggerStop();
      } else {
        _triggerStopPacketsRemaining = remaining;
      }
      return;
    }

    if (!_triggerConfig.enabled || _triggerStopRequested) {
      _recordTriggerPreviousValue(currentValue);
      return;
    }

    if (!_canUseTriggerChannel(triggerChannelIndex) || currentValue == null) {
      _recordTriggerPreviousValue(currentValue);
      return;
    }

    if (!_matchesTriggerCondition(currentValue, previousValue)) {
      _recordTriggerPreviousValue(currentValue);
      return;
    }

    _recordTriggerPreviousValue(currentValue);

    _triggerHitCount++;
    _triggerHitPoints.add(point);
    if (_triggerHitCount < _triggerConfig.hitThreshold) return;

    _triggeredCount++;
    final hitPoints = List<PlotDataPoint>.from(_triggerHitPoints);
    final note = _buildTriggerObservationNote(now);
    _addTriggerObservations(hitPoints, note);
    _triggerHitCount = 0;
    _triggerHitPoints.clear();

    final reachedTriggerLimit = _triggeredCount >= _triggerConfig.triggerLimit;
    if (!reachedTriggerLimit) {
      _markOverlayChanged();
      Future.microtask(() => notifyListeners());
      return;
    }

    _triggerConfig.enabled = false;

    switch (_triggerConfig.action) {
      case PlotTriggerAction.markOnly:
        _markOverlayChanged();
        Future.microtask(() => notifyListeners());
        break;
      case PlotTriggerAction.stopImmediately:
        _requestTriggerStop();
        break;
      case PlotTriggerAction.stopAfterPackets:
        if (_triggerConfig.postTriggerPacketCount <= 0) {
          _requestTriggerStop();
        } else {
          _triggerStopPacketsRemaining = _triggerConfig.postTriggerPacketCount;
        }
        break;
    }
  }

  bool _canUseTriggerChannel(int index) {
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    if (index >= 0 && index < rawCount && index < channels.length) {
      return channels[index].visible;
    }
    final mathIndex = index - PlotConfiguration.rawChannelCount;
    return mathIndex >= 0 &&
        mathIndex < mathChannels.length &&
        _canUseMathChannelForTrigger(mathChannels[mathIndex]);
  }

  double? _triggerValueForPoint(PlotDataPoint point, int channelIndex) {
    if (channelIndex >= 0 && channelIndex < PlotConfiguration.rawChannelCount) {
      if (channelIndex >= point.values.length) return null;
      final value = point.values[channelIndex];
      return value.isFinite ? value : null;
    }
    final mathIndex = channelIndex - PlotConfiguration.rawChannelCount;
    if (mathIndex < 0 || mathIndex >= mathChannels.length) return null;
    final channel = mathChannels[mathIndex];
    if (!_canUseMathChannelForTrigger(channel)) return null;
    final value = _compiledMathExpressions[mathIndex]!.evaluate(point.values);
    return value.isFinite ? value : null;
  }

  bool _matchesTriggerCondition(double value, double? previousValue) {
    return switch (_triggerConfig.comparison) {
      PlotTriggerComparison.greater => value > _triggerConfig.targetValue,
      PlotTriggerComparison.less => value < _triggerConfig.targetValue,
      PlotTriggerComparison.equal =>
        (value - _triggerConfig.targetValue).abs() <=
            PlotTriggerConfig.equalTolerance,
      PlotTriggerComparison.crossUp =>
        previousValue != null &&
            previousValue < _triggerConfig.targetValue &&
            value >= _triggerConfig.targetValue,
      PlotTriggerComparison.crossDown =>
        previousValue != null &&
            previousValue > _triggerConfig.targetValue &&
            value <= _triggerConfig.targetValue,
    };
  }

  void _recordTriggerPreviousValue(double? value) {
    _triggerPreviousValue = value;
  }

  void _addTriggerObservations(List<PlotDataPoint> hitPoints, String note) {
    switch (_triggerConfig.observationMode) {
      case PlotTriggerObservationMode.none:
        return;
      case PlotTriggerObservationMode.triggerPoint:
        if (hitPoints.isNotEmpty) {
          _addObservationFromPoint(hitPoints.last, note: note);
        }
        break;
      case PlotTriggerObservationMode.allHits:
        for (final point in hitPoints) {
          if (!_addObservationFromPoint(point, note: note)) break;
        }
        break;
    }
  }

  String _buildTriggerObservationNote(DateTime now) {
    final channel = displayChannelName(_triggerConfig.channelIndex);
    final parts = <String>[];
    if (_triggerConfig.includeSystemTimeInNote) {
      parts.add('触发于 ${_formatTriggerTime(now)}');
    }
    parts.add(
      '$channel ${_triggerConfig.comparison.label} ${formatPlotValue(_triggerConfig.targetValue)}',
    );
    parts.add('累计 ${_triggerConfig.hitThreshold} 次');
    parts.add('第 $_triggeredCount 次触发');
    return parts.join('，');
  }

  String _formatTriggerTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  void _requestTriggerStop() {
    if (_triggerStopRequested) return;
    _triggerStopRequested = true;
    _triggerConfig.enabled = false;
    Future.microtask(() {
      if (!_disposed) unawaited(stopPlotting());
    });
  }

  void _resetTriggerRuntimeState() {
    _triggerHitCount = 0;
    _triggeredCount = 0;
    _triggerHitPoints.clear();
    _triggerPreviousValue = null;
    _triggerStopPacketsRemaining = null;
    _triggerStopRequested = false;
  }

  /// 更新垂直光标（跟随鼠标模式）
  ///
  /// - X 值吸附到最近的整数（数据点索引都是整数）
  /// - 使用二分查找精确匹配数据点，避免线性扫描
  /// - 未绘制到数据点的区域设置 hasData=false，tooltip 不显示
  void updateFollowCursor(double x, double y, Offset screenPosition) {
    _cursor = _buildCursorAtX(x, y: y, screenPosition: screenPosition);
    _markOverlayChanged();
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  /// 更新光标状态（由外部直接设置）
  void updateCursor(CursorState? cursor) {
    _cursor = cursor;
    _markOverlayChanged();
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  void addObservation() {
    final cursorX = _cursor?.x;
    final sourceX =
        cursorX != null && viewport.isVisibleX(cursorX)
            ? cursorX
            : viewport.xMin + viewport.xRange / 2;
    if (_addObservationAtX(sourceX)) {
      _markOverlayChanged();
      scheduleMicrotask(notifyListeners);
    }
  }

  void startObservationPlacement() {
    if (displayDataPoints.isEmpty) return;
    _observationPlacementActive = true;
    _observationPreview = null;
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void updateObservationPlacement(double x) {
    if (!_observationPlacementActive) return;
    _observationPreview = _buildCursorAtX(x);
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void commitObservationPlacement(double x) {
    if (!_observationPlacementActive) return;
    _addObservationAtX(x);
    _observationPlacementActive = false;
    _observationPreview = null;
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void updateObservation(int index, double x) {
    if (index < 0 || index >= _observations.length) return;
    if (_observations[index].locked) return;
    _observations[index] = _observations[index].copyWith(
      cursor: _buildObservationCursorAtX(x),
    );
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void updateObservationNote(int index, String note) {
    if (index < 0 || index >= _observations.length) return;
    _observations[index] = _observations[index].copyWith(note: note);
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void setObservationLocked(int index, bool locked) {
    if (index < 0 || index >= _observations.length) return;
    if (_observations[index].locked == locked) return;
    _observations[index] = _observations[index].copyWith(locked: locked);
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void removeObservation(int index) {
    if (index < 0 || index >= _observations.length) return;
    _observations.removeAt(index);
    _markOverlayChanged();
    scheduleMicrotask(notifyListeners);
  }

  void jumpToObservation(int index) {
    if (index < 0 || index >= _observations.length) return;
    jumpToXIndex(_observations[index].x.round());
  }

  bool canJumpToXIndex(int x) {
    return x >= 0 && x < _nextIndex;
  }

  void jumpToXIndex(int x) {
    if (!canJumpToXIndex(x)) return;
    final range = viewport.xRange;
    final halfRange = range / 2;
    final center = x.toDouble();
    _setViewport(
      viewport.copyWith(xMin: center - halfRange, xMax: center + halfRange),
    );
    _loadWindowForViewport();
    Future.microtask(() => notifyListeners());
  }

  bool _addObservationAtX(double x, {String note = ''}) {
    if (_observations.length >= maxObservationCount) return false;
    var nextNote = note;
    if (_observations.length + 1 == maxObservationCount) {
      nextNote = _appendObservationLimitNote(nextNote);
    }
    _observations.add(
      PlotObservation(cursor: _buildObservationCursorAtX(x), note: nextNote),
    );
    return true;
  }

  bool _addObservationFromPoint(PlotDataPoint point, {String note = ''}) {
    if (_observations.length >= maxObservationCount) return false;
    var nextNote = note;
    if (_observations.length + 1 == maxObservationCount) {
      nextNote = _appendObservationLimitNote(nextNote);
    }
    _observations.add(
      PlotObservation(
        cursor: CursorState(
          x: point.index.toDouble(),
          channelValues: _buildTriggerObservationValues(point),
          hasData: true,
        ),
        note: nextNote,
        locked: true,
      ),
    );
    return true;
  }

  List<double> _buildTriggerObservationValues(PlotDataPoint point) {
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    final values = List<double>.generate(
      rawCount,
      (index) => index < point.values.length ? point.values[index] : double.nan,
      growable: true,
    );
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      final expression = _compiledMathExpressions[channel.index];
      if (expression == null || expression.hasChannelOffset) {
        values.add(double.nan);
        continue;
      }
      values.add(expression.evaluate(point.values));
    }
    return values;
  }

  String _appendObservationLimitNote(String note) {
    const limitNote = '观察已达 100 条上限，后续触发不再新增观察';
    if (note.isEmpty) return limitNote;
    if (note.contains(limitNote)) return note;
    return '$note；$limitNote';
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

  CursorState _buildObservationCursorAtX(double x) {
    if (!viewport.isVisibleX(x)) {
      return CursorState(x: x, hasData: false);
    }
    final point = _nearestVisiblePointByX(x);
    if (point == null) {
      return CursorState(x: x, hasData: false);
    }
    return CursorState(
      x: point.index.toDouble(),
      channelValues: List<double>.from(point.values),
      hasData: true,
    );
  }

  PlotDataPoint? _nearestVisiblePointByX(double x) {
    final points = displayDataPoints;
    if (points.isEmpty) return null;
    final range = _dataPointRangeByX(viewport.xMin, viewport.xMax);
    if (range == null) return null;

    int left = range.start;
    int right = range.end - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final midX = points[mid].index.toDouble();
      if (midX < x) {
        left = mid + 1;
      } else if (midX > x) {
        right = mid - 1;
      } else {
        return points[mid];
      }
    }

    final candidates = <int>[
      if (right >= range.start && right < range.end) right,
      if (left >= range.start && left < range.end) left,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final da = (points[a].index.toDouble() - x).abs();
      final db = (points[b].index.toDouble() - x).abs();
      return da.compareTo(db);
    });
    return points[candidates.first];
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
    final points = displayDataPoints;
    final currentChannels = displayChannels;
    if (!_statsEnabled || points.isEmpty) return null;

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

    for (int i = 0; i < currentChannels.length; i++) {
      if (!currentChannels[i].visible) continue;

      double? maxVal, minVal, sum;
      int count = 0;

      for (
        int pointIndex = range.start;
        pointIndex < range.end;
        pointIndex += sampleStep
      ) {
        final point = points[pointIndex];
        if (i >= point.channelCount) continue;

        final val = point.values[i];
        if (!val.isFinite) continue;
        maxVal = maxVal == null || val > maxVal ? val : maxVal;
        minVal = minVal == null || val < minVal ? val : minVal;
        sum = (sum ?? 0) + val;
        count++;
      }

      if (count == 0) continue;
      if (hasVisibleChannel) buffer.writeln('---');
      hasVisibleChannel = true;

      final name =
          currentChannels[i].alias.isNotEmpty
              ? currentChannels[i].alias
              : 'Ch$i';
      buffer.writeln('$name:');
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
    final rangeStart = points[range.start].index;
    final rangeEnd = points[range.end - 1].index;
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
    _cancelPendingDragViewportNotification();
    _parseSubscription?.cancel();
    _parseSubscription = null;
    _sourceManager.stop();
    _parser?.dispose();
    _parser = null;
    _isPlotting = false;
    _isStopping = false;
    _stopFuture = null;
    _resetRateState();
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

/// 文本/浮点协议的全量数值历史缓存。
///
/// 直接保存 `List<PlotDataPoint>` 会为每个点和每个通道产生大量 Dart 对象，
/// 百万级数据下 GC 压力很大。这里改用分块的 typed data：
/// - `_valueChunks` 连续保存每个点最多 16 个 double 值。
/// - `_countChunks` 记录每个点真实通道数，支持 JustFloat 自动通道数变化。
