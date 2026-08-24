import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';

import '../../support/plot_lod_benchmark_data.dart';

void main() {
  test('五类固定数据集均生成四通道且可在 80K 全范围查询', () {
    for (final dataset in PlotLodBenchmarkDataset.values) {
      final index = buildPlotLodBenchmarkIndex(dataset, 80000);
      expect(index.length, 80000, reason: dataset.id);
      expect(index.maxChannelCount, 4, reason: dataset.id);
      for (var channel = 0; channel < 4; channel++) {
        expect(
          index.query(
            channelIndex: channel,
            xMin: 0,
            xMax: 79999,
            plotWidth: 1000,
            quality: PlotLodQuality.quality,
          ),
          isNotNull,
          reason: '${dataset.id}/ch$channel',
        );
      }
    }
  });

  test('突变、脉冲和阶跃数据的关键极值保留在LOD摘要中', () {
    final spike = buildPlotLodBenchmarkIndex(
      PlotLodBenchmarkDataset.isolatedSpike,
      80000,
    );
    final spikePositive = spike.query(
      channelIndex: 0,
      xMin: 0,
      xMax: 79999,
      plotWidth: 1000,
      quality: PlotLodQuality.balanced,
    );
    final spikeNegative = spike.query(
      channelIndex: 2,
      xMin: 0,
      xMax: 79999,
      plotWidth: 1000,
      quality: PlotLodQuality.balanced,
    );
    expect(spikePositive!.values, contains(10000));
    expect(spikeNegative!.values, contains(-10000));

    final pulse = buildPlotLodBenchmarkIndex(
      PlotLodBenchmarkDataset.pulse,
      80000,
    );
    for (var channel = 0; channel < 4; channel++) {
      final series = pulse.query(
        channelIndex: channel,
        xMin: 0,
        xMax: 79999,
        plotWidth: 1000,
        quality: PlotLodQuality.quality,
      );
      expect(series!.values, contains(10000), reason: 'pulse/ch$channel');
    }

    final step = buildPlotLodBenchmarkIndex(
      PlotLodBenchmarkDataset.stepAndPeriodic,
      80000,
    ).query(
      channelIndex: 0,
      xMin: 0,
      xMax: 79999,
      plotWidth: 1000,
      quality: PlotLodQuality.quality,
    );
    expect(step!.values, containsAll(<double>[0, 10000]));
  });
}
