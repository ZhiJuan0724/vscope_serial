part of '../plot_viewmodel.dart';

extension PlotViewModelViewportControls on PlotViewModel {
  // ========== 视口控制（带历史记录） ==========
  /// 保存当前视口到历史记录栈（用于撤回）
  void _saveViewport() {
    _viewportHistory.add(viewport.copy());
    if (_viewportHistory.length > PlotViewModel._maxHistory) {
      _viewportHistory.removeAt(0);
    }
  }

  /// 更新视口并保存到历史记录
  ///
  /// [fromDrag] 为 true 时表示来自用户拖动交互，跳过配置保存和
  /// 历史记录，避免频繁文件写入导致的卡顿。拖动结束后再统一保存。
  void updateViewport(
    PlotViewport newViewport, {
    bool fromDrag = false,
    bool preserveFollow = false,
  }) => _updateViewport(
    newViewport,
    fromDrag: fromDrag,
    preserveFollow: preserveFollow,
    alreadyFramePaced: false,
  );

  /// 接收已经由视图层 Ticker 按目标刷新率放行的连续交互视口。
  ///
  /// 此路径直接通知 UI，不再经过 ViewModel 的下一帧合并。定位条等其它
  /// [fromDrag] 来源仍使用 [updateViewport] 的原有合帧保护。
  void updateFramePacedViewport(
    PlotViewport newViewport, {
    bool preserveFollow = false,
  }) => _updateViewport(
    newViewport,
    fromDrag: true,
    preserveFollow: preserveFollow,
    alreadyFramePaced: true,
  );

  void _updateViewport(
    PlotViewport newViewport, {
    required bool fromDrag,
    required bool preserveFollow,
    required bool alreadyFramePaced,
  }) {
    // 保存当前的偏移通道列宽，避免 copy() 丢失
    final offsetAxisColumnWidths = viewport.offsetAxisColumnWidths;
    if (!fromDrag) {
      _dragStartViewport = null;
      _cancelPendingDragViewportNotification();
      _cancelDragWindowLoad();
    } else {
      _dragStartViewport ??= viewport.copy();
    }
    if (fromDrag && !preserveFollow && _followEnabled) {
      _followEnabled = false;
    }
    if (!fromDrag) {
      _saveViewport();
    }
    final normalizedViewport = newViewport.normalizedY(fallback: viewport);
    _setViewport(_limitXRange(normalizedViewport, previous: viewport).copy());
    viewport.setOffsetAxisColumnWidths(offsetAxisColumnWidths);
    if (fromDrag) {
      _scheduleDragWindowLoad();
    } else {
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
      if (alreadyFramePaced) {
        notifyListeners();
      } else {
        _notifyDragViewportAtNextFrame();
      }
    } else {
      Future.microtask(notifyListeners);
    }
  }

  /// 拖动结束后保存视口配置
  ///
  /// 在 PlotGestureHandler._handlePointerUp 中调用，将拖动期间的
  /// 最终视口保存到配置和历史记录。
  void saveDragViewport() {
    _cancelPendingDragViewportNotification();
    _cancelDragWindowLoad();
    final start = _dragStartViewport;
    _dragStartViewport = null;
    if (start != null) {
      _viewportHistory.add(start);
      if (_viewportHistory.length > PlotViewModel._maxHistory) {
        _viewportHistory.removeAt(0);
      }
    }
    _loadWindowForViewport();
    _refreshSnapHighlightColors();
    _saveSettings();
    AppLogger().trace(
      'saveDragViewport: xMin=${viewport.xMin.toStringAsFixed(1)}',
      category: 'PLOT',
    );
    Future.microtask(notifyListeners);
  }

  /// 定位条拖动期间只在鼠标短暂停顿后换载精确窗口。
  ///
  /// 连续移动时由 LOD 提供有界预览，避免每个指针事件都解析
  /// 一整块精确数据；停住不松手也会自动补齐当前位置。
  void _scheduleDragWindowLoad() {
    if (_historyPointCount == 0 || _plotInteractionActive) return;
    _windowProvider.scheduleDragLoad(_loadWindowForViewport);
  }

  void _cancelDragWindowLoad() {
    _windowProvider.cancelDragLoad();
  }

  /// 指针事件可能高于显示器刷新率；拖动时只在下一帧通知 UI，
  /// 始终使用此帧收到的最新视口，避免主图重绘任务堆积。
  ///
  /// 帧调度由组合根注入的 [_postFrameCallback] 完成；纯逻辑场景使用 no-op
  /// 实现时不会触发通知，`_dragViewportNotifyScheduled` 直到下次取消才会复位。
  void _notifyDragViewportAtNextFrame() {
    if (_dragViewportNotifyScheduled) return;
    _dragViewportNotifyScheduled = true;
    final generation = _dragViewportNotifyGeneration;
    _postFrameCallback(() {
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
    Future.microtask(notifyListeners);
  }

  /// 撤回上次缩放
  void undoZoom() {
    if (_viewportHistory.isEmpty) return;
    final previous = _viewportHistory.removeLast();
    _setViewport(_limitXRange(previous).copy());
    _loadWindowForViewport();
    _saveSettings();
    Future.microtask(notifyListeners);
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

  (double, double)? _lodDisplayYRange(double xMin, double xMax) {
    if (_historyStore.lodSource.isEmpty || xMax <= xMin) return null;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (final channel in displayChannels) {
      if (!channel.visible || channel.offsetEnabled) continue;
      final series = _historyStore.queryLod(
        channelIndex: channel.index,
        xMin: xMin,
        xMax: xMax,
        plotWidth: 2048,
        quality: _lodQuality,
      );
      if (series == null) continue;
      for (final value in series.values) {
        if (!value.isFinite) continue;
        final displayValue = value * channel.yScale + channel.yOffset;
        if (displayValue < minY) minY = displayValue;
        if (displayValue > maxY) maxY = displayValue;
      }
    }
    return minY == double.infinity || maxY == double.negativeInfinity
        ? null
        : (minY, maxY);
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
    Future.microtask(notifyListeners);
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
    Future.microtask(notifyListeners);
  }

  /// Y 轴放大
  void zoomYIn() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    _setViewport(viewport.zoomY(0.8, centerY));
    _saveSettings();
    Future.microtask(notifyListeners);
  }

  /// Y 轴缩小
  void zoomYOut() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    _setViewport(viewport.zoomY(1.25, centerY));
    _saveSettings();
    Future.microtask(notifyListeners);
  }

  /// 设置框选放大开关；连续模式需要手动关闭，单次模式在框选成功后关闭。
  void setBoxZoomEnabled(bool value, {bool continuous = false}) {
    _boxZoomEnabled = value;
    _boxZoomContinuous = value && continuous;
    Future.microtask(notifyListeners);
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
    final lodRange =
        viewport.xRange > effectiveMaterializedPointLimit
            ? _lodDisplayYRange(viewport.xMin, viewport.xMax)
            : null;
    if (lodRange != null) {
      (minY, maxY) = lodRange;
    } else {
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
    Future.microtask(notifyListeners);
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
    Future.microtask(notifyListeners);
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
    final lodRange =
        maxX - minX > effectiveMaterializedPointLimit
            ? _lodDisplayYRange(minX, maxX)
            : null;
    if (lodRange != null) {
      (minY, maxY) = lodRange;
    } else {
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
    Future.microtask(notifyListeners);
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
}
