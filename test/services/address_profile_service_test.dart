import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';
import 'package:vscope_serial/services/address_profile_service.dart';

void main() {
  group('AddressProfileService persistence', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'vscope_address_profile_test_',
      );
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('单个损坏配置不影响其他配置加载', () async {
      final valid = AddressConfigProfile(
        id: 'valid',
        name: '有效配置',
        presets: [AddressChannelPreset(name: '通道', address: 1)],
      );
      await File(
        '${directory.path}/valid.json',
      ).writeAsString(valid.toJsonString());
      await File('${directory.path}/broken.json').writeAsString('{');

      final service = AddressProfileService(directoryOverride: directory);
      await service.init();

      expect(service.profiles.map((profile) => profile.id), ['valid']);
    });

    test('主文件损坏时恢复上一代地址配置', () async {
      final service = AddressProfileService(directoryOverride: directory);
      await service.init();
      final profile = await service.createProfile('第一版');
      await service.updateProfile(profile.copyWith(name: '第二版'));
      await File('${directory.path}/${profile.id}.json').writeAsString('{');

      final reloaded = AddressProfileService(directoryOverride: directory);
      await reloaded.init();

      expect(reloaded.profiles.single.name, '第一版');
      expect(
        await File('${directory.path}/${profile.id}.json').readAsString(),
        contains('第一版'),
      );
    });
  });
}
