import 'dart:async';
import 'package:flutter/foundation.dart';

import '../core/utils/app_logger.dart';
import '../data/models/multi_send_profile.dart';
import '../services/app_settings.dart';
import '../services/multi_send_profile_service.dart';
import '../services/serial_service.dart';

/// 多条发送调度模式：仅执行一轮或在末条间隔后继续循环。
enum MultiSendRunMode { once, loop }

/// 管理配置及串行发送调度；接收数据更新不会驱动本 ViewModel 重建。
/// 多条发送配置和串行调度器的状态门面。
///
/// 循环发送不使用重叠周期定时器：每次串口写完成后才等待下一条间隔，停止、断线
/// 或页面离开会使取消 token 失效并阻止继续调度。
class MultiSendViewModel extends ChangeNotifier {
  final SerialService _serialService;
  final MultiSendProfileService _profileService;
  MultiSendProfile? _selectedProfile;
  bool _loading = false;
  bool _initialized = false;
  bool _running = false;
  int _runToken = 0;
  String? _currentEntryId;
  int _completedRounds = 0;
  late bool _lastConnected;
  late bool _lastRawReceiving;

  MultiSendViewModel(
    this._serialService, {
    MultiSendProfileService? profileService,
  }) : _profileService = profileService ?? MultiSendProfileService() {
    _lastConnected = _serialService.isConnected;
    _lastRawReceiving = _serialService.isRawReceiving;
    _serialService.addListener(_handleSerialChange);
  }

  bool get loading => _loading;
  bool get isRunning => _running;
  String? get currentEntryId => _currentEntryId;
  int get completedRounds => _completedRounds;
  List<MultiSendProfile> get profiles => _profileService.profiles;
  MultiSendProfile? get selectedProfile => _selectedProfile;
  bool get canSendManually =>
      !_running && _serialService.isConnected && _serialService.isRawReceiving;
  bool get canRun => canSendManually && enabledEntries.isNotEmpty;
  List<MultiSendEntry> get enabledEntries =>
      _selectedProfile?.entries.where((entry) => entry.enabled).toList() ??
      const [];

  Future<void> initialize() async {
    if (_initialized || _loading) return;
    _loading = true;
    notifyListeners();
    try {
      await _profileService.init();
      final selectedId = AppSettings().rawMultiSendProfileId;
      _selectedProfile = _profileService.profiles
          .cast<MultiSendProfile?>()
          .firstWhere(
            (profile) => profile?.id == selectedId,
            orElse:
                () =>
                    _profileService.profiles.isEmpty
                        ? null
                        : _profileService.profiles.first,
          );
      if (_selectedProfile != null && _selectedProfile!.id != selectedId) {
        AppSettings().rawMultiSendProfileId = _selectedProfile!.id;
        unawaited(AppSettings().save());
      }
    } catch (error, stackTrace) {
      AppLogger().error(
        '加载多条发送配置失败: $error',
        category: 'DATA',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _initialized = true;
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> selectProfile(String? id) async {
    if (_running) return;
    _selectedProfile = _profileService.profiles
        .cast<MultiSendProfile?>()
        .firstWhere((profile) => profile?.id == id, orElse: () => null);
    AppSettings().rawMultiSendProfileId = _selectedProfile?.id ?? '';
    await AppSettings().save();
    notifyListeners();
  }

  Future<void> createProfile(String name) async {
    final profile = await _profileService.create(name);
    await selectProfile(profile.id);
  }

  Future<void> renameProfile(String name) async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    await _saveProfile(
      profile.copyWith(name: name.trim().isEmpty ? profile.name : name.trim()),
    );
  }

  Future<void> deleteSelectedProfile() async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    await _profileService.delete(profile.id);
    _selectedProfile =
        _profileService.profiles.isEmpty
            ? null
            : _profileService.profiles.first;
    AppSettings().rawMultiSendProfileId = _selectedProfile?.id ?? '';
    await AppSettings().save();
    notifyListeners();
  }

  Future<void> importProfile(String path) async {
    if (_running) return;
    final profile = await _profileService.importJson(path);
    await selectProfile(profile.id);
  }

  Future<void> exportSelectedProfile(String path) async {
    final profile = _selectedProfile;
    if (profile == null) return;
    await _profileService.exportJson(profile, path);
  }

  Future<void> addEntry(MultiSendEntry entry) async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    await _saveProfile(profile.copyWith(entries: [...profile.entries, entry]));
  }

  Future<void> updateEntry(MultiSendEntry entry) async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    await _saveProfile(
      profile.copyWith(
        entries: [
          for (final item in profile.entries)
            item.id == entry.id ? entry : item,
        ],
      ),
    );
  }

  Future<void> deleteEntry(String id) async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    await _saveProfile(
      profile.copyWith(
        entries: profile.entries.where((entry) => entry.id != id).toList(),
      ),
    );
  }

  Future<void> reorderEntries(int oldIndex, int newIndex) async {
    final profile = _selectedProfile;
    if (profile == null || _running) return;
    final entries = [...profile.entries];
    entries.insert(newIndex, entries.removeAt(oldIndex));
    await _saveProfile(profile.copyWith(entries: entries));
  }

  Future<void> sendEntry(MultiSendEntry entry) async {
    if (!canSendManually) return;
    await _sendEntry(entry);
  }

  void runOnce() => _run(MultiSendRunMode.once);
  void runLoop() => _run(MultiSendRunMode.loop);

  void _run(MultiSendRunMode mode) {
    if (!canRun) return;
    final entries = [...enabledEntries];
    _running = true;
    _currentEntryId = null;
    _completedRounds = 0;
    final token = ++_runToken;
    notifyListeners();
    unawaited(_runEntries(entries, mode, token));
  }

  Future<void> _runEntries(
    List<MultiSendEntry> entries,
    MultiSendRunMode mode,
    int token,
  ) async {
    try {
      do {
        for (var index = 0; index < entries.length; index++) {
          if (!_isActive(token)) return;
          final entry = entries[index];
          _currentEntryId = entry.id;
          notifyListeners();
          await _sendEntry(entry);
          if (!_isActive(token)) return;
          final isLast = index == entries.length - 1;
          if (!isLast || mode == MultiSendRunMode.loop) {
            await Future<void>.delayed(
              Duration(milliseconds: entry.intervalMs),
            );
          }
        }
        _completedRounds++;
        notifyListeners();
      } while (mode == MultiSendRunMode.loop && _isActive(token));
    } catch (error, stackTrace) {
      AppLogger().error(
        '多条发送已停止: $error',
        category: 'DATA',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (token == _runToken) {
        _running = false;
        _currentEntryId = null;
        notifyListeners();
      }
    }
  }

  bool _isActive(int token) =>
      _running &&
      token == _runToken &&
      _serialService.isConnected &&
      _serialService.isRawReceiving;

  Future<void> _sendEntry(MultiSendEntry entry) async {
    final data = _serialService.prepareMultiSendData(
      entry.isHex ? entry.content : '${entry.content}${entry.textLineEnding}',
      isHex: entry.isHex,
    );
    if (data == null || data.isEmpty) {
      throw StateError('“${entry.name}”内容无效或串口未连接');
    }
    await _serialService.send(data, displayAsHex: entry.isHex);
  }

  Future<void> _saveProfile(MultiSendProfile profile) async {
    _selectedProfile = profile;
    await _profileService.save(profile);
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _runToken++;
    _running = false;
    _currentEntryId = null;
    notifyListeners();
  }

  /// 数据收发开始或停止后立即同步发送可用性，避免等待异步服务通知。
  void refreshSendAvailability() {
    _handleSerialChange();
  }

  void _handleSerialChange() {
    final connected = _serialService.isConnected;
    final rawReceiving = _serialService.isRawReceiving;
    final availabilityChanged =
        connected != _lastConnected || rawReceiving != _lastRawReceiving;
    _lastConnected = connected;
    _lastRawReceiving = rawReceiving;

    if (_running && (!connected || !rawReceiving)) {
      stop();
      return;
    }
    // 只在发送可用性变化时刷新面板，避免接收数据通知重建条目列表。
    if (availabilityChanged) notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _serialService.removeListener(_handleSerialChange);
    super.dispose();
  }
}
