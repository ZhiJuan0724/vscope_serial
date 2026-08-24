import 'dart:math' as math;

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

    test('连续正弦桶不标记为阶跃，二值阶跃保留边沿类型', () {
      final sine = PlotLodIndex();
      final step = PlotLodIndex();
      for (var i = 0; i < 2048; i++) {
        sine.add(i, [math.sin(i * 0.07)]);
        step.add(i, [i < 1030 ? 0.0 : 1.0]);
      }

      final sineSeries = sine.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 2047,
        plotWidth: 128,
      );
      final stepSeries = step.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 2047,
        plotWidth: 128,
      );

      expect(sineSeries, isNotNull);
      expect(sineSeries!.bucketStepKinds, everyElement(0));
      expect(stepSeries, isNotNull);
      expect(stepSeries!.bucketStepKinds, contains(1));
    });

    test(
      'query exposes contiguous sample ranges for each populated bucket',
      () {
        final index = PlotLodIndex();
        for (int i = 0; i < 512; i++) {
          index.add(i, [i == 130 ? 1000.0 : 0.0]);
        }

        final series = index.query(
          channelIndex: 0,
          xMin: 0,
          xMax: 511,
          plotWidth: 4,
          quality: PlotLodQuality.quality,
        );

        expect(series, isNotNull);
        expect(series!.bucketOffsets.first, 0);
        expect(series.bucketOffsets.last, series.length);
        for (var i = 1; i < series.bucketOffsets.length; i++) {
          expect(
            series.bucketOffsets[i],
            greaterThan(series.bucketOffsets[i - 1]),
          );
        }
      },
    );

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

    test('late channel uses its own first and last sample indices', () {
      final index = PlotLodIndex();
      index.add(0, [1.0]);
      index.add(1, [2.0]);
      index.add(2, [3.0, 20.0]);
      index.add(3, [4.0, 30.0]);

      final series = index.queryFinest(channelIndex: 1, xMin: 0, xMax: 7);

      expect(series, isNotNull);
      expect(series!.indices.first, 2);
      expect(series.indices.last, 3);
      expect(series.values.first, 20);
      expect(series.values.last, 30);
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
      // 范围摘要最多保留每个显示列的 first/min/max/last 候选，不能为
      // 追求旧的更小点数重新牺牲峰值和时序信息。
      expect(series!.length, lessThanOrEqualTo(1200 * 4));
    });

    test('balanced and quality select progressively finer LOD levels', () {
      final index = PlotLodIndex();
      for (var i = 0; i < 100000; i++) {
        index.add(i, [math.sin(i / 31)]);
      }

      final performance = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 99999,
        plotWidth: 400,
      );
      final balanced = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 99999,
        plotWidth: 400,
        quality: PlotLodQuality.balanced,
      );
      final quality = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 99999,
        plotWidth: 400,
        quality: PlotLodQuality.quality,
      );

      expect(performance, isNotNull);
      expect(balanced, isNotNull);
      expect(quality, isNotNull);
      expect(balanced!.length, greaterThan(performance!.length));
      expect(quality!.length, greaterThan(balanced.length));
      // 最细 64 点桶可输出首尾及极值，结果仍受像素宽度的常数倍约束。
      expect(quality.length, lessThanOrEqualTo(400 * 12 + 8));
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

    test(
      'viewport cache prefetches nearby buckets and invalidates on append',
      () {
        final index = PlotLodIndex();
        for (var i = 0; i < 4096; i++) {
          index.add(i, [math.sin(i / 13)]);
        }

        final first = index.query(
          channelIndex: 0,
          xMin: 1000,
          xMax: 2000,
          plotWidth: 200,
          useViewportCache: true,
        );
        final nearby = index.query(
          channelIndex: 0,
          xMin: 1050,
          xMax: 2050,
          plotWidth: 200,
          useViewportCache: true,
        );
        expect(nearby, same(first));

        index.add(4096, [1]);
        final afterAppend = index.query(
          channelIndex: 0,
          xMin: 1050,
          xMax: 2050,
          plotWidth: 200,
          useViewportCache: true,
        );
        expect(afterAppend, isNot(same(first)));
      },
    );

    test(
      'coarse query bypasses density threshold during exact window load',
      () {
        final index = PlotLodIndex();
        for (var i = 0; i < 2048; i++) {
          index.add(i, [math.sin(i / 17)]);
        }

        expect(
          index.query(channelIndex: 0, xMin: 500, xMax: 550, plotWidth: 800),
          isNull,
        );
        final coarse = index.queryCoarse(
          channelIndex: 0,
          xMin: 500,
          xMax: 550,
          plotWidth: 800,
        );

        expect(coarse, isNotNull);
        expect(coarse!.length, lessThanOrEqualTo(32));
      },
    );

    test('interaction bucket scale selects a coarser bounded preview', () {
      final index = PlotLodIndex();
      for (var i = 0; i < 500000; i++) {
        index.add(i, [math.sin(i / 17)]);
      }
      final settled = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 499999,
        plotWidth: 1000,
      );
      final preview = index.query(
        channelIndex: 0,
        xMin: 0,
        xMax: 499999,
        plotWidth: 1000,
        targetBucketScale: 8,
      );

      expect(preview, isNotNull);
      expect(preview!.bucketCount, lessThan(settled!.bucketCount));
      expect(preview.bucketCount, lessThanOrEqualTo(160));
    });
  });
}
