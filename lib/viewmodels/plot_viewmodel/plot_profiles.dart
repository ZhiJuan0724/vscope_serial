part of '../plot_viewmodel.dart';

/// PlotViewModel 的众邦/R 协议配置文件管理能力。
extension PlotViewModelProfiles on PlotViewModel {
  // ========== 众邦电控配置文件操作 ==========

  /// 选择配置文件
  void selectZobowProfile(String? profileId) {
    _profileService.selectProfile(profileId);
    _profileRevision++;
    // 保存到设置
    final settings = AppSettings();
    settings.zobowProfileId = profileId ?? '';
    settings.save();
    AppLogger().info(
      'Zobow配置切换为 ${_profileService.selectedProfile?.name ?? '<不使用配置>'}',
      category: 'PLOT',
    );
    _notifyLater();
  }

  /// 创建新配置文件
  Future<ZobowConfigProfile?> createZobowProfile(String name) async {
    final profile = await _profileService.createProfile(name);
    _profileRevision++;
    AppLogger().info('新增Zobow配置：${profile.name}', category: 'PLOT');
    _notifyLater();
    return profile;
  }

  /// 更新配置文件
  Future<void> updateZobowProfile(ZobowConfigProfile profile) async {
    await _profileService.updateProfile(profile);
    _profileRevision++;
    AppLogger().info('更新Zobow配置：${profile.name}', category: 'PLOT');
    _notifyLater();
  }

  /// 删除配置文件
  Future<void> deleteZobowProfile(String id) async {
    String? name;
    for (final profile in _profileService.profiles) {
      if (profile.id == id) {
        name = profile.name;
        break;
      }
    }
    await _profileService.deleteProfile(id);
    _profileRevision++;
    AppLogger().info('删除Zobow配置：${name ?? id}', category: 'PLOT');
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
    _profileRevision++;
    AppLogger().info(
      '重新加载Zobow配置列表，共${_profileService.profiles.length}项',
      category: 'PLOT',
    );
    _notifyLater();
  }

  void selectRProfile(String? profileId) {
    _rProfileService.selectProfile(profileId);
    _profileRevision++;
    _saveSettings();
    AppLogger().info(
      'r协议配置切换为 ${_rProfileService.selectedProfile?.name ?? '<不使用配置>'}',
      category: 'PLOT',
    );
    _notifyLater();
  }

  Future<ZobowConfigProfile?> createRProfile(String name) async {
    final profile = await _rProfileService.createProfile(name);
    _profileRevision++;
    AppLogger().info('新增r协议配置：${profile.name}', category: 'PLOT');
    _notifyLater();
    return profile;
  }

  Future<void> updateRProfile(ZobowConfigProfile profile) async {
    await _rProfileService.updateProfile(profile);
    _profileRevision++;
    AppLogger().info('更新r协议配置：${profile.name}', category: 'PLOT');
    _notifyLater();
  }

  Future<void> deleteRProfile(String id) async {
    String? name;
    for (final profile in _rProfileService.profiles) {
      if (profile.id == id) {
        name = profile.name;
        break;
      }
    }
    await _rProfileService.deleteProfile(id);
    _profileRevision++;
    _saveSettings();
    AppLogger().info('删除r协议配置：${name ?? id}', category: 'PLOT');
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
