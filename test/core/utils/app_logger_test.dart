import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/app_logger.dart';

void main() {
  test('FileLogOutput creates per-process log files instead of latest.log', () async {
    final first = FileLogOutput();
    final second = FileLogOutput();
    await first.init();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await second.init();
    addTearDown(first.close);
    addTearDown(second.close);

    final firstPath = first.filePathForTest!;
    final secondPath = second.filePathForTest!;
    expect(firstPath, isNot(secondPath));
    final firstName = firstPath.replaceAll(r'\', '/').split('/').last;
    expect(firstName, isNot('latest.log'));
    expect(
      firstName,
      matches(RegExp(r'^vscope_log_\d{8}_\d{6}_\d{3}_\d+\.log$')),
    );
    expect(File(firstPath).existsSync(), isTrue);
    expect(File(secondPath).existsSync(), isTrue);
  });
}
