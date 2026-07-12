import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';

void main() {
  group('PlotLodIndex', () {
    test('preserves step extrema in coarse query', () {
      final index = PlotLodIndex();
      for (int i = 0; i < 512; i++) {
        final value =
            i < 128
                ? 0.0
                : i < 256
                ? 100.0
                : i < 384
                ? 200.0
                : 0.0;
        index.add(i, [value]);
      }

      final series = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 511,
        plotWidth: 4,
      );

      expect(series, isNotNull);
      expect(series!.values, containsAll([0.0, 100.0, 200.0]));
    });

    test('query returns ordered unique indices', () {
      final index = PlotLodIndex();
      for (int i = 0; i < 1024; i++) {
        index.add(i, [i.isEven ? i.toDouble() : -i.toDouble()]);
      }

      final series = index.query(
        channelIndex: 0,
        xMin: 100,
        xMax: 900,
        plotWidth: 8,
      );

      expect(series, isNotNull);
      var previous = -1;
      final seen = <int>{};
      for (final pointIndex in series!.indices) {
        expect(pointIndex, greaterThan(previous));
        expect(seen.add(pointIndex), isTrue);
        previous = pointIndex;
      }
    });

    test('tracks max channel count for variable JustFloat frames', () {
      final index = PlotLodIndex();
      index.add(0, [1.0, 2.0, 3.0]);
      index.add(1, [10.0, 20.0]);

      expect(index.maxChannelCount, 3);
      expect(
        index.query(channelIndex: 2, xMin: 0, xMax: 100, plotWidth: 1),
        isNotNull,
      );
      expect(
        index.query(channelIndex: 3, xMin: 0, xMax: 100, plotWidth: 1),
        isNull,
      );
    });

    test('sampled updates do not allocate skipped buckets', () {
      final index = PlotLodIndex();
      for (var i = 0; i < 100000; i++) {
        index.addSampled(i, [i.toDouble()], 1024);
      }

      expect(index.length, 100000);
      expect(index.allocatedBucketCount, lessThan(1000));
      expect(
        index.query(channelIndex: 0, xMin: 0, xMax: 99999, plotWidth: 100),
        isNotNull,
      );
    });

    test('medium density query uses LOD instead of scanning every point', () {
      final index = PlotLodIndex();
      for (var i = 0; i < 30000; i++) {
        index.add(i, [i.isEven ? 1.0 : -1.0]);
      }

      final series = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 29999,
        plotWidth: 1200,
      );

      expect(series, isNotNull);
      expect(series!.length, lessThan(2000));
    });

    test('overview query returns bounded bucket samples for long history', () {
      final index = PlotLodIndex();
      for (var i = 0; i < 100000; i++) {
        index.addSampled(i, [i.toDouble()], 64);
      }

      final series = index.queryOverview(
        channelIndex: 0,
        xMin: 0,
        xMax: 99999,
        plotWidth: 400,
      );

      expect(series, isNotNull);
      expect(series!.length, lessThan(4000));
    });
  });
}
