part of '../plot_viewmodel.dart';

/// PlotViewModel 的众邦/R 协议配置文件管理能力。
extension PlotViewModelProfiles on PlotViewModel {
  // ========== 众邦电控配置文件操作 ==========

  /// 选择配置文件
  void selectZobowProfile(String? profileId) {
    _profileService.selectProfile(profileId);
    // 保存到设置
    final settings = AppSettings();
    settings.zobowProfileId = profileId ?? '';
    settings.save();
    _notifyLater();
  }

  /// 创建新配置文件
  Future<ZobowConfigProfile?> createZobowProfile(String name) async {
    final profile = await _profileService.createProfile(name);
    _notifyLater();
    return profile;
  }

  /// 更新配置文件
  Future<void> updateZobowProfile(ZobowConfigProfile profile) async {
    await _profileService.updateProfile(profile);
    _notifyLater();
  }

  /// 删除配置文件
  Future<void> deleteZobowProfile(String id) async {
    await _profileService.deleteProfile(id);
    _notifyLater();
  }

  /// 应用预设到指定通道
  void applyPresetToChannel(int channelIndex, ZobowChannelPreset preset) {
    if (channelIndex < 0 || channelIndex >= _parserConfig.zobowChannelCount) {
      return;
    }
    _parserConfig.zobowChannelIds[channelIndex] = preset.address & 0xFFFFFFFF;
    // 同时设置通道别名
    if (preset.name.isNotEmpty && channelIndex < channels.length) {
      channels[channelIndex].alias = preset.name;
    }
    _notifyLater();
  }

  /// 重新加载配置文件列表
  Future<void> reloadZobowProfiles() async {
    await _profileService.reload();
    _notifyLater();
  }

  void selectRProfile(String? profileId) {
    _rProfileService.selectProfile(profileId);
    _saveSettings();
    _notifyLater();
  }

  Future<ZobowConfigProfile?> createRProfile(String name) async {
    final profile = await _rProfileService.createProfile(name);
    _notifyLater();
    return profile;
  }

  Future<void> updateRProfile(ZobowConfigProfile profile) async {
    await _rProfileService.updateProfile(profile);
    _notifyLater();
  }

  Future<void> deleteRProfile(String id) async {
    await _rProfileService.deleteProfile(id);
    _saveSettings();
    _notifyLater();
  }

  void applyRProtocolPresetToChannel(
    int channelIndex,
    ZobowChannelPreset preset,
  ) {
    if (channelIndex < 0 ||
        channelIndex >= SendProtocolConfig.maxChannelCount) {
      return;
    }
    final previous = _sendProtocolConfig.rChannelAddresses[channelIndex];
    final useHex = previous.trim().toLowerCase().startsWith('0x');
    _sendProtocolConfig.rChannelAddresses[channelIndex] =
        useHex
            ? '0x${preset.address.toRadixString(16).toUpperCase()}'
            : '${preset.address}';
    if (preset.name.isNotEmpty && channelIndex < channels.length) {
      channels[channelIndex].alias = preset.name;
    }
    _saveSettings();
    _notifyLater();
  }
}
