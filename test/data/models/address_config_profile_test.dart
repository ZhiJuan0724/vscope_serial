import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';

void main() {
  group('AddressConfigProfile', () {
    test('Zobow固定按十六进制而r协议严格区分地址进制', () {
      final zobow = AddressChannelPreset.tryParseAddress(
        name: 'Zobow',
        text: '16',
        protocolType: AddressProfileProtocolType.zobow,
      );
      final rDecimal = AddressChannelPreset.tryParseAddress(
        name: 'R十进制',
        text: '16',
        protocolType: AddressProfileProtocolType.rProtocol,
      );
      final rHex = AddressChannelPreset.tryParseAddress(
        name: 'R十六进制',
        text: '0x10',
        protocolType: AddressProfileProtocolType.rProtocol,
      );

      expect(zobow!.address, 0x16);
      expect(zobow.addressFormat, AddressValueFormat.hexadecimal);
      expect(rDecimal!.address, 16);
      expect(rDecimal.addressFormat, AddressValueFormat.decimal);
      expect(rHex!.address, 16);
      expect(rHex.addressFormat, AddressValueFormat.hexadecimal);
      expect(
        AddressChannelPreset.tryParseAddress(
          name: '非法R地址',
          text: 'FF',
          protocolType: AddressProfileProtocolType.rProtocol,
        ),
        isNull,
      );
    });

    test('旧JSON缺少protocolType时按Zobow加载', () {
      final profile = AddressConfigProfile.fromJson({
        'id': 'legacy',
        'name': '旧配置',
        'presets': [
          {'name': '通道1', 'address': 16},
        ],
      });

      expect(profile.protocolType, AddressProfileProtocolType.zobow);
      expect(profile.presets.single.address, 16);
      expect(
        profile.presets.single.addressFormat,
        AddressValueFormat.hexadecimal,
      );
    });

    test('新JSON保存并恢复r协议类型', () {
      final profile = AddressConfigProfile(
        id: 'r_profile',
        name: 'r配置',
        protocolType: AddressProfileProtocolType.rProtocol,
        presets: [AddressChannelPreset(name: '通道1', address: 32)],
      );

      final json = profile.toJson();
      final restored = AddressConfigProfile.fromJson(json);

      expect(json['protocolType'], 'rProtocol');
      expect(restored.protocolType, AddressProfileProtocolType.rProtocol);
      expect(restored.presets.single.address, 32);
    });

    test('r协议配置保存并恢复地址进制', () {
      final profile = AddressConfigProfile(
        id: 'r_profile',
        name: 'r配置',
        protocolType: AddressProfileProtocolType.rProtocol,
        presets: [
          AddressChannelPreset(
            name: '十进制',
            address: 16,
            addressFormat: AddressValueFormat.decimal,
          ),
          AddressChannelPreset(
            name: '十六进制',
            address: 16,
            addressFormat: AddressValueFormat.hexadecimal,
          ),
        ],
      );

      final restored = AddressConfigProfile.fromJson(profile.toJson());

      expect(restored.presets[0].formatAddress(), '16');
      expect(restored.presets[1].formatAddress(compactHex: true), '0x10');
    });
  });
}
