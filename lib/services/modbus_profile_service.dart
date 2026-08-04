import 'dart:convert';
import 'dart:io';

import '../core/utils/app_logger.dart';
import '../core/utils/atomic_file.dart';

class ModbusProfile {
  const ModbusProfile({
    required this.id,
    required this.name,
    required this.source,
  });

  final String id;
  final String name;
  final String source;

  ModbusProfile copyWith({String? name, String? source}) => ModbusProfile(
    id: id,
    name: name ?? this.name,
    source: source ?? this.source,
  );
}

/// Modbus配置库存储。每个配置独立保存在 `config/modbus/*.json`。
class ModbusProfileService {
  ModbusProfileService({
    this.directoryOverride,
    this.fileCommitter = const AtomicFileCommitter(),
  });

  static const String defaultProfileName = '默认配置';
  static const String _directoryName = 'modbus';
  static const String _extension = '.json';

  final Directory? directoryOverride;
  final AtomicFileCommitter fileCommitter;
  final List<ModbusProfile> _profiles = [];
  Directory? _directory;

  List<ModbusProfile> get profiles => List.unmodifiable(_profiles);
  String? get directoryPath => _directory?.path;

  Future<void> init() async {
    _directory ??=
        directoryOverride ??
        Directory(
          '${File(Platform.resolvedExecutable).parent.path}/config/$_directoryName',
        );
    await _directory!.create(recursive: true);
    await reload();
    await ensureDefaultProfile();
  }

  Future<void> reload() async {
    _profiles.clear();
    final directory = _directory;
    if (directory == null || !await directory.exists()) return;
    final targetPaths = <String>{};
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (lower.endsWith(_extension)) {
        targetPaths.add(entity.path);
      } else if (lower.endsWith('$_extension.bak')) {
        targetPaths.add(entity.path.substring(0, entity.path.length - 4));
      }
    }
    for (final path in targetPaths) {
      try {
        await fileCommitter.recoverMissingTarget(path);
        _profiles.add(await _read(path));
      } catch (primaryError) {
        try {
          final backup = fileCommitter.backupPath(path);
          final recovered = await _read(backup);
          await fileCommitter.restoreBackup(path);
          _profiles.add(recovered);
          AppLogger().warning('Modbus配置损坏，已从备份恢复: $path', category: 'MODBUS');
        } catch (backupError) {
          AppLogger().warning(
            '跳过损坏的Modbus配置: $path ($primaryError; $backupError)',
            category: 'MODBUS',
          );
        }
      }
    }
    _sort();
  }

  Future<ModbusProfile> ensureDefaultProfile() async {
    for (final profile in _profiles) {
      if (profile.name == defaultProfileName) return profile;
    }
    return create(defaultProfileName, source: _emptySource());
  }

  Future<ModbusProfile> create(String name, {String? source}) async {
    final profile = ModbusProfile(
      id: _newId(),
      name: _uniqueName(name),
      source: source ?? _emptySource(),
    );
    await save(profile);
    return profile;
  }

  Future<void> save(ModbusProfile profile) async {
    final directory = _directory;
    if (directory == null) throw StateError('Modbus配置服务尚未初始化');
    final normalized = profile.copyWith(
      source: _withMetadata(profile.source, profile.id, profile.name),
    );
    final index = _profiles.indexWhere((item) => item.id == profile.id);
    if (index >= 0) {
      _profiles[index] = normalized;
    } else {
      _profiles.add(normalized);
    }
    _sort();
    await fileCommitter.writeString(
      '${directory.path}/${profile.id}$_extension',
      normalized.source,
      keepBackup: true,
    );
  }

  Future<ModbusProfile> rename(ModbusProfile profile, String name) async {
    final renamed = profile.copyWith(
      name: _uniqueName(name, exceptId: profile.id),
    );
    await save(renamed);
    await ensureDefaultProfile();
    return _profiles.firstWhere((item) => item.id == renamed.id);
  }

  Future<void> delete(String id) async {
    final directory = _directory;
    _profiles.removeWhere((profile) => profile.id == id);
    if (directory != null) {
      final path = '${directory.path}/$id$_extension';
      for (final candidate in [
        path,
        fileCommitter.backupPath(path),
        fileCommitter.partPath(path),
      ]) {
        final file = File(candidate);
        if (await file.exists()) await file.delete();
      }
    }
    await ensureDefaultProfile();
  }

  Future<ModbusProfile> importJson(String path) async {
    final source = await File(path).readAsString();
    final decoded = _decodeConfiguration(source);
    final metadata = decoded['profile'];
    final importedName =
        metadata is Map && metadata['name'] is String
            ? '${metadata['name']}'
            : _fileStem(path);
    return create(importedName, source: source);
  }

  Future<void> exportJson(ModbusProfile profile, String path) async {
    await File(path).writeAsString(profile.source, encoding: utf8);
  }

  ModbusProfile? findById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<ModbusProfile> _read(String path) async {
    final source = await File(path).readAsString();
    final root = _decodeConfiguration(source);
    final metadata = root['profile'];
    final fallbackId = _fileStem(path.replaceFirst(RegExp(r'\.bak$'), ''));
    final id =
        metadata is Map && metadata['id'] is String
            ? '${metadata['id']}'
            : fallbackId;
    final name =
        metadata is Map && metadata['name'] is String
            ? '${metadata['name']}'
            : fallbackId;
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw const FormatException('Modbus配置名称或ID无效');
    }
    return ModbusProfile(
      id: id,
      name: name,
      source: _withMetadata(source, id, name),
    );
  }

  Map<String, dynamic> _decodeConfiguration(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('不是受支持的Modbus配置文件');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root['modbus'] is! Map) {
      throw const FormatException('Modbus配置节点无效');
    }
    return root;
  }

  String _withMetadata(String source, String id, String name) {
    final root = _decodeConfiguration(source);
    root['profile'] = {'id': id, 'name': name};
    return const JsonEncoder.withIndent('  ').convert(root);
  }

  String _emptySource() => const JsonEncoder.withIndent(
    '  ',
  ).convert({'schemaVersion': 1, 'modbus': <String, Object?>{}});

  String _newId() => 'modbus_${DateTime.now().microsecondsSinceEpoch}';

  String _uniqueName(String value, {String? exceptId}) {
    final base = value.trim().isEmpty ? '新建配置' : value.trim();
    var candidate = base;
    var suffix = 2;
    while (_profiles.any(
      (profile) => profile.id != exceptId && profile.name == candidate,
    )) {
      candidate = '$base (${suffix++})';
    }
    return candidate;
  }

  String _fileStem(String path) {
    final name = File(path).uri.pathSegments.last;
    return name.toLowerCase().endsWith(_extension)
        ? name.substring(0, name.length - _extension.length)
        : name;
  }

  void _sort() {
    _profiles.sort((a, b) {
      if (a.name == defaultProfileName) return -1;
      if (b.name == defaultProfileName) return 1;
      return a.name.compareTo(b.name);
    });
  }
}
