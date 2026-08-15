part of '../plot_viewmodel.dart';

extension PlotViewModelInteractionControls on PlotViewModel {
  /// 设置跟随开关
  void setFollowEnabled(bool value) {
    _followEnabled = value;
    if (value && _historyPointCount > 0) {
      _setViewport(_followViewportForLatestIndex(_latestFollowIndex()));
      _loadTailWindow();
    }
    _saveSettings();
    Future.microtask(notifyListeners);
  }

  /// 设置单垂直光标开关
  ///
  /// 光标开关为临时功能，不保存到配置。
  void setVCursorEnabled(bool value) {
    _vCursorEnabled = value;
    _cursor = null;
    _markOverlayChanged();
    Future.microtask(notifyListeners);
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
    Future.microtask(notifyListeners);
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
    Future.microtask(notifyListeners);
  }
}
