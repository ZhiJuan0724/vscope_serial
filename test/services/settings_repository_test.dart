import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/settings_repository.dart';

void main() {
  test('设置仓库合并写入并从备份恢复', () async {
    final directory = await Directory.systemTemp.createTemp('settings_repo_');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}settings.json';
    final repository = SettingsRepository(
      validator: (snapshot) {
        if (snapshot['value'] is! int) {
          throw const FormatException('value must be int');
        }
      },
      saveDebounce: Duration.zero,
    );
    await repository.setPath(path);

    await repository.save({'value': 1});
    await repository.save({'value': 2});
    await repository.flush();
    expect((await repository.load()).snapshot?['value'], 2);

    await repository.save({'value': 3});
    await repository.flush();
    await File(path).writeAsString('{');
    final recovered = await repository.load();
    expect(recovered.recoveredFromBackup, isTrue);
    expect(recovered.snapshot?['value'], 2);
  });
}
