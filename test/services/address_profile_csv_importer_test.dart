import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/zobow_config_profile.dart';
import 'package:vscope_serial/services/address_profile_csv_importer.dart';

void main() {
  group('AddressProfileCsvImporter', () {
    test('识别表头并导入 Zobow 十六进制地址', () {
      final presets = AddressProfileCsvImporter.parse(
        '通道名称,通道地址\n母线电压,0x00000040\n速度给定,3\n',
        protocolType: AddressProfileProtocolType.zobow,
      );

      expect(presets, hasLength(2));
      expect(presets[0].name, '母线电压');
      expect(presets[0].address, 0x40);
      expect(presets[1].name, '速度给定');
      expect(presets[1].address, 0x3);
    });

    test('首行地址有效时按数据行导入', () {
      final presets = AddressProfileCsvImporter.parse(
        '母线电压,0x40\n速度给定,0x03\n',
        protocolType: AddressProfileProtocolType.zobow,
      );

      expect(presets.map((preset) => preset.name), ['母线电压', '速度给定']);
      expect(presets.map((preset) => preset.address), [0x40, 0x03]);
    });

    test('r 协议无前缀地址按十进制解析', () {
      final presets = AddressProfileCsvImporter.parse(
        'name,address\n通道1,16\n通道2,0x10\n',
        protocolType: AddressProfileProtocolType.rProtocol,
      );

      expect(presets.map((preset) => preset.address), [16, 16]);
    });

    test('支持带逗号的引号通道名', () {
      final presets = AddressProfileCsvImporter.parse(
        'name,address\n"速度,给定",0x03\n',
        protocolType: AddressProfileProtocolType.zobow,
      );

      expect(presets.single.name, '速度,给定');
      expect(presets.single.address, 0x03);
    });

    test('非首行地址格式错误时报错', () {
      expect(
        () => AddressProfileCsvImporter.parse(
          'name,address\n通道1,not-address\n',
          protocolType: AddressProfileProtocolType.zobow,
        ),
        throwsFormatException,
      );
    });
  });
}
