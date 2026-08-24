import 'dart:math' as math;

import 'package:vscope_serial/data/models/plot_lod_index.dart';

/// 固定的 LOD 正确性与性能数据集。
///
/// 所有公式均为确定性输入；噪声组使用本地固定种子，不受测试执行顺序影响。
enum PlotLodBenchmarkDataset {
  sine('sine'),
  isolatedSpike('isolated-spike'),
  pulse('pulse'),
  stepAndPeriodic('step-periodic'),
  noiseMixed('noise-mixed');

  const PlotLodBenchmarkDataset(this.id);
  final String id;
}

PlotLodIndex buildPlotLodBenchmarkIndex(
  PlotLodBenchmarkDataset dataset,
  int pointCount,
) {
  final index = PlotLodIndex();
  final values = List<double>.filled(4, 0);
  final random = math.Random(0x5C0FE);
  final center = pointCount ~/ 2;

  for (var i = 0; i < pointCount; i++) {
    switch (dataset) {
      case PlotLodBenchmarkDataset.sine:
        values[0] = math.sin(i * 2 * math.pi / 997) * 1000;
        values[1] = math.sin(i * 2 * math.pi / 257 + 0.7) * 3500;
        values[2] = 2400 + math.sin(i * 2 * math.pi / 4093) * 800;
        values[3] =
            math.sin(i * 2 * math.pi / 601) * 1400 +
            math.sin(i * 2 * math.pi / 67) * 280;
        break;
      case PlotLodBenchmarkDataset.isolatedSpike:
        values[0] = i == center ? 10000 : 0;
        values[1] = switch (i - center) {
          -2 || 2 => 100,
          -1 || 1 => 500,
          0 => 10000,
          _ => 0,
        };
        values[2] = i == center ? -10000 : 1000;
        values[3] = switch (i) {
          _ when i == pointCount ~/ 4 => 8000,
          _ when i == pointCount * 3 ~/ 4 => -8000,
          _ => 0,
        };
        break;
      case PlotLodBenchmarkDataset.pulse:
        const widths = <int>[1, 4, 16, 64];
        for (var channel = 0; channel < 4; channel++) {
          final width = widths[channel];
          final start = center + (channel.isEven ? 17 : 64 - width ~/ 2);
          values[channel] = i >= start && i < start + width ? 10000 : 0;
        }
        break;
      case PlotLodBenchmarkDataset.stepAndPeriodic:
        values[0] = i < center ? 0 : 10000;
        values[1] = i % 400 < 100 ? 10000 : 0;
        values[2] = (i % 400) * 25.0;
        final trianglePhase = i % 400;
        values[3] =
            trianglePhase < 200
                ? trianglePhase * 50.0
                : (400 - trianglePhase) * 50.0;
        break;
      case PlotLodBenchmarkDataset.noiseMixed:
        final drift = math.sin(i * 2 * math.pi / 8191) * 500;
        for (var channel = 0; channel < 4; channel++) {
          values[channel] =
              drift + (random.nextDouble() - 0.5) * (120 + channel * 30);
        }
        if (i == pointCount ~/ 5) values[0] += 7000;
        if (i == pointCount ~/ 3) values[1] -= 9000;
        if (i >= center && i < center + 8) values[2] += 6000;
        if (i == pointCount * 4 ~/ 5) values[3] -= 7500;
        break;
    }
    index.add(i, values);
  }
  return index;
}
