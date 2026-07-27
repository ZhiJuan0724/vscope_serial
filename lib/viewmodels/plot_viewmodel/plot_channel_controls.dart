part of '../plot_viewmodel.dart';

extension PlotViewModelChannelControls on PlotViewModel {
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
    return _mathEngine.validate(expression);
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
    if (!channel.display.offsetEnabled) {
      channel.display.offsetBindingGroupId = null;
      _cleanupOffsetBindingGroups();
    }
    _compileMathChannel(channel);
    _invalidateDisplayCaches();
    _rebuildObservedRawValueMetadata();
    _markChannelConfigChanged();
    _saveSettings();
    unawaited(Future.microtask(() => notifyListeners()));
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
    _mathEngine.remove(index);
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
    _mathEngine.clear();
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
    if (index >= PlotConfiguration.rawChannelCount &&
        index < PlotConfiguration.rawChannelCount + mathChannels.length) {
      final display =
          mathChannels[index - PlotConfiguration.rawChannelCount].display;
      final groupId = display.offsetBindingGroupId;
      if (groupId != null) {
        _setOffsetBindingGroupScale(groupId, scale);
      } else {
        display.yScale = scale;
      }
      _invalidateDisplayChannelCaches();
      _markChannelConfigChanged();
      Future.microtask(() => notifyListeners());
      return;
    }
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
    final nextKey = PlotViewModel._presetAddressKey(
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

    final total = _historyStore.zobowFrameCount;
    if (total > 0) {
      final visibleStart = _visibleStartIndex;
      final visibleCount = _dataPoints.length;
      final stopwatch = Stopwatch()..start();
      _historyStore.clearLod();
      const batchSize = 4096;
      for (int packetIndex = 0; packetIndex < total; packetIndex++) {
        final frame = _historyStore.readZobowFrame(packetIndex);
        _historyStore.addLod(
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

    unawaited(Future.microtask(() => notifyListeners()));
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
    unawaited(Future.microtask(() => notifyListeners()));
    return true;
  }
}
