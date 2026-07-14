import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/multi_send_profile.dart';
import 'package:vscope_serial/services/multi_send_profile_service.dart';

void main() {
  test('多条发送配置可完整 JSON 往返并限制间隔', () {
    final profile = MultiSendProfile(
      id: 'profile',
      name: '启动命令',
      entries: const [
        MultiSendEntry(
          id: 'entry',
          name: '初始化',
          content: '01 02',
          isHex: true,
          textLineEnding: '\r\n',
          intervalMs: 0,
        ),
      ],
    );

    final restored = MultiSendProfile.fromJson(profile.toJson());
    expect(restored.name, '启动命令');
    expect(restored.entries.single.isHex, isTrue);
    expect(restored.entries.single.textLineEnding, '\r\n');
    expect(restored.entries.single.intervalMs, MultiSendEntry.minIntervalMs);
  });

  test('旧配置缺少文本行尾时保持不追加', () {
    final entry = MultiSendEntry.fromJson({
      'id': 'entry',
      'name': '文本',
      'content': 'AT',
    });
    expect(entry.textLineEnding, isEmpty);
  });

  test('导入配置创建新 ID 并处理同名', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vscope_multi_send_test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = MultiSendProfileService(directoryOverride: directory);
    await service.init();
    final existing = await service.create('测试配置');
    final source = File('${directory.path}/import.json');
    await source.writeAsString(
      MultiSendProfile(
        id: existing.id,
        name: existing.name,
        entries: const [MultiSendEntry(id: 'entry', name: '条目', content: 'AT')],
      ).toJsonString(),
    );

    final imported = await service.importJson(source.path);
    expect(imported.id, isNot(existing.id));
    expect(imported.name, '测试配置 (2)');
    expect(service.profiles, hasLength(2));
  });
}
