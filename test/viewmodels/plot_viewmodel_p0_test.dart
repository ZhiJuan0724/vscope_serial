import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/math_channel_config.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/models/retention_usage.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

void main() {
  group('PlotViewModel P0 invariants', () {
    late PlotViewModel vm;

    setUp(() {
      AppSettings()
        ..parserType = 'fireWater'
        ..sendProtocolType = 'none'
        ..useRandomSource = false
        ..keepPlotOnRestart = false
        ..plotHistoryMemoryLimitGiB = 2
        ..mathChannels = MathChannelConfig.createDefaults();
      vm = PlotViewModel(SerialService());
      vm.setParserType(ParserType.fireWater);
    });

    tearDown(() {
      vm.dispose();
    });

    test(
      'concurrent starts share one Future and initialize one session',
      () async {
        vm.setUseRandomSource(true);
        final first = vm.startPlotting();
        final second = vm.startPlotting();

        expect(identical(first, second), isTrue);
        expect(vm.isStarting, isTrue);
        await first;
        expect(vm.isStarting, isFalse);
        expect(vm.isPlotting, isTrue);
        expect(vm.serialService.activityOwner, SerialActivityOwner.plot);

        await vm.stopPlotting();
        expect(vm.serialService.activityOwner, SerialActivityOwner.none);
      },
    );

    test('stop during start cancels intent and leaves no ownership', () async {
      vm.setUseRandomSource(true);
      final starting = vm.startPlotting();
      final stopping = vm.stopPlotting();
      await Future.wait([starting, stopping]);

      expect(vm.isStarting, isFalse);
      expect(vm.isStopping, isFalse);
      expect(vm.isPlotting, isFalse);
      expect(vm.serialService.activityOwner, SerialActivityOwner.none);
    });

    test('plot budget warns, stops before overflow, and clear rearms it', () {
      vm.dispose();
      vm = PlotViewModel(SerialService(), retentionLimitBytes: 48 * 1024);
      vm.setParserType(ParserType.fireWater);

      for (var i = 0; i < 5000; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 4),
        );
      }

      expect(vm.plotRetentionUsage.state, RetentionState.limitReached);
      expect(vm.plotRetentionUsage.usedBytes, lessThanOrEqualTo(48 * 1024));
      expect(vm.pointCount, lessThan(5000));
      final retainedCount = vm.pointCount;
      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 4));
      expect(vm.pointCount, retainedCount);

      vm.clearData();
      expect(vm.plotRetentionUsage.state, RetentionState.normal);
      vm.ingestParsedResultForTest(ParseResult.ok([1], bytesConsumed: 4));
      expect(vm.pointCount, 1);
    });

    test('CSV import cannot bypass the plot retention budget', () async {
      vm.dispose();
      vm = PlotViewModel(SerialService(), retentionLimitBytes: 512);
      final directory = await Directory.systemTemp.createTemp(
        'vscope_p0_import_budget_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final csv = File('${directory.path}/over-budget.csv');
      await csv.writeAsString('x,y1\n0,1\n1,2\n2,3\n');

      final error = await vm.importFromCsv(csv.path);

      expect(error, contains('超过绘图历史'));
      expect(vm.pointCount, 0);
      expect(vm.plotRetentionUsage.usedBytes, 0);
    });

    test('materialized objects stay within 250K and last load wins', () async {
      const total = 260000;
      for (var i = 0; i < total; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 4),
        );
      }
      expect(vm.pointCount, total);
      expect(vm.visiblePointCount, lessThanOrEqualTo(250000));

      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 250000));
      expect(vm.isWindowLoading, isTrue);
      expect(vm.statusText, isNot(contains('精确窗口加载中')));
      vm.updateViewport(vm.viewport.copyWith(xMin: 250000, xMax: 259999));
      for (var i = 0; i < 100 && vm.isWindowLoading; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(vm.isWindowLoading, isFalse);
      expect(vm.visibleStartIndex, greaterThan(0));
      expect(vm.visibleStartIndex, lessThanOrEqualTo(250000));
      expect(vm.visibleStartIndex + vm.visiblePointCount, total);
      expect(vm.visiblePointCount, lessThanOrEqualTo(250000));
    });

    test('math LOD and exact cursor use full history with channel offsets', () {
      expect(
        vm.configureMathChannel(0, 'CH0[1] + CH1', vm.mathChannels[0].display),
        isTrue,
      );
      for (var i = 0; i < 256; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble(), (i * 2).toDouble()], bytesConsumed: 8),
        );
      }

      final lod = vm.lodIndex.query(
        channelIndex: 16,
        xMin: 0,
        xMax: 255,
        plotWidth: 1,
      );
      expect(lod, isNotNull);
      expect(lod!.values.where((value) => value.isFinite), isNotEmpty);

      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 255));
      vm.updateFollowCursor(200, 0, Offset.zero);
      expect(vm.cursor!.channelValues!.last, 599);
    });

    test('large-range statistics explicitly use approximate sampling', () {
      for (var i = 0; i < 100100; i++) {
        vm.ingestParsedResultForTest(
          ParseResult.ok([i.toDouble()], bytesConsumed: 4),
        );
      }
      vm.updateViewport(vm.viewport.copyWith(xMin: 0, xMax: 100099));
      vm.toggleStats();

      expect(vm.statsText, contains('Mode: 约 100000 samples'));
      expect(vm.statsText, contains('Range: 0 ~ 100099'));
    });
  });
}
