import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/zobow_config_profile.dart';

void main() {
  group('ZobowConfigProfile', () {
    test('旧JSON缺少protocolType时按Zobow加载', () {
      final profile = ZobowConfigProfile.fromJson({
        'id': 'legacy',
        'name': '旧配置',
        'presets': [
          {'name': '通道1', 'address': 16},
        ],
      });

      expect(profile.protocolType, AddressProfileProtocolType.zobow);
      expect(profile.presets.single.address, 16);
    });

    test('新JSON保存并恢复r协议类型', () {
      final profile = ZobowConfigProfile(
        id: 'r_profile',
        name: 'r配置',
        protocolType: AddressProfileProtocolType.rProtocol,
        presets: [ZobowChannelPreset(name: '通道1', address: 32)],
      );

      final json = profile.toJson();
      final restored = ZobowConfigProfile.fromJson(json);

      expect(json['protocolType'], 'rProtocol');
      expect(restored.protocolType, AddressProfileProtocolType.rProtocol);
      expect(restored.presets.single.address, 32);
    });
  });
}
