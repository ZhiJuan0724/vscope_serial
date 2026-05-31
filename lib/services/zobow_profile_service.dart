import 'dart:convert';
import 'dart:io';

import '../data/models/zobow_config_profile.dart';

/// 众邦电控配置文件服务
///
/// 配置文件存储在软件目录下的 `config/` 文件夹中，
/// 每个配置文件为一个独立的 JSON 文件。
class ZobowProfileService {
  static final ZobowProfileService _instance = ZobowProfileService._internal();
  factory ZobowProfileService() => _instance;
  ZobowProfileService._internal();

  /// 配置文件目录名称
  static const String _configDirName = 'config';

  /// 配置文件扩展名
  static const String _fileExtension = '.json';

  /// 配置文件目录路径
  Directory? _configDir;

  /// 内存缓存的配置文件列表
  final List<ZobowConfigProfile> _profiles = [];

  /// 当前选中的配置文件ID（空字符串表示"不使用"）
  String _selectedProfileId = '';

  /// 是否已初始化
  bool _initialized = false;

  /// 配置文件列表（只读）
  List<ZobowConfigProfile> get profiles => List.unmodifiable(_profiles);

  /// 当前选中的配置文件
  ZobowConfigProfile? get selectedProfile {
    if (_selectedProfileId.isEmpty) return null;
    try {
      return _profiles.firstWhere((p) => p.id == _selectedProfileId);
    } catch (_) {
      return null;
    }
  }

  /// 当前选中的配置文件ID
  String get selectedProfileId => _selectedProfileId;

  /// 初始化：创建配置目录并加载所有配置文件
  Future<void> init() async {
    if (_initialized) return;

    final exeDir = File(Platform.resolvedExecutable).parent;
    _configDir = Directory('${exeDir.path}/$_configDirName');

    if (!_configDir!.existsSync()) {
      _configDir!.createSync(recursive: true);
    }

    await _loadAllProfiles();
    _initialized = true;
  }

  /// 加载目录下所有配置文件
  Future<void> _loadAllProfiles() async {
    _profiles.clear();

    if (_configDir == null || !_configDir!.existsSync()) return;

    final files = _configDir!.listSync().whereType<File>().where(
      (f) => f.path.endsWith(_fileExtension),
    );

    for (final file in files) {
      try {
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final profile = ZobowConfigProfile.fromJson(json);
        _profiles.add(profile);
      } catch (e) {
        // 跳过损坏的配置文件
      }
    }

    // 按名称排序
    _profiles.sort((a, b) => a.name.compareTo(b.name));
  }

  /// 创建新配置文件
  Future<ZobowConfigProfile> createProfile(String name) async {
    final id = 'profile_${DateTime.now().millisecondsSinceEpoch}';
    final profile = ZobowConfigProfile.empty(id, name: name);

    await _saveProfile(profile);
    _profiles.add(profile);
    _profiles.sort((a, b) => a.name.compareTo(b.name));

    return profile;
  }

  /// 保存配置文件到磁盘
  Future<void> _saveProfile(ZobowConfigProfile profile) async {
    if (_configDir == null) return;

    final file = File('${_configDir!.path}/${profile.id}$_fileExtension');
    file.writeAsStringSync(profile.toJsonString());
  }

  /// 更新并保存配置文件
  Future<void> updateProfile(ZobowConfigProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
      await _saveProfile(profile);
    }
  }

  /// 删除配置文件
  Future<void> deleteProfile(String id) async {
    if (_configDir == null) return;

    final file = File('${_configDir!.path}/$id$_fileExtension');
    if (file.existsSync()) {
      file.deleteSync();
    }

    _profiles.removeWhere((p) => p.id == id);

    // 如果删除的是当前选中的，清空选择
    if (_selectedProfileId == id) {
      _selectedProfileId = '';
    }
  }

  /// 设置当前选中的配置文件
  void selectProfile(String? id) {
    _selectedProfileId = id ?? '';
  }

  /// 重新加载所有配置文件
  Future<void> reload() async {
    await _loadAllProfiles();
  }
}
