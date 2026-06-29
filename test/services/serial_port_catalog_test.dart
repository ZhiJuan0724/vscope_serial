import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/serial_port_catalog.dart';

void main() {
  group('SerialPortCatalog', () {
    test('并发刷新只调用一次底层枚举', () async {
      final result = Completer<List<String>>();
      var calls = 0;
      final catalog = SerialPortCatalog(
        enumerator: () {
          calls++;
          return result.future;
        },
        onChanged: () {},
      );

      final first = catalog.refresh(reason: 'first');
      final second = catalog.refresh(reason: 'second');
      expect(calls, 1);
      expect(catalog.isRefreshing, isTrue);

      result.complete(['COM2', 'COM10']);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(catalog.ports, ['COM2', 'COM10']);
      expect(catalog.isRefreshing, isFalse);
    });

    test('枚举失败保留最后一次成功列表', () async {
      var shouldFail = false;
      final catalog = SerialPortCatalog(
        enumerator: () async {
          if (shouldFail) throw StateError('driver error');
          return ['COM7'];
        },
        onChanged: () {},
      );

      expect(await catalog.refresh(reason: 'initial'), isTrue);
      shouldFail = true;
      expect(await catalog.refresh(reason: 'failure'), isFalse);

      expect(catalog.ports, ['COM7']);
      expect(catalog.lastError, contains('driver error'));
    });

    test('等待枚举超时不会阻塞事件循环且后台结果仍会更新缓存', () async {
      final result = Completer<List<String>>();
      var eventLoopAdvanced = false;
      final catalog = SerialPortCatalog(
        enumerator: () => result.future,
        onChanged: () {},
      );

      Timer.run(() => eventLoopAdvanced = true);
      final refreshed = await catalog.refresh(
        reason: 'slow driver',
        waitTimeout: const Duration(milliseconds: 20),
      );

      expect(refreshed, isFalse);
      expect(eventLoopAdvanced, isTrue);
      expect(catalog.isRefreshing, isTrue);

      result.complete(['COM12']);
      await Future<void>.delayed(Duration.zero);
      expect(catalog.ports, ['COM12']);
      expect(catalog.isRefreshing, isFalse);
    });
  });
}
