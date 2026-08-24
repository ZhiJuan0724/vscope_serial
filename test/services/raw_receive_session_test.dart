import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/retention_usage.dart';
import 'package:vscope_serial/services/raw_receive_session.dart';

void main() {
  RawReceiveSession createSession({
    void Function()? onChanged,
    void Function()? onRetentionLimitReached,
  }) {
    return RawReceiveSession(
      onChanged: onChanged ?? () {},
      onRetentionLimitReached: onRetentionLimitReached ?? () {},
    );
  }

  test('容量上限时截断接收并触发停止回调', () {
    var reached = 0;
    final session = createSession(onRetentionLimitReached: () => reached++);
    session.debugRetentionLimitBytes = 8;
    final accepted = session.appendRawBytes(
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      stopAtLimit: true,
    );
    expect(accepted, hasLength(8));
    expect(session.retentionUsage.state, RetentionState.limitReached);
    expect(reached, 1);
  });

  test('显示行数上限按 FIFO 清理', () {
    final session = createSession();
    session.debugRetentionLimitBytes = 1024 * 1024;
    session.setAutoLineBreak(false);
    session.setDisplayLineLimit(100);
    for (var i = 0; i < 150; i++) {
      session.addReceivedData(ascii.encode('line$i\n'), DateTime(2026, 1, 1));
    }
    expect(session.receivedLines.length, lessThanOrEqualTo(100));
  });

  test('HEX 模式显示十六进制文本', () {
    final session = createSession();
    session.debugRetentionLimitBytes = 1024 * 1024;
    session.setAutoLineBreak(false);
    session.setReceiveHex(true);
    session.addReceivedData(
      Uint8List.fromList([0x12, 0xAB]),
      DateTime(2026, 1, 1),
    );
    expect(session.receivedLines.single, contains('12 AB'));
  });

  test('clear 清空字节、显示与容量状态', () {
    var reached = 0;
    final session = createSession(onRetentionLimitReached: () => reached++);
    session.debugRetentionLimitBytes = 8;
    session.appendRawBytes(Uint8List.fromList([1, 2, 3]), stopAtLimit: true);
    session.setAutoLineBreak(false);
    session.addReceivedData(ascii.encode('hello\n'), DateTime(2026, 1, 1));
    expect(session.hasRawData, isTrue);
    expect(session.receivedLines, isNotEmpty);

    session.clear();
    expect(session.hasRawData, isFalse);
    expect(session.receivedLines, isEmpty);
    expect(session.retentionUsage.state, RetentionState.normal);
  });
}
