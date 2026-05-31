import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/zobow_c_profile_importer.dart';

String _source(String cases) {
  return '''
void Other(void)
{
  switch (VsRxVar.Addr[i])
  {
    case 0x99:// should_ignore
      VsTemp[i] = Wrong.Value;
      break;
  }
}

void ChxValueTable(void)
{
  int16_t i;
  for (i = 0; i < CycleCountNum; i++)
  {
    switch (VsRxVar.Addr[i])
    {
$cases
    }
  }
}
''';
}

void main() {
  group('ZobowCProfileImporter', () {
    test('parses UTF-8 case comment names', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x1:// 运动命令
        VsTemp[i] = ((int16_t)(RunControl.Cmd * 100));
        break;
'''),
      );

      expect(result.presets, hasLength(1));
      expect(result.presets.first.address, 0x1);
      expect(result.presets.first.name, '运动命令');
      expect(result.commentNameCount, 1);
    });

    test('falls back when comment is numeric address', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x10://0x10
        VsTemp[i] = Adc.Servo1CurA;
        break;
      case 17:// 17
        VsTemp[i] = Adc.Servo1CurB;
        break;
      case 0x18://0x40
        VsTemp[i] = Adc.Servo1CurC;
        break;
'''),
      );

      expect(result.presets, hasLength(3));
      expect(result.presets[0].name, 'Adc.Servo1CurA');
      expect(result.presets[1].name, 'Adc.Servo1CurB');
      expect(result.presets[2].name, 'Adc.Servo1CurC');
    });

    test('can ignore comments and use variable names only', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x1:// 杩愬姩鍛戒护
        VsTemp[i] = ((int16_t)(RunControl.Cmd * 100));
        break;
      case 0x2:
        VsTemp[i] = PedalMinid.Voltage;// 脚踏电压值
        break;
'''),
        useComments: false,
      );

      expect(result.presets, hasLength(2));
      expect(result.presets[0].name, '((int16_t)(RunControl.Cmd*100))');
      expect(result.presets[1].name, 'PedalMinid.Voltage');
      expect(result.commentNameCount, 0);
    });

    test('falls back for missing and garbled comments', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x20:
        VsTemp[i] = ((int16_t)(_IQtoF(ServoPidSpeed.Ref) * 6000));
        break;
      case 0x21:// 锟斤拷锟斤拷
        VsTemp[i] = PedalMinid.Voltage;// 锟借定
        break;
      case 0x22:// Uμ?á÷·′à?
        VsTemp[i] = Servo_AdcIu;
        break;
'''),
      );

      expect(result.presets, hasLength(3));
      expect(
        result.presets[0].name,
        '((int16_t)(_IQtoF(ServoPidSpeed.Ref)*6000))',
      );
      expect(result.presets[1].name, 'PedalMinid.Voltage');
      expect(result.presets[2].name, 'Servo_AdcIu');
      expect(result.commentNameCount, 0);
    });

    test('fallback keeps full rhs including arrays and negative signs', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x23:
        VsTemp[i] = -DataVelFbk[OutPutIndex] + OffsetTable[i];
        break;
'''),
      );

      expect(result.presets, hasLength(1));
      expect(
        result.presets.first.name,
        '-DataVelFbk[OutPutIndex]+OffsetTable[i]',
      );
    });

    test('requires break and keeps first duplicate address', () {
      final result = ZobowCProfileImporter.parseSource(
        _source('''
      case 0x30:// skipped
        VsTemp[i] = Skipped.Value;
      case 0x31:// first
        VsTemp[i] = First.Value;
        break;
      case 0x31:// duplicate
        VsTemp[i] = Duplicate.Value;
        break;
'''),
      );

      expect(result.presets, hasLength(1));
      expect(result.presets.first.address, 0x31);
      expect(result.presets.first.name, 'first');
    });

    test('parses the longest switch inside ChxValueTable', () {
      final result = ZobowCProfileImporter.parseSource('''
void Other(void)
{
  switch (VsRxVar.Addr[i])
  {
    case 0x99:// outside
      VsTemp[i] = Outside.Value;
      break;
  }
}

void ChxValueTable(INT16U Addr)
{
  switch (ShortSwitch)
  {
    case 0x1:// short
      VsTemp = Short.Value;
      break;
  }

  switch (Addr)
  {
    case 1:// longest one
      VsTemp = Old.Value;
      break;
    case 2:
      VsTemp = Other.Value;
      break;
  }
}
''');

      expect(result.presets, hasLength(2));
      expect(result.presets[0].address, 1);
      expect(result.presets[0].name, 'longest one');
      expect(result.presets[1].address, 2);
      expect(result.presets[1].name, 'Other.Value');
    });

    test('uses GBK candidate when UTF-8 is malformed', () {
      final source = _source('''
      case 0x40:// 母线电压
        VsTemp[i] = Adc.VoltBus;
        break;
''');
      final bytes = Uint8List.fromList(gbk.encode(source));

      final result = ZobowCProfileImporter.parseBytes(bytes);

      expect(result.presets, hasLength(1));
      expect(result.presets.first.address, 0x40);
      expect(result.presets.first.name, '母线电压');
    });

    test('parses repository VisualScope_2 sample', () async {
      final file = File('test_tools/test_data/VisualScope_2.c');
      final result = await ZobowCProfileImporter.parseFile(file.path);

      expect(result.presets.length, greaterThan(100));
      expect(
        result.presets.any(
          (preset) => preset.address == 0x1 && preset.name == '运动命令',
        ),
        isTrue,
      );
      expect(
        result.presets.any(
          (preset) => preset.address == 0x3 && preset.name == '速度给定',
        ),
        isTrue,
      );
    });
  });
}
