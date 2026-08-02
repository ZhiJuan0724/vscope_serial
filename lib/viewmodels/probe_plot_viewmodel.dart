import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/constants/plot_configuration.dart';
import '../core/utils/plot_value_formatter.dart';
import '../data/models/channel_config.dart';
import '../data/models/plot_data.dart';
import '../data/models/plot_lod_index.dart';
import '../data/models/probe_plot_config.dart';
import '../data/models/probe_connection_config.dart';
import '../services/j_scope_rtt_parser.dart';
import '../services/app_settings.dart';
import '../services/probe_connection_service.dart';
import '../views/plot/plot_render_snapshot.dart';
import '../views/plot/plot_viewport.dart';
import 'settings_drafts.dart';

/// 探针绘图的独立历史、LOD 和视口状态，不依赖串口绘图 ViewModel。
class ProbePlotViewModel extends ChangeNotifier {
  ProbePlotViewModel(this.service) {
    _loadDisplaySettings();
    service.addListener(_handleServiceChanged);
    _subscription = service.probePlotData.listen(_handleRttData);
    _sampleSubscription = service.probeSamples.listen(appendHssSample);
    _wasConnected = service.isConnected;
    _serviceStateSignature = _currentServiceStateSignature();
    if (_wasConnected) {
      scheduleMicrotask(_refreshRttChannelsAfterConnect);
    }
  }

  static const int maxObservationCount = 100;
  static const int minWindowPointLimit = 10000;
  static const int maxWindowPointLimit =
      PlotConfiguration.maxMaterializedPointCount;
  static const int minHistoryMemoryLimitMiB = 64;
  static const int maxHistoryMemoryLimitMiB = 2048;
  static const int _bytesPerMiB = 1024 * 1024;
  final ProbeConnectionService service;
  final Queue<PlotDataPoint> _exactPoints = Queue<PlotDataPoint>();
  final Map<int, PlotDataPoint> _pointsByIndex = <int, PlotDataPoint>{};
  List<PlotDataPoint>? _pointsSnapshot;
  final PlotLodIndex lodIndex = PlotLodIndex();
  late final StreamSubscription<RttDataChunk> _subscription;
  late final StreamSubscription<ProbeSampleChunk> _sampleSubscription;
  final List<ChannelConfig> channels = List.generate(
    12,
    (index) => ChannelConfig(
      index: index,
      color: ChannelConfig.lightPresetColors[index],
      alias: 'Value ${index + 1}',
    ),
  );

  ProbePlotMode mode = ProbePlotMode.rtt;
  PlotViewport viewport = PlotViewport(xMin: 0, xMax: 1000, yMin: -1, yMax: 1);
  JScopeRttParser? _rttParser;
  int? _rttChannelIndex;
  bool _operationPending = false;
  bool _wasConnected = false;
  Future<void>? _rttRefreshFuture;
  int _rttActiveChannelCount = 0;
  String rttChannelName = 'JScope_f4';
  String rttFormat = 'f4';
  List<RttChannelInfo> rttChannels = const [];
  String programPath = '';
  int hssFrequencyHz = 100;
  final List<ProbeSampleVariable> hssVariables = [];
  List<ProbeSymbolInfo> symbols = const [];
  DateTime? _programModifiedAt;
  bool follow = true;
  late int windowPointLimit;
  late int historyMemoryLimitMiB;
  late PlotLodQuality lodQuality;
  late bool showGrid;
  late GridDensity gridDensity;
  late PlotBackgroundStyle backgroundStyle;
  late double floatingPanelOpacity;
  late int plotFontSizeDelta;
  late bool plotFontBold;
  late double followPositionRatio;
  late bool observationClickToPlace;
  bool retentionLimitReached = false;
  int _exactPointsEstimatedBytes = 0;
  int revision = 0;
  int dataRevision = 0;
  int viewportRevision = 0;
  int channelConfigRevision = 0;
  int overlayRevision = 0;
  int pointCount = 0;
  double actualRate = 0;
  int _lastRateCount = 0;
  DateTime _lastRateTime = DateTime.now();
  double? _firstSourceTime;
  double? _dataYMin;
  double? _dataYMax;
  bool _autoFitY = true;
  CursorState? cursor;
  bool vCursorEnabled = false;
  bool xMeasurementEnabled = false;
  bool yMeasurementEnabled = false;
  double? xCursor1;
  double? xCursor2;
  double? yCursor1;
  double? yCursor2;
  final List<PlotObservation> observations = [];
  bool observationPlacementActive = false;
  PlotObservation? observationPreview;
  Timer? _frameNotificationTimer;
  final ValueNotifier<int> _renderNotifier = ValueNotifier<int>(0);
  Object? _serviceStateSignature;
  bool _disposed = false;

  /// 只驱动绘图区的高频刷新，避免采样时重建工具栏和通道列表。
  ValueNotifier<int> get renderListenable => _renderNotifier;

  List<PlotDataPoint> get points =>
      _pointsSnapshot ??= List.unmodifiable(_exactPoints);
  PlotDataPoint? get latestPoint =>
      _exactPoints.isEmpty ? null : _exactPoints.last;
  int? get minJumpPacketIndex =>
      _exactPoints.isEmpty ? null : _exactPoints.first.index;
  int? get maxJumpPacketIndex =>
      _exactPoints.isEmpty ? null : _exactPoints.last.index;
  int get estimatedHistoryBytes =>
      _exactPointsEstimatedBytes + lodIndex.estimatedAllocatedBytes;
  int get historyMemoryLimitBytes => historyMemoryLimitMiB * _bytesPerMiB;
  double get historyMemoryUsageRatio =>
      historyMemoryLimitBytes <= 0
          ? 0
          : (estimatedHistoryBytes / historyMemoryLimitBytes).clamp(0.0, 1.0);
  String? get measurementText {
    final lines = <String>[];
    if (xMeasurementEnabled && xCursor1 != null && xCursor2 != null) {
      lines.addAll([
        'X1 = ${formatPlotValue(xCursor1!)}',
        'X2 = ${formatPlotValue(xCursor2!)}',
        'ΔX = ${formatPlotValue(xCursor2! - xCursor1!)}',
      ]);
    }
    if (yMeasurementEnabled && yCursor1 != null && yCursor2 != null) {
      if (lines.isNotEmpty) lines.add('---');
      lines.addAll([
        'Y1 = ${formatPlotValue(yCursor1!)}',
        'Y2 = ${formatPlotValue(yCursor2!)}',
        'ΔY = ${formatPlotValue(yCursor2! - yCursor1!)}',
      ]);
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  bool get running => service.activityOwner == ProbeActivityOwner.probePlot;
  bool get operationPending => _operationPending;
  int get activeChannelCount => switch (mode) {
    ProbePlotMode.hss => hssVariables.length,
    ProbePlotMode.rtt => _rttActiveChannelCount,
  };

  void _loadDisplaySettings() {
    final settings = AppSettings();
    windowPointLimit = settings.probePlotWindowPointLimit.clamp(
      minWindowPointLimit,
      maxWindowPointLimit,
    );
    historyMemoryLimitMiB = settings.probePlotHistoryMemoryLimitMiB.clamp(
      minHistoryMemoryLimitMiB,
      maxHistoryMemoryLimitMiB,
    );
    lodQuality = switch (settings.probePlotLodQuality) {
      'performance' => PlotLodQuality.performance,
      'balanced' => PlotLodQuality.balanced,
      _ => PlotLodQuality.quality,
    };
    showGrid = settings.probePlotShowGrid;
    gridDensity = switch (settings.probePlotGridDensity) {
      'sparse' => GridDensity.sparse,
      'dense' => GridDensity.dense,
      _ => GridDensity.normal,
    };
    backgroundStyle =
        settings.probePlotBackground == 'dark'
            ? PlotBackgroundStyle.dark
            : PlotBackgroundStyle.light;
    floatingPanelOpacity = settings.probePlotFloatingPanelOpacity;
    plotFontSizeDelta = settings.probePlotFontSizeDelta;
    plotFontBold = settings.probePlotFontBold;
    followPositionRatio = settings.probePlotFollowPositionRatio;
    observationClickToPlace = settings.probePlotObservationClickToPlace;
  }

  void _saveDisplaySettings() {
    final settings = AppSettings();
    settings.probePlotWindowPointLimit = windowPointLimit;
    settings.probePlotHistoryMemoryLimitMiB = historyMemoryLimitMiB;
    settings.probePlotLodQuality = switch (lodQuality) {
      PlotLodQuality.performance => 'performance',
      PlotLodQuality.balanced => 'balanced',
      PlotLodQuality.quality => 'quality',
    };
    settings.probePlotShowGrid = showGrid;
    settings.probePlotGridDensity = gridDensity.name;
    settings.probePlotBackground = backgroundStyle.name;
    settings.probePlotFloatingPanelOpacity = floatingPanelOpacity;
    settings.probePlotFontSizeDelta = plotFontSizeDelta;
    settings.probePlotFontBold = plotFontBold;
    settings.probePlotFollowPositionRatio = followPositionRatio;
    settings.probePlotObservationClickToPlace = observationClickToPlace;
    unawaited(settings.save());
  }

  /// 原子提交探针绘图设置草稿，持久化成功前不改变当前绘图。
  Future<void> applyPlotSettings(PlotUiSettingsDraft draft) async {
    final nextWindow = draft.windowPointLimit.clamp(
      minWindowPointLimit,
      maxWindowPointLimit,
    );
    final nextMemory = draft.historyLimit.clamp(
      minHistoryMemoryLimitMiB,
      maxHistoryMemoryLimitMiB,
    );
    final nextOpacity = draft.floatingPanelOpacity.clamp(0.0, 1.0);
    final nextFollow = draft.followPositionRatio.clamp(0.5, 0.95);
    final nextGridDensity = draft.gridDensity as GridDensity;
    final nextBackground = draft.background as PlotBackgroundStyle;
    final nextQuality = draft.quality as PlotLodQuality;
    final settings = AppSettings();
    final previous = (
      window: settings.probePlotWindowPointLimit,
      history: settings.probePlotHistoryMemoryLimitMiB,
      quality: settings.probePlotLodQuality,
      showGrid: settings.probePlotShowGrid,
      gridDensity: settings.probePlotGridDensity,
      background: settings.probePlotBackground,
      opacity: settings.probePlotFloatingPanelOpacity,
      fontSize: settings.probePlotFontSizeDelta,
      fontBold: settings.probePlotFontBold,
      follow: settings.probePlotFollowPositionRatio,
      observation: settings.probePlotObservationClickToPlace,
    );
    settings
      ..probePlotWindowPointLimit = nextWindow
      ..probePlotHistoryMemoryLimitMiB = nextMemory
      ..probePlotLodQuality = nextQuality.name
      ..probePlotShowGrid = draft.showGrid
      ..probePlotGridDensity = nextGridDensity.name
      ..probePlotBackground = nextBackground.name
      ..probePlotFloatingPanelOpacity = nextOpacity
      ..probePlotFontSizeDelta = draft.fontSizeDelta.clamp(-3, 6)
      ..probePlotFontBold = draft.fontBold
      ..probePlotFollowPositionRatio = nextFollow
      ..probePlotObservationClickToPlace = draft.observationClickToPlace;
    try {
      await settings.save();
    } catch (_) {
      settings
        ..probePlotWindowPointLimit = previous.window
        ..probePlotHistoryMemoryLimitMiB = previous.history
        ..probePlotLodQuality = previous.quality
        ..probePlotShowGrid = previous.showGrid
        ..probePlotGridDensity = previous.gridDensity
        ..probePlotBackground = previous.background
        ..probePlotFloatingPanelOpacity = previous.opacity
        ..probePlotFontSizeDelta = previous.fontSize
        ..probePlotFontBold = previous.fontBold
        ..probePlotFollowPositionRatio = previous.follow
        ..probePlotObservationClickToPlace = previous.observation;
      rethrow;
    }

    windowPointLimit = nextWindow;
    historyMemoryLimitMiB = nextMemory;
    lodQuality = nextQuality;
    showGrid = draft.showGrid;
    gridDensity = nextGridDensity;
    backgroundStyle = nextBackground;
    floatingPanelOpacity = nextOpacity;
    plotFontSizeDelta = draft.fontSizeDelta.clamp(-3, 6);
    plotFontBold = draft.fontBold;
    followPositionRatio = nextFollow;
    observationClickToPlace = draft.observationClickToPlace;
    while (_exactPoints.length > windowPointLimit) {
      final removed = _exactPoints.removeFirst();
      _exactPointsEstimatedBytes -= _estimatePointBytes(removed);
      _pointsByIndex.remove(removed.index);
    }
    _pointsSnapshot = null;
    retentionLimitReached = estimatedHistoryBytes >= historyMemoryLimitBytes;
    if (!observationClickToPlace) {
      observationPlacementActive = false;
      observationPreview = null;
    }
    dataRevision++;
    revision++;
    overlayRevision++;
    notifyListeners();
    if (retentionLimitReached) unawaited(_stopAfterRetentionLimit());
  }

  Future<void> start() async {
    if (running || _operationPending) return;
    _operationPending = true;
    notifyListeners();
    try {
      if (mode == ProbePlotMode.hss) {
        if (programPath.isNotEmpty) {
          final modified = await File(programPath).lastModified();
          if (_programModifiedAt != null && modified != _programModifiedAt) {
            symbols = await service.readProbeSymbols(programPath);
            hssVariables.clear();
            _programModifiedAt = modified;
            notifyListeners();
            throw StateError('程序文件已修改，旧变量地址已失效，请重新选择变量');
          }
        }
        if (hssVariables.isEmpty) {
          throw StateError('HSS 需要先在配置中添加采样变量');
        }
        for (var index = 0; index < channels.length; index++) {
          channels[index].visible = index < hssVariables.length;
          if (index < hssVariables.length) {
            channels[index].alias = hssVariables[index].name;
          }
        }
        channelConfigRevision++;
        clear();
        await service.startHss(hssVariables, frequencyHz: hssFrequencyHz);
        return;
      }

      // 首次进入探针绘图页时也必须从控制块同步通道，不能依赖用户先打开
      // 设置弹窗触发刷新。
      await refreshRttChannels();
      final selected = rttChannels.where(
        (channel) => channel.name == rttChannelName,
      );
      if (selected.isEmpty) {
        throw StateError('RTT Up 通道不存在：$rttChannelName');
      }
      _rttChannelIndex = selected.first.index;
      final format = JScopeFormat.parse(
        rttFormat.startsWith('JScope_') ? rttFormat : 'JScope_$rttFormat',
      );
      _rttParser = JScopeRttParser(format);
      _rttActiveChannelCount = format.fields.length;
      for (var index = 0; index < channels.length; index++) {
        channels[index].visible = index < format.fields.length;
        if (index >= format.fields.length) {
          channels[index].alias = 'Value ${index + 1}';
        }
      }
      channelConfigRevision++;
      clear();
      await service.startRttProbePlot(rttChannelName);
    } finally {
      _operationPending = false;
      notifyListeners();
    }
  }

  Future<void> loadProgram(String path) async {
    final loadedSymbols = await service.readProbeSymbols(path);
    if (programPath.isNotEmpty && programPath != path) {
      hssVariables.clear();
      _syncHssChannels();
    }
    symbols = loadedSymbols;
    programPath = path;
    _programModifiedAt = await File(path).lastModified();
    notifyListeners();
  }

  Future<void> refreshRttChannels() async {
    final pending = _rttRefreshFuture;
    if (pending != null) return pending;
    final operation = _loadRttChannels();
    _rttRefreshFuture = operation;
    try {
      await operation;
    } finally {
      if (identical(_rttRefreshFuture, operation)) {
        _rttRefreshFuture = null;
      }
    }
  }

  Future<void> _loadRttChannels() async {
    final loadedChannels = await service.listRttUpChannels();
    if (!service.isConnected) return;
    rttChannels = loadedChannels;
    if (rttChannels.isEmpty) {
      _rttActiveChannelCount = 0;
      notifyListeners();
      return;
    }
    final currentExists = rttChannels.any(
      (channel) => channel.name == rttChannelName,
    );
    final selected =
        currentExists
            ? rttChannels.firstWhere(
              (channel) => channel.name == rttChannelName,
            )
            : rttChannels.firstWhere(
              (channel) => JScopeFormat.tryParse(channel.name) != null,
              orElse: () => rttChannels.first,
            );
    rttChannelName = selected.name;
    _rttChannelIndex = selected.index;
    final detected = JScopeFormat.tryParse(selected.name);
    if (detected != null) {
      rttFormat = selected.name;
      _rttActiveChannelCount = detected.fields.length;
    } else {
      _rttActiveChannelCount = 0;
    }
    notifyListeners();
  }

  void addHssVariable(ProbeSampleVariable variable) {
    if (hssVariables.length >= 12) throw StateError('最多支持 12 个 HSS 变量');
    if (hssVariables.any((item) => item.address == variable.address)) return;
    hssVariables.add(variable);
    _syncHssChannels();
    notifyListeners();
  }

  void removeHssVariable(int index) {
    hssVariables.removeAt(index);
    _syncHssChannels();
    notifyListeners();
  }

  void setHssVariableType(int index, ProbeScalarType type) {
    final variable = hssVariables[index];
    if (variable.type == type) return;
    hssVariables[index] = ProbeSampleVariable(
      name: variable.name,
      address: variable.address,
      type: type,
    );
    notifyListeners();
  }

  void _syncHssChannels() {
    for (var index = 0; index < channels.length; index++) {
      channels[index].visible = index < hssVariables.length;
      channels[index].alias =
          index < hssVariables.length
              ? hssVariables[index].name
              : 'Value ${index + 1}';
    }
    channelConfigRevision++;
    revision++;
  }

  void setHssFrequency(int value) {
    hssFrequencyHz = value.clamp(1, 5000);
    notifyListeners();
  }

  Future<void> stop() async {
    if (_operationPending) return;
    _operationPending = true;
    notifyListeners();
    try {
      await service.stopActivity();
    } finally {
      _operationPending = false;
      notifyListeners();
    }
  }

  void setMode(ProbePlotMode value) {
    if (running || mode == value) return;
    mode = value;
    notifyListeners();
    if (value == ProbePlotMode.rtt &&
        service.isConnected &&
        rttChannels.isEmpty) {
      unawaited(_refreshRttChannelsAfterConnect());
    }
  }

  void setRttChannelName(String value) {
    if (running) return;
    rttChannelName = value.trim();
    notifyListeners();
  }

  void setRttConfig({required String channelName, required String format}) {
    if (running) return;
    rttChannelName = channelName.trim();
    rttFormat = format.trim();
    _rttChannelIndex = null;
    for (final channel in rttChannels) {
      if (channel.name == rttChannelName) {
        _rttChannelIndex = channel.index;
        break;
      }
    }
    final parsed = JScopeFormat.tryParse(
      rttFormat.startsWith('JScope_') ? rttFormat : 'JScope_$rttFormat',
    );
    _rttActiveChannelCount = parsed?.fields.length ?? 0;
    notifyListeners();
  }

  void _handleRttData(RttDataChunk chunk) {
    if (!running || mode != ProbePlotMode.rtt) return;
    final channelIndex = _rttChannelIndex;
    if (channelIndex != null && chunk.channel != channelIndex) return;
    final parser = _rttParser;
    if (parser == null) return;
    for (final sample in parser.add(chunk.data)) {
      _append(sample.x, sample.values);
    }
  }

  void appendHssSample(ProbeSampleChunk sample) {
    if (!running || mode != ProbePlotMode.hss) return;
    _append(sample.monotonicUs / 1000000.0, sample.values);
  }

  void _handleServiceChanged() {
    final previousSignature = _serviceStateSignature;
    final connected = service.isConnected;
    var channelStateChanged = false;
    if (!connected && _wasConnected) {
      rttChannels = const [];
      _rttChannelIndex = null;
      channelStateChanged = true;
      // RTT 通道枚举属于当前连接，断开后必须失效；但活动通道数量同时用于
      // 渲染已经采集的历史数据。保留它，避免断开探针后曲线消失而光标仍能
      // 查询到底层数据。重新连接后的枚举或配置会再次更新该数量。
    } else if (connected &&
        mode == ProbePlotMode.rtt &&
        (!_wasConnected || rttChannels.isEmpty)) {
      unawaited(_refreshRttChannelsAfterConnect());
    }
    _wasConnected = connected;
    final nextSignature = _currentServiceStateSignature();
    _serviceStateSignature = nextSignature;
    // 后端诊断文本也会触发 ProbeConnectionService 通知，但它与探针绘图页面无关。
    // 这里只响应连接、能力和活动状态变化，避免实时诊断造成整页重建。
    if (channelStateChanged || previousSignature != nextSignature) {
      notifyListeners();
    }
  }

  Object _currentServiceStateSignature() => (
    service.isConnected,
    service.isConnecting,
    service.supportsProbePlot,
    service.activeBackendId,
    service.activityOwner,
  );

  Future<void> _refreshRttChannelsAfterConnect() async {
    if (!service.isConnected || mode != ProbePlotMode.rtt) {
      return;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await refreshRttChannels();
        return;
      } catch (_) {
        if (attempt == 0 && service.isConnected && mode == ProbePlotMode.rtt) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        // 首次开始还会再次刷新并向用户显示最终错误。
      }
    }
  }

  void _append(double x, List<double> values) {
    if (retentionLimitReached) return;
    _firstSourceTime ??= x;
    final relativeTime = x - _firstSourceTime!;
    // 共享绘图核心和 LOD 使用连续样本序号作为内部 X 坐标，真实的 helper
    // 单调相对时间仍保存在 timestamp 中，避免稀疏时间值膨胀 LOD 索引。
    final plotX = pointCount;
    final point = PlotDataPoint(
      index: plotX,
      timestamp: relativeTime * 1000,
      values: values,
    );
    final pointBytes = _estimatePointBytes(point);
    final evictedBytes =
        _exactPoints.length >= windowPointLimit
            ? _estimatePointBytes(_exactPoints.first)
            : 0;
    final projectedBytes =
        estimatedHistoryBytes +
        pointBytes -
        evictedBytes +
        lodIndex.estimatedAdditionalBytesFor(plotX, values.length);
    if (projectedBytes > historyMemoryLimitBytes) {
      retentionLimitReached = true;
      revision++;
      notifyListeners();
      unawaited(_stopAfterRetentionLimit());
      return;
    }

    _exactPoints.add(point);
    _exactPointsEstimatedBytes += pointBytes;
    _pointsByIndex[plotX] = point;
    if (_exactPoints.length > windowPointLimit) {
      final removed = _exactPoints.removeFirst();
      _exactPointsEstimatedBytes -= _estimatePointBytes(removed);
      _pointsByIndex.remove(removed.index);
    }
    _pointsSnapshot = null;
    lodIndex.add(plotX, values);
    pointCount++;
    _updateYRange(values);
    if (follow) {
      final width = viewport.xRange;
      final xMin = plotX - width * followPositionRatio;
      viewport = viewport.copyWith(xMin: xMin, xMax: xMin + width);
    }
    dataRevision++;
    if (follow || _autoFitY) viewportRevision++;
    final firstPoint = pointCount == 1;
    final now = DateTime.now();
    final elapsed = now.difference(_lastRateTime);
    var rateChanged = false;
    if (elapsed.inMilliseconds >= 500) {
      actualRate =
          (pointCount - _lastRateCount) * 1000 / elapsed.inMilliseconds;
      _lastRateCount = pointCount;
      _lastRateTime = now;
      rateChanged = true;
    }
    revision++;
    _notifyOnNextFrame();
    // 点数和速率只需低频刷新状态栏；首点需要立即撤下空数据占位。
    if (firstPoint || rateChanged) notifyListeners();
  }

  int _estimatePointBytes(PlotDataPoint point) {
    // PlotDataPoint、List<double>、Queue 节点和索引 Map 条目的保守近似。
    return 112 + point.values.length * 8;
  }

  Future<void> _stopAfterRetentionLimit() async {
    if (!running || _operationPending) return;
    try {
      await stop();
    } catch (_) {
      // 内存保护已经停止接收新点；后端停止错误由连接状态和后续操作呈现。
    }
  }

  void _updateYRange(List<double> values) {
    for (final value in values) {
      if (!value.isFinite) continue;
      _dataYMin = _dataYMin == null ? value : math.min(_dataYMin!, value);
      _dataYMax = _dataYMax == null ? value : math.max(_dataYMax!, value);
    }
    final min = _dataYMin;
    final max = _dataYMax;
    if (min == null || max == null || !_autoFitY) return;
    _applyDataYRange();
  }

  void _applyDataYRange() {
    final min = _dataYMin;
    final max = _dataYMax;
    if (min == null || max == null) return;
    final span = math.max((max - min).abs(), math.max(max.abs(), 1) * 0.02);
    final padding = span * 0.08;
    viewport = viewport.copyWith(yMin: min - padding, yMax: max + padding);
  }

  void clear() {
    _exactPoints.clear();
    _pointsByIndex.clear();
    _pointsSnapshot = null;
    _exactPointsEstimatedBytes = 0;
    lodIndex.clear();
    pointCount = 0;
    actualRate = 0;
    _firstSourceTime = null;
    _dataYMin = null;
    _dataYMax = null;
    _autoFitY = true;
    cursor = null;
    retentionLimitReached = false;
    observations.clear();
    observationPlacementActive = false;
    observationPreview = null;
    xMeasurementEnabled = false;
    yMeasurementEnabled = false;
    xCursor1 = null;
    xCursor2 = null;
    yCursor1 = null;
    yCursor2 = null;
    _rttParser?.reset();
    dataRevision++;
    revision++;
    overlayRevision++;
    notifyListeners();
  }

  void toggleChannel(int index) {
    channels[index].visible = !channels[index].visible;
    channelConfigRevision++;
    revision++;
    notifyListeners();
  }

  void renameChannel(int index, String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || index < 0 || index >= channels.length) return;
    channels[index].alias = normalized;
    channelConfigRevision++;
    revision++;
    notifyListeners();
  }

  void setFollow(bool value) {
    follow = value;
    if (follow && pointCount > 0) {
      final latestX = (pointCount - 1).toDouble();
      final width = viewport.xRange;
      final xMin = latestX - width * followPositionRatio;
      viewport = viewport.copyWith(xMin: xMin, xMax: xMin + width);
      viewportRevision++;
    }
    notifyListeners();
  }

  void setWindowPointLimit(int value) {
    windowPointLimit = value.clamp(minWindowPointLimit, maxWindowPointLimit);
    while (_exactPoints.length > windowPointLimit) {
      final removed = _exactPoints.removeFirst();
      _exactPointsEstimatedBytes -= _estimatePointBytes(removed);
      _pointsByIndex.remove(removed.index);
    }
    _pointsSnapshot = null;
    _saveDisplaySettings();
    dataRevision++;
    revision++;
    notifyListeners();
  }

  void setHistoryMemoryLimitMiB(int value) {
    historyMemoryLimitMiB = value.clamp(
      minHistoryMemoryLimitMiB,
      maxHistoryMemoryLimitMiB,
    );
    retentionLimitReached = estimatedHistoryBytes >= historyMemoryLimitBytes;
    _saveDisplaySettings();
    notifyListeners();
    if (retentionLimitReached) unawaited(_stopAfterRetentionLimit());
  }

  void setLodQuality(PlotLodQuality value) {
    if (lodQuality == value) return;
    lodQuality = value;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setShowGrid(bool value) {
    if (showGrid == value) return;
    showGrid = value;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setGridDensity(GridDensity value) {
    if (gridDensity == value) return;
    gridDensity = value;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setBackgroundStyle(PlotBackgroundStyle value) {
    if (backgroundStyle == value) return;
    backgroundStyle = value;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setFloatingPanelOpacity(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((next - floatingPanelOpacity).abs() < 0.0001) return;
    floatingPanelOpacity = next;
    _saveDisplaySettings();
    overlayRevision++;
    notifyListeners();
  }

  void setPlotFontSizeDelta(int value) {
    final next = value.clamp(-3, 6);
    if (next == plotFontSizeDelta) return;
    plotFontSizeDelta = next;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setPlotFontBold(bool value) {
    if (plotFontBold == value) return;
    plotFontBold = value;
    _saveDisplaySettings();
    revision++;
    notifyListeners();
  }

  void setFollowPositionRatio(double value) {
    final next = value.clamp(0.5, 0.95);
    if ((next - followPositionRatio).abs() < 0.0001) return;
    followPositionRatio = next;
    _saveDisplaySettings();
    if (follow) setFollow(true);
    notifyListeners();
  }

  void setObservationClickToPlace(bool value) {
    if (observationClickToPlace == value) return;
    observationClickToPlace = value;
    if (!value) {
      observationPlacementActive = false;
      observationPreview = null;
    }
    _saveDisplaySettings();
    overlayRevision++;
    notifyListeners();
  }

  void updateViewport(PlotViewport value, {bool fromDrag = false}) {
    final previous = viewport;
    final yChanged = value.yMin != viewport.yMin || value.yMax != viewport.yMax;
    final xMoved = value.xMin != previous.xMin || value.xMax != previous.xMax;
    final yMoved = value.yMin != previous.yMin || value.yMax != previous.yMax;
    final preservesRange =
        (value.xRange - previous.xRange).abs() <=
            math.max(1, previous.xRange.abs()) * 1e-9 &&
        (value.yRange - previous.yRange).abs() <=
            math.max(1, previous.yRange.abs()) * 1e-9;
    viewport = value;
    if (fromDrag && preservesRange && (xMoved || yMoved)) {
      follow = false;
    }
    if (yChanged) _autoFitY = false;
    viewportRevision++;
    revision++;
    notifyListeners();
  }

  void zoomXIn() => _zoomX(0.8);

  void zoomXOut() => _zoomX(1.25);

  void zoomYIn() => _zoomY(0.8);

  void zoomYOut() => _zoomY(1.25);

  void _zoomX(double factor) {
    final center = viewport.xMin + viewport.xRange / 2;
    updateViewport(viewport.zoomX(factor, center));
  }

  void _zoomY(double factor) {
    final center = viewport.yMin + viewport.yRange / 2;
    updateViewport(viewport.zoomY(factor, center));
  }

  void setVCursorEnabled(bool value) {
    vCursorEnabled = value;
    cursor = null;
    overlayRevision++;
    notifyListeners();
  }

  Color? get xMeasurementLine1Color {
    final value = AppSettings().xMeasurementLine1Color;
    return value == null ? null : Color(value);
  }

  Color? get xMeasurementLine2Color {
    final value = AppSettings().xMeasurementLine2Color;
    return value == null ? null : Color(value);
  }

  Color? get yMeasurementLine1Color {
    final value = AppSettings().yMeasurementLine1Color;
    return value == null ? null : Color(value);
  }

  Color? get yMeasurementLine2Color {
    final value = AppSettings().yMeasurementLine2Color;
    return value == null ? null : Color(value);
  }

  double get xMeasurementLine1Opacity => AppSettings().xMeasurementLine1Opacity;
  double get xMeasurementLine2Opacity => AppSettings().xMeasurementLine2Opacity;
  double get yMeasurementLine1Opacity => AppSettings().yMeasurementLine1Opacity;
  double get yMeasurementLine2Opacity => AppSettings().yMeasurementLine2Opacity;
  bool get yMeasurementSnapEnabled => AppSettings().yMeasurementSnapEnabled;

  void toggleXMeasurement() {
    xMeasurementEnabled = !xMeasurementEnabled;
    if (xMeasurementEnabled && xCursor1 == null) {
      final range = viewport.xRange;
      final center = viewport.xMin + range / 2;
      xCursor1 =
          _nearestPoint(center - range / 8)?.index.toDouble() ??
          center - range / 8;
      xCursor2 =
          _nearestPoint(center + range / 8)?.index.toDouble() ??
          center + range / 8;
    } else if (!xMeasurementEnabled) {
      xCursor1 = null;
      xCursor2 = null;
    }
    overlayRevision++;
    notifyListeners();
  }

  void toggleYMeasurement() {
    yMeasurementEnabled = !yMeasurementEnabled;
    if (yMeasurementEnabled && yCursor1 == null) {
      final range = viewport.yRange;
      final center = viewport.yMin + range / 2;
      yCursor1 = center - range / 8;
      yCursor2 = center + range / 8;
    } else if (!yMeasurementEnabled) {
      yCursor1 = null;
      yCursor2 = null;
    }
    overlayRevision++;
    notifyListeners();
  }

  void setXCursor1(double value) {
    xCursor1 = _nearestPoint(value)?.index.toDouble() ?? value;
    overlayRevision++;
    notifyListeners();
  }

  void setXCursor2(double value) {
    xCursor2 = _nearestPoint(value)?.index.toDouble() ?? value;
    overlayRevision++;
    notifyListeners();
  }

  void setYCursor1(double value) {
    yCursor1 = value;
    overlayRevision++;
    notifyListeners();
  }

  void setYCursor2(double value) {
    yCursor2 = value;
    overlayRevision++;
    notifyListeners();
  }

  void setXMeasurementStyle({
    required Color line1Color,
    required double line1Opacity,
    required Color line2Color,
    required double line2Opacity,
  }) {
    final settings = AppSettings();
    settings.xMeasurementLine1Color = line1Color.toARGB32();
    settings.xMeasurementLine2Color = line2Color.toARGB32();
    settings.xMeasurementLine1Opacity = line1Opacity.clamp(0.0, 1.0);
    settings.xMeasurementLine2Opacity = line2Opacity.clamp(0.0, 1.0);
    unawaited(settings.save());
    overlayRevision++;
    notifyListeners();
  }

  void setYMeasurementStyle({
    required Color line1Color,
    required double line1Opacity,
    required Color line2Color,
    required double line2Opacity,
  }) {
    final settings = AppSettings();
    settings.yMeasurementLine1Color = line1Color.toARGB32();
    settings.yMeasurementLine2Color = line2Color.toARGB32();
    settings.yMeasurementLine1Opacity = line1Opacity.clamp(0.0, 1.0);
    settings.yMeasurementLine2Opacity = line2Opacity.clamp(0.0, 1.0);
    unawaited(settings.save());
    overlayRevision++;
    notifyListeners();
  }

  void setYMeasurementSnapEnabled(bool value) {
    AppSettings().yMeasurementSnapEnabled = value;
    unawaited(AppSettings().save());
    overlayRevision++;
    notifyListeners();
  }

  void addObservation() {
    if (_exactPoints.isEmpty || observations.length >= maxObservationCount) {
      return;
    }
    final sourceX =
        cursor != null && viewport.isVisibleX(cursor!.x)
            ? cursor!.x
            : viewport.xMin + viewport.xRange / 2;
    _addObservationAtX(sourceX);
  }

  void startObservationPlacement() {
    if (_exactPoints.isEmpty || observations.length >= maxObservationCount) {
      return;
    }
    observationPlacementActive = true;
    observationPreview = null;
    overlayRevision++;
    notifyListeners();
  }

  void updateObservationPlacement(double x) {
    if (!observationPlacementActive) return;
    observationPreview = PlotObservation(cursor: _cursorAtX(x));
    overlayRevision++;
    _notifyOnNextFrame();
  }

  void commitObservationPlacement(double x) {
    if (!observationPlacementActive) return;
    _addObservationAtX(x);
    observationPlacementActive = false;
    observationPreview = null;
    overlayRevision++;
    notifyListeners();
  }

  void updateObservation(int index, double x) {
    if (index < 0 || index >= observations.length) return;
    if (observations[index].locked) return;
    observations[index] = observations[index].copyWith(cursor: _cursorAtX(x));
    overlayRevision++;
    notifyListeners();
  }

  void updateObservationNote(int index, String note) {
    if (index < 0 || index >= observations.length) return;
    observations[index] = observations[index].copyWith(note: note);
    overlayRevision++;
    notifyListeners();
  }

  void setObservationLocked(int index, bool locked) {
    if (index < 0 || index >= observations.length) return;
    observations[index] = observations[index].copyWith(locked: locked);
    overlayRevision++;
    notifyListeners();
  }

  void removeObservation(int index) {
    if (index < 0 || index >= observations.length) return;
    observations.removeAt(index);
    overlayRevision++;
    notifyListeners();
  }

  void jumpToObservation(int index) {
    if (index < 0 || index >= observations.length) return;
    jumpToPacketIndex(observations[index].x.round());
  }

  void _addObservationAtX(double x) {
    if (observations.length >= maxObservationCount) return;
    observations.add(PlotObservation(cursor: _cursorAtX(x)));
    overlayRevision++;
    notifyListeners();
  }

  CursorState _cursorAtX(double x) {
    final point = _nearestPoint(x);
    return CursorState(
      x: point?.index.toDouble() ?? x,
      channelValues: point?.values,
      hasData: point != null,
    );
  }

  bool canJumpToPacketIndex(int index) {
    final min = minJumpPacketIndex;
    final max = maxJumpPacketIndex;
    return min != null && max != null && index >= min && index <= max;
  }

  void jumpToPacketIndex(int index) {
    if (!canJumpToPacketIndex(index)) return;
    final halfRange = viewport.xRange / 2;
    viewport = viewport.copyWith(
      xMin: index - halfRange,
      xMax: index + halfRange,
    );
    viewportRevision++;
    revision++;
    notifyListeners();
  }

  void updateCursor(CursorState? value) {
    if (!vCursorEnabled || value == null) {
      if (cursor == null) return;
      cursor = null;
    } else {
      final point = _nearestPoint(value.x);
      cursor = CursorState(
        x: point?.index.toDouble() ?? value.x,
        y: value.y,
        screenPosition: value.screenPosition,
        channelValues: point?.values,
        hasData: point != null,
      );
    }
    overlayRevision++;
    _notifyOnNextFrame();
  }

  PlotDataPoint? _nearestPoint(double x) {
    if (_exactPoints.isEmpty) return null;
    final first = _exactPoints.first.index;
    final last = _exactPoints.last.index;
    final index = x.round().clamp(first, last).toInt();
    return _pointsByIndex[index];
  }

  void _notifyOnNextFrame() {
    if (_disposed || _frameNotificationTimer != null) return;
    _frameNotificationTimer = Timer(const Duration(milliseconds: 16), () {
      _frameNotificationTimer = null;
      if (!_disposed) _renderNotifier.value++;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _frameNotificationTimer?.cancel();
    _frameNotificationTimer = null;
    service.removeListener(_handleServiceChanged);
    unawaited(_subscription.cancel());
    unawaited(_sampleSubscription.cancel());
    _renderNotifier.dispose();
    super.dispose();
  }
}
