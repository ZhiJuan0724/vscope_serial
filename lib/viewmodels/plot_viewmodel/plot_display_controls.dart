part of '../plot_viewmodel.dart';

extension PlotViewModelDisplayControls on PlotViewModel {
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

  void setXMeasurementStyle({
    required Color line1Color,
    required double line1Opacity,
    required Color line2Color,
    required double line2Opacity,
  }) {
    _xMeasurementLine1Color = _opaqueMeasurementColor(line1Color);
    _xMeasurementLine2Color = _opaqueMeasurementColor(line2Color);
    _xMeasurementLine1Opacity = line1Opacity.clamp(0.0, 1.0).toDouble();
    _xMeasurementLine2Opacity = line2Opacity.clamp(0.0, 1.0).toDouble();
    _refreshSnapHighlightColors();
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setYMeasurementStyle({
    required Color line1Color,
    required double line1Opacity,
    required Color line2Color,
    required double line2Opacity,
  }) {
    _yMeasurementLine1Color = _opaqueMeasurementColor(line1Color);
    _yMeasurementLine2Color = _opaqueMeasurementColor(line2Color);
    _yMeasurementLine1Opacity = line1Opacity.clamp(0.0, 1.0).toDouble();
    _yMeasurementLine2Opacity = line2Opacity.clamp(0.0, 1.0).toDouble();
    _refreshSnapHighlightColors();
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  void setYMeasurementSnapEnabled(bool value) {
    if (_yMeasurementSnapEnabled == value) return;
    _yMeasurementSnapEnabled = value;
    if (value) {
      _refreshSnapHighlightColors();
    } else {
      _yCursor1SnapHighlights = const [];
      _yCursor2SnapHighlights = const [];
    }
    _markOverlayChanged();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  Color _opaqueMeasurementColor(Color color) =>
      Color(0xFF000000 | (color.toARGB32() & 0x00FFFFFF));

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

  /// 设置单次绘图历史内存上限。
  ///
  /// 调低到当前已用量以下时立即进入容量停止状态；调高后若已有
  /// 历史仍在新上限内，则重新允许继续绘图。
  void setPlotRetentionLimitGiB(int value) {
    final nextGiB = value.clamp(
      PlotConfiguration.minHistoryMemoryLimitGiB,
      PlotConfiguration.maxHistoryMemoryLimitGiB,
    );
    final nextBytes = nextGiB * PlotConfiguration.bytesPerGiB;
    if (nextBytes == _plotRetentionLimitBytes) return;
    _plotRetentionLimitBytes = nextBytes;
    _saveSettings();

    if (_estimatedPlotAllocatedBytes >= _plotRetentionLimitBytes) {
      _resetPlotRetentionState();
      _reachPlotRetentionLimit(
        '绘图历史已达到 ${_formatRetentionBytes(_plotRetentionLimitBytes)} 上限，绘图已停止',
      );
      return;
    }

    _resetPlotRetentionState();
    _updatePlotRetentionWarning();
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
    final next =
        points
            .clamp(
              PlotViewModel.minVisiblePoints,
              PlotViewModel.maxVisiblePointsLimit,
            )
            .toInt();
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
    final next =
        count.clamp(0, PlotViewModel.maxDiscardInitialPacketCount).toInt();
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
    final evaluation = _triggerRuntime.process(
      item: point,
      value: _canUseTriggerChannel(triggerChannelIndex) ? currentValue : null,
      enabled: _triggerConfig.enabled,
      hitThreshold: _triggerConfig.hitThreshold,
      triggerLimit: _triggerConfig.triggerLimit,
      stopAtLimit: _triggerConfig.action != PlotTriggerAction.markOnly,
      postStopItemCount:
          _triggerConfig.action == PlotTriggerAction.stopAfterPackets
              ? _triggerConfig.postTriggerPacketCount
              : 0,
      matches: _matchesTriggerCondition,
    );
    if (evaluation.stopRequested && !evaluation.thresholdReached) {
      _requestTriggerStop();
      return;
    }
    if (!evaluation.thresholdReached) return;

    final note = _buildTriggerObservationNote(now);
    _addTriggerObservations(evaluation.hitItems, note);

    if (!evaluation.limitReached) {
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
    final value = _mathEngine.evaluateValues(mathIndex, point.values);
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
    parts.add('第 ${_triggerRuntime.triggeredCount} 次触发');
    return parts.join('，');
  }

  String _formatTriggerTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  void _requestTriggerStop() {
    if (_triggerStopDispatchScheduled) return;
    _triggerStopDispatchScheduled = true;
    _triggerRuntime.requestStop();
    _triggerConfig.enabled = false;
    Future.microtask(() {
      if (!_disposed) unawaited(stopPlotting());
    });
  }

  void _resetTriggerRuntimeState() {
    _triggerRuntime.reset();
    _triggerStopDispatchScheduled = false;
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
    if (_observations.length >= PlotViewModel.maxObservationCount) return false;
    var nextNote = note;
    if (_observations.length + 1 == PlotViewModel.maxObservationCount) {
      nextNote = _appendObservationLimitNote(nextNote);
    }
    _observations.add(
      PlotObservation(cursor: _buildObservationCursorAtX(x), note: nextNote),
    );
    return true;
  }

  bool _addObservationFromPoint(PlotDataPoint point, {String note = ''}) {
    if (_observations.length >= PlotViewModel.maxObservationCount) return false;
    var nextNote = note;
    if (_observations.length + 1 == PlotViewModel.maxObservationCount) {
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
    return _observationAssembler.fromPoint(
      point: point,
      rawChannelCount: rawDisplayChannelCount,
      mathChannels: mathChannels,
      mathEngine: _mathEngine,
    );
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

  PlotDataPoint? _displayPointAtHistoryIndex(int pointIndex) {
    if (pointIndex < 0 || pointIndex >= _historyPointCount) return null;
    final rawValues = _rawValuesAtHistoryIndex(pointIndex);
    final rawCount = rawDisplayChannelCount.clamp(0, channels.length).toInt();
    final values = <double>[
      for (var i = 0; i < rawCount; i++)
        i < rawValues.length ? rawValues[i] : double.nan,
    ];
    for (final channel in mathChannels) {
      if (!channel.enabled) continue;
      values.add(
        _mathEngine.evaluateAt(
          channelIndex: channel.index,
          currentIndex: pointIndex,
          pointCount: _historyPointCount,
          valueAt: _rawHistoryValueAt,
        ),
      );
    }
    return PlotDataPoint(
      index: pointIndex,
      timestamp: pointIndex.toDouble(),
      values: values,
    );
  }

  PlotDataPoint? _nearestVisiblePointByX(double x) {
    if (_historyPointCount <= 0) return null;
    final first = math.max(0, viewport.xMin.ceil());
    final last = math.min(_historyPointCount - 1, viewport.xMax.floor());
    if (first > last) return null;
    return _displayPointAtHistoryIndex(x.round().clamp(first, last).toInt());
  }

  double _snapXToNearestVisiblePoint(double x) {
    return _nearestVisiblePointByX(x)?.index.toDouble() ??
        x.clamp(viewport.xMin, viewport.xMax).toDouble();
  }
}
