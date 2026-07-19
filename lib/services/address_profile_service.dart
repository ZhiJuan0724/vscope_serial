import 'dart:convert';
import 'dart:io';

import '../core/utils/app_logger.dart';
import '../core/utils/atomic_file.dart';
import '../data/models/address_config_profile.dart';
import 'app_notifications.dart';

/// Zobow/r 协议共用的地址配置文件服务。
///
/// 配置文件存储在软件目录下的 `config/` 文件夹中，
/// 每个配置文件为一个独立的 JSON 文件。
class AddressProfileService {
  final AddressProfileProtocolType protocolType;
  final Directory? directoryOverride;
  final AtomicFileCommitter fileCommitter;

  AddressProfileService({
    this.protocolType = AddressProfileProtocolType.zobow,
    this.directoryOverride,
    this.fileCommitter = const AtomicFileCommitter(),
  });

  /// 配置文件目录名称
  static const String _configDirName = 'config';

  /// 配置文件扩展名
  static const String _fileExtension = '.json';

  /// 配置文件目录路径
  Directory? _configDir;

  /// 内存缓存的配置文件列表
  final List<AddressConfigProfile> _profiles = [];

  /// 当前选中的配置文件ID（空字符串表示"不使用"）
  String _selectedProfileId = '';

  /// 是否已初始化
  bool _initialized = false;

  /// 配置文件列表（只读）
  List<AddressConfigProfile> get profiles => List.unmodifiable(_profiles);

  /// 当前选中的配置文件
  AddressConfigProfile? get selectedProfile {
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
    _configDir =
        directoryOverride ?? Directory('${exeDir.path}/$_configDirName');

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

    final targetPaths = <String>{};
    for (final file in _configDir!.listSync().whereType<File>()) {
      final lowerPath = file.path.toLowerCase();
      if (lowerPath.endsWith(_fileExtension)) {
        targetPaths.add(file.path);
      } else if (lowerPath.endsWith('$_fileExtension.bak')) {
        targetPaths.add(file.path.substring(0, file.path.length - 4));
      }
    }

    for (final path in targetPaths) {
      try {
        await fileCommitter.recoverMissingTarget(path);
        final profile = await _readProfile(path);
        if (profile.protocolType == protocolType) {
          _profiles.add(profile);
        }
      } catch (primaryError) {
        try {
          final profile = await _readProfile(fileCommitter.backupPath(path));
          await fileCommitter.restoreBackup(path);
          if (profile.protocolType == protocolType) _profiles.add(profile);
          AppLogger().warning('地址配置损坏，已从备份恢复: $path', category: 'SETTINGS');
          AppNotifications.show('一个地址配置文件损坏，已自动恢复上一份有效配置。');
        } catch (backupError) {
          AppLogger().warning(
            '跳过损坏的地址配置: $path ($primaryError; $backupError)',
            category: 'SETTINGS',
          );
        }
      }
    }

    // 按名称排序
    _profiles.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<AddressConfigProfile> _readProfile(String path) async {
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map) throw const FormatException('地址配置根节点必须为对象');
    final json = Map<String, dynamic>.from(decoded);
    if (json['id'] is! String || (json['id'] as String).isEmpty) {
      throw const FormatException('地址配置 ID 无效');
    }
    if (json['name'] is! String || json['presets'] is! List) {
      throw const FormatException('地址配置字段类型错误');
    }
    for (final item in json['presets'] as List) {
      if (item is! Map || item['name'] is! String || item['address'] is! num) {
        throw const FormatException('地址条目字段类型错误');
      }
      final address = (item['address'] as num).toInt();
      if (address < 0 || address > 0xFFFFFFFF) {
        throw const FormatException('地址条目超出32位无符号范围');
      }
    }
    return AddressConfigProfile.fromJson(json);
  }

  /// 创建新配置文件
  Future<AddressConfigProfile> createProfile(String name) async {
    final id = '${protocolType.id}_${DateTime.now().millisecondsSinceEpoch}';
    final profile = AddressConfigProfile.empty(
      id,
      name: name,
      protocolType: protocolType,
    );

    await _saveProfile(profile);
    _profiles.add(profile);
    _profiles.sort((a, b) => a.name.compareTo(b.name));

    return profile;
  }

  /// 保存配置文件到磁盘
  Future<void> _saveProfile(AddressConfigProfile profile) async {
    if (_configDir == null) return;

    final path = '${_configDir!.path}/${profile.id}$_fileExtension';
    await fileCommitter.writeString(
      path,
      profile.toJsonString(),
      keepBackup: true,
    );
  }

  /// 更新并保存配置文件
  Future<void> updateProfile(AddressConfigProfile profile) async {
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
