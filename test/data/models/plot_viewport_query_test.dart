import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';
import 'package:vscope_serial/data/models/plot_viewport_query.dart';

void main() {
  group('PlotViewportQuery', () {
    test('三档按每物理像素1、2、4点切换原始折线', () {
      PlotGeometryBatch query(int pointCount, PlotLodQuality quality) {
        final data = <PlotDataPoint>[
          for (var i = 0; i < pointCount; i++)
            PlotDataPoint(
              index: i,
              timestamp: i.toDouble(),
              values: [math.sin(i * 0.1)],
            ),
        ];
        return PlotViewportQuery.queryChannel(
          exactData: data,
          rangeIndex: null,
          channelIndex: 0,
          xMin: 0,
          xMax: pointCount - 1,
          logicalPlotWidth: 100,
          devicePixelRatio: 1,
          quality: quality,
          workspace: PlotGeometryWorkspace(),
        )!;
      }

      expect(query(150, PlotLodQuality.performance).isRaw, isFalse);
      expect(query(150, PlotLodQuality.balanced).isRaw, isTrue);
      expect(query(150, PlotLodQuality.quality).isRaw, isTrue);
      expect(query(350, PlotLodQuality.performance).isRaw, isFalse);
      expect(query(350, PlotLodQuality.balanced).isRaw, isFalse);
      expect(query(350, PlotLodQuality.quality).isRaw, isTrue);
    });

    test('高密度时性能档合并两列，均衡与质量档使用相同单列M4', () {
      final data = <PlotDataPoint>[
        for (var i = 0; i < 2000; i++)
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: [math.sin(i * 0.07) * 100],
          ),
      ];

      PlotGeometryBatch query(PlotLodQuality quality) =>
          PlotViewportQuery.queryChannel(
            exactData: data,
            rangeIndex: null,
            channelIndex: 0,
            xMin: 0,
            xMax: 1999,
            logicalPlotWidth: 100,
            devicePixelRatio: 1,
            quality: quality,
            workspace: PlotGeometryWorkspace(),
          )!;

      final performance = query(PlotLodQuality.performance);
      final balanced = query(PlotLodQuality.balanced);
      final quality = query(PlotLodQuality.quality);
      expect(performance.isRaw, isFalse);
      expect(balanced.isRaw, isFalse);
      expect(quality.isRaw, isFalse);
      expect(performance.length, lessThan(balanced.length));
      expect(quality.indices, orderedEquals(balanced.indices));
      expect(quality.values, orderedEquals(balanced.values));
    });

    test('低密度正弦使用原始点并保持严格时序', () {
      final data = <PlotDataPoint>[
        for (var i = 0; i < 1000; i++)
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: [math.sin(i * 0.03)],
          ),
      ];

      final batch = PlotViewportQuery.queryChannel(
        exactData: data,
        rangeIndex: null,
        channelIndex: 0,
        xMin: 0,
        xMax: 999,
        logicalPlotWidth: 500,
        devicePixelRatio: 1,
        quality: PlotLodQuality.quality,
        workspace: PlotGeometryWorkspace(),
      );

      expect(batch, isNotNull);
      expect(batch!.isRaw, isTrue);
      expect(batch.length, 1000);
      for (var i = 1; i < batch.length; i++) {
        expect(batch.indices[i], greaterThan(batch.indices[i - 1]));
      }
    });

    test('屏幕级M4按真实序号连接并保留孤立尖峰', () {
      final data = <PlotDataPoint>[];
      for (var i = 0; i < 5000; i++) {
        data.add(
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: [i == 2501 ? 10000 : 0],
          ),
        );
      }

      final batch = PlotViewportQuery.queryChannel(
        exactData: data,
        rangeIndex: null,
        channelIndex: 0,
        xMin: 0,
        xMax: 4999,
        logicalPlotWidth: 200,
        devicePixelRatio: 1,
        quality: PlotLodQuality.balanced,
        workspace: PlotGeometryWorkspace(),
      );

      expect(batch, isNotNull);
      expect(batch!.isRaw, isFalse);
      expect(batch.values, contains(10000));
      expect(batch.length, lessThanOrEqualTo(200 * 4));
      for (var i = 1; i < batch.length; i++) {
        expect(batch.indices[i], greaterThan(batch.indices[i - 1]));
      }
    });

    test('最细范围候选不会把尖峰扩展成固定64点宽度', () {
      final lod = PlotLodIndex();
      for (var i = 0; i < 2048; i++) {
        lod.add(i, [i == 1030 ? 10000 : 0]);
      }

      final batch = PlotViewportQuery.queryChannel(
        exactData: const [],
        rangeIndex: lod,
        channelIndex: 0,
        xMin: 0,
        xMax: 2047,
        logicalPlotWidth: 900,
        devicePixelRatio: 1,
        quality: PlotLodQuality.quality,
        workspace: PlotGeometryWorkspace(),
      );

      expect(batch, isNotNull);
      final peak = batch!.values.indexOf(10000);
      expect(peak, greaterThanOrEqualTo(0));
      final left = peak > 0 ? batch.indices[peak - 1] : batch.indices[peak];
      final right =
          peak + 1 < batch.length
              ? batch.indices[peak + 1]
              : batch.indices[peak];
      final projectedWidth = (right - left) * 900 / 2047;
      expect(projectedWidth, lessThanOrEqualTo(6));
    });

    test('性能档最多合并两个物理像素列且仍保留包络', () {
      final data = <PlotDataPoint>[
        for (var i = 0; i < 10000; i++)
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: [math.sin(i * 0.02) * 100],
          ),
      ];

      final batch = PlotViewportQuery.queryChannel(
        exactData: data,
        rangeIndex: null,
        channelIndex: 0,
        xMin: 0,
        xMax: 9999,
        logicalPlotWidth: 250,
        devicePixelRatio: 2,
        quality: PlotLodQuality.performance,
        workspace: PlotGeometryWorkspace(),
      );

      expect(batch, isNotNull);
      expect(batch!.length, lessThanOrEqualTo(250 * 4));
      expect(batch.values.reduce(math.min), lessThan(-99));
      expect(batch.values.reduce(math.max), greaterThan(99));
    });

    test('原始数据中的无效值会切断折线', () {
      final data = <PlotDataPoint>[
        for (var i = 0; i < 20; i++)
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: [i == 10 ? double.nan : i.toDouble()],
          ),
      ];

      final batch = PlotViewportQuery.queryChannel(
        exactData: data,
        rangeIndex: null,
        channelIndex: 0,
        xMin: 0,
        xMax: 19,
        logicalPlotWidth: 100,
        devicePixelRatio: 1,
        quality: PlotLodQuality.performance,
        workspace: PlotGeometryWorkspace(),
      );

      expect(batch, isNotNull);
      expect(batch!.runCount, 2);
      expect(batch.runOffsets, orderedEquals([0, 10, 19]));
    });
  });
}
