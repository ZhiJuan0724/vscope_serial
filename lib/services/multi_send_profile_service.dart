import 'dart:convert';
import 'dart:io';

import '../core/utils/app_logger.dart';
import '../data/models/multi_send_profile.dart';

/// 多条发送配置的磁盘存储。与绘图地址配置分目录保存，避免混读。
class MultiSendProfileService {
  static const _directoryName = 'multi_send';
  final Directory? directoryOverride;
  final List<MultiSendProfile> _profiles = [];
  Directory? _directory;

  MultiSendProfileService({this.directoryOverride});

  List<MultiSendProfile> get profiles => List.unmodifiable(_profiles);

  Future<void> init() async {
    _directory ??=
        directoryOverride ??
        Directory(
          '${File(Platform.resolvedExecutable).parent.path}/config/$_directoryName',
        );
    if (!_directory!.existsSync()) _directory!.createSync(recursive: true);
    await reload();
  }

  Future<void> reload() async {
    _profiles.clear();
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return;
    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.toLowerCase().endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map) continue;
        final profile = MultiSendProfile.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (profile.id.isNotEmpty) _profiles.add(profile);
      } catch (error) {
        AppLogger().warning('跳过损坏的多条发送配置: ${file.path}', category: 'DATA');
      }
    }
    _profiles.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<MultiSendProfile> create(String name) async {
    final profile = MultiSendProfile.empty(_newId(), name: _uniqueName(name));
    await save(profile);
    return profile;
  }

  Future<void> save(MultiSendProfile profile) async {
    final directory = _directory;
    if (directory == null) throw StateError('多条发送配置服务尚未初始化');
    final index = _profiles.indexWhere((item) => item.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    _profiles.sort((a, b) => a.name.compareTo(b.name));
    final target = File('${directory.path}/${profile.id}.json');
    final temporary = File('${target.path}.tmp');
    temporary.writeAsStringSync(profile.toJsonString(), encoding: utf8);
    if (target.existsSync()) target.deleteSync();
    temporary.renameSync(target.path);
  }

  Future<void> delete(String id) async {
    _profiles.removeWhere((profile) => profile.id == id);
    final directory = _directory;
    final file = directory == null ? null : File('${directory.path}/$id.json');
    if (file?.existsSync() ?? false) file!.deleteSync();
  }

  Future<MultiSendProfile> importJson(String path) async {
    final decoded = jsonDecode(File(path).readAsStringSync());
    if (decoded is! Map) throw const FormatException('配置文件格式不正确');
    final imported = MultiSendProfile.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    final profile = imported.copyWith(
      id: _newId(),
      name: _uniqueName(imported.name),
    );
    await save(profile);
    return profile;
  }

  Future<void> exportJson(MultiSendProfile profile, String path) async {
    await File(path).writeAsString(profile.toJsonString(), encoding: utf8);
  }

  String _newId() => 'multi_send_${DateTime.now().microsecondsSinceEpoch}';

  String _uniqueName(String name) {
    final base = name.trim().isEmpty ? '新发送配置' : name.trim();
    var candidate = base;
    var suffix = 2;
    while (_profiles.any((profile) => profile.name == candidate)) {
      candidate = '$base (${suffix++})';
    }
    return candidate;
  }
}
