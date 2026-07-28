import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models/channel_config.dart';
import '../data/models/plot_data.dart';
import '../data/models/plot_lod_index.dart';
import '../data/models/probe_plot_config.dart';
import '../data/models/rtt_config.dart';
import '../services/j_scope_rtt_parser.dart';
import '../services/rtt_service.dart';
import '../views/plot/plot_render_snapshot.dart';
import '../views/plot/plot_viewport.dart';

/// 探针绘图的独立历史、LOD 和视口状态，不依赖串口绘图 ViewModel。
class ProbePlotViewModel extends ChangeNotifier {
  ProbePlotViewModel(this.service) {
    service.addListener(_handleServiceChanged);
    _subscription = service.probePlotData.listen(_handleRttData);
    _sampleSubscription = service.probeSamples.listen(appendHssSample);
    _wasConnected = service.isConnected;
    if (_wasConnected) {
      scheduleMicrotask(_refreshRttChannelsAfterConnect);
    }
  }

  static const int _exactPointLimit = 100000;
  final RttService service;
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
  int revision = 0;
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
  Timer? _frameNotificationTimer;
  bool _disposed = false;

  List<PlotDataPoint> get points =>
      _pointsSnapshot ??= List.unmodifiable(_exactPoints);
  PlotDataPoint? get latestPoint =>
      _exactPoints.isEmpty ? null : _exactPoints.last;
  int? get minJumpPacketIndex =>
      _exactPoints.isEmpty ? null : _exactPoints.first.index;
  int? get maxJumpPacketIndex =>
      _exactPoints.isEmpty ? null : _exactPoints.last.index;
  bool get running => service.activityOwner == ProbeActivityOwner.probePlot;
  bool get operationPending => _operationPending;
  int get activeChannelCount => switch (mode) {
    ProbePlotMode.hss => hssVariables.length,
    ProbePlotMode.rtt => _rttActiveChannelCount,
  };
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
    final connected = service.isConnected;
    if (!connected && _wasConnected) {
      rttChannels = const [];
      _rttChannelIndex = null;
      // RTT 通道枚举属于当前连接，断开后必须失效；但活动通道数量同时用于
      // 渲染已经采集的历史数据。保留它，避免断开探针后曲线消失而光标仍能
      // 查询到底层数据。重新连接后的枚举或配置会再次更新该数量。
    } else if (connected &&
        mode == ProbePlotMode.rtt &&
        (!_wasConnected || rttChannels.isEmpty)) {
      unawaited(_refreshRttChannelsAfterConnect());
    }
    _wasConnected = connected;
    notifyListeners();
  }

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
    _exactPoints.add(point);
    _pointsByIndex[plotX] = point;
    if (_exactPoints.length > _exactPointLimit) {
      final removed = _exactPoints.removeFirst();
      _pointsByIndex.remove(removed.index);
    }
    _pointsSnapshot = null;
    lodIndex.add(plotX, values);
    pointCount++;
    _updateYRange(values);
    if (follow) {
      final width = viewport.xRange;
      viewport = viewport.copyWith(xMin: plotX - width, xMax: plotX.toDouble());
    }
    final now = DateTime.now();
    final elapsed = now.difference(_lastRateTime);
    if (elapsed.inMilliseconds >= 500) {
      actualRate =
          (pointCount - _lastRateCount) * 1000 / elapsed.inMilliseconds;
      _lastRateCount = pointCount;
      _lastRateTime = now;
    }
    revision++;
    _notifyOnNextFrame();
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
    lodIndex.clear();
    pointCount = 0;
    actualRate = 0;
    _firstSourceTime = null;
    _dataYMin = null;
    _dataYMax = null;
    _autoFitY = true;
    cursor = null;
    _rttParser?.reset();
    revision++;
    overlayRevision++;
    notifyListeners();
  }

  void toggleChannel(int index) {
    channels[index].visible = !channels[index].visible;
    revision++;
    notifyListeners();
  }

  void renameChannel(int index, String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || index < 0 || index >= channels.length) return;
    channels[index].alias = normalized;
    revision++;
    notifyListeners();
  }

  void setFollow(bool value) {
    follow = value;
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
      if (!_disposed) notifyListeners();
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
    super.dispose();
  }
}
