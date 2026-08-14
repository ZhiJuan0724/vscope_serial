import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vscope_serial/core/utils/plot_performance_metrics.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';
import 'package:vscope_serial/data/models/plot_render_engine.dart';
import 'package:vscope_serial/views/plot/plot_layer_stack.dart';
import 'package:vscope_serial/views/plot/plot_render_snapshot.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

import '../test/support/plot_lod_benchmark_data.dart';

const _label = String.fromEnvironment(
  'PLOT_BENCHMARK_LABEL',
  defaultValue: 'lod-optimized',
);
const _outputDirectory = String.fromEnvironment(
  'PLOT_BENCHMARK_OUTPUT_DIR',
  defaultValue: 'build/performance',
);
const _quick = bool.fromEnvironment('PLOT_LOD_BENCHMARK_QUICK');
const _gateOnly = bool.fromEnvironment('PLOT_LOD_BENCHMARK_GATE');
const _renderEngineName = String.fromEnvironment(
  'PLOT_RENDER_ENGINE',
  defaultValue: 'canvas',
);
const _renderEngine =
    _renderEngineName == 'd3d11'
        ? PlotRenderEngine.d3d11
        : PlotRenderEngine.canvas;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('静态历史 LOD 拖动性能基准', (tester) async {
    expect(PlotPerformanceMetrics.enabled, isTrue);
    final reports = <Map<String, Object?>>[];
    for (final pointCount in const <int>[80000, 500000]) {
      if (_gateOnly && pointCount != 500000) continue;
      for (final dataset in PlotLodBenchmarkDataset.values) {
        if (_gateOnly && dataset != PlotLodBenchmarkDataset.noiseMixed) {
          continue;
        }
        // 数据构建不计入拖动指标；同一索引复用到两档质量和两个视口范围。
        final lod = buildPlotLodBenchmarkIndex(dataset, pointCount);
        for (final quality in const <PlotLodQuality>[
          PlotLodQuality.performance,
          PlotLodQuality.balanced,
          PlotLodQuality.quality,
        ]) {
          for (final rangeRatio in const <double>[1, 0.125]) {
            if (_gateOnly && rangeRatio != 0.125) continue;
            final repeats = _quick ? 1 : 3;
            for (var repeat = 0; repeat < repeats; repeat++) {
              reports.addAll(
                await _runDragScenario(
                  tester,
                  lod: lod,
                  pointCount: pointCount,
                  dataset: dataset,
                  quality: quality,
                  rangeRatio: rangeRatio,
                  repeat: repeat + 1,
                ),
              );
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }

    final report = <String, Object?>{
      'label': _label,
      'createdAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystemVersion,
      'quick': _quick,
      'gateOnly': _gateOnly,
      'renderEngine': _renderEngine.name,
      'scenarios': reports,
      'gate': _evaluateRenderingGate(reports),
    };
    await _writeReport(report);
  }, timeout: const Timeout(Duration(minutes: 90)));
}

Future<List<Map<String, Object?>>> _runDragScenario(
  WidgetTester tester, {
  required PlotLodIndex lod,
  required int pointCount,
  required PlotLodBenchmarkDataset dataset,
  required PlotLodQuality quality,
  required double rangeRatio,
  required int repeat,
}) async {
  final key = GlobalKey<_LodDragSurfaceState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: _LodDragSurface(
          key: key,
          lod: lod,
          pointCount: pointCount,
          quality: quality,
          rangeRatio: rangeRatio,
        ),
      ),
    ),
  );
  await Future<void>.delayed(
    _quick ? const Duration(milliseconds: 300) : const Duration(seconds: 1),
  );
  final reports = <Map<String, Object?>>[];
  for (final mode in _DragMode.values) {
    key.currentState?.setMode(mode);
    await Future<void>.delayed(
      _quick ? const Duration(milliseconds: 200) : const Duration(seconds: 1),
    );
    reports.add(
      await _measureDragMode(
        pointCount: pointCount,
        dataset: dataset,
        quality: quality,
        rangeRatio: rangeRatio,
        repeat: repeat,
        mode: mode,
      ),
    );
  }
  key.currentState?.stop();
  return reports;
}

Future<Map<String, Object?>> _measureDragMode({
  required int pointCount,
  required PlotLodBenchmarkDataset dataset,
  required PlotLodQuality quality,
  required double rangeRatio,
  required int repeat,
  required _DragMode mode,
}) async {
  PlotPerformanceMetrics.instance.reset();
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> values) => timings.addAll(values);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final duration =
      _quick ? const Duration(seconds: 1) : const Duration(seconds: 8);
  final elapsed = Stopwatch()..start();
  await Future<void>.delayed(duration);
  elapsed.stop();
  SchedulerBinding.instance.removeTimingsCallback(collect);

  final total = timings
    .map((value) => value.totalSpan.inMicroseconds)
    .toList(growable: false)..sort();
  final build = timings
    .map((value) => value.buildDuration.inMicroseconds)
    .toList(growable: false)..sort();
  final raster = timings
    .map((value) => value.rasterDuration.inMicroseconds)
    .toList(growable: false)..sort();
  final samples = PlotPerformanceMetrics.instance.sampleSnapshot();
  final counters = PlotPerformanceMetrics.instance.snapshot();
  final cacheHits = counters[PlotPerformanceMetric.lodCacheHit] ?? 0;
  final cacheMisses = counters[PlotPerformanceMetric.lodCacheMiss] ?? 0;
  final cacheTotal = cacheHits + cacheMisses;
  final over16 = total.where((value) => value > 16667).length;
  final over33 = total.where((value) => value > 33333).length;
  final over50 = total.where((value) => value > 50000).length;
  final fps = _actualFps(timings, elapsed.elapsed);
  final gpuSubmissions = counters[PlotPerformanceMetric.gpuSubmitCount] ?? 0;
  final elapsedSeconds = math.max(
    0.001,
    elapsed.elapsed.inMicroseconds / 1000000,
  );

  return <String, Object?>{
    'name':
        '${pointCount ~/ 1000}K-${dataset.id}-${quality.name}-${rangeRatio == 1 ? 'full' : 'one-eighth'}-${mode.id}-R$repeat',
    'pointCount': pointCount,
    'dataset': dataset.id,
    'quality': quality.name,
    'rangeRatio': rangeRatio,
    'repeat': repeat,
    'dragMode': mode.id,
    'frameCount': timings.length,
    'fps': fps,
    'gpuSubmissionCount': gpuSubmissions,
    'gpuSubmissionFps': gpuSubmissions / elapsedSeconds,
    'frameTotalMs': _summary(total, divisor: 1000),
    'frameBuildMs': _summary(build, divisor: 1000),
    'frameRasterMs': _summary(raster, divisor: 1000),
    'over16Ratio': timings.isEmpty ? 0 : over16 / timings.length,
    'over33Ratio': timings.isEmpty ? 0 : over33 / timings.length,
    'over50Ratio': timings.isEmpty ? 0 : over50 / timings.length,
    'lodQueryMs': _summary(
      samples[PlotPerformanceMetric.lodQueryMicros] ?? const <int>[],
      divisor: 1000,
    ),
    'geometryBuildMs': _summary(
      samples[PlotPerformanceMetric.geometryBuildMicros] ?? const <int>[],
      divisor: 1000,
    ),
    'canvasSubmitMs': _summary(
      samples[PlotPerformanceMetric.canvasSubmitMicros] ?? const <int>[],
      divisor: 1000,
    ),
    'gpuSubmitMs': _summary(
      samples[PlotPerformanceMetric.gpuSubmitMicros] ?? const <int>[],
      divisor: 1000,
    ),
    'gpuSegmentCount': _summary(
      samples[PlotPerformanceMetric.gpuSegmentCount] ?? const <int>[],
      divisor: 1,
    ),
    'cacheHitRatio': cacheTotal == 0 ? 0 : cacheHits / cacheTotal,
    'bufferGrowths': counters[PlotPerformanceMetric.geometryBufferGrowth] ?? 0,
    'counters': counters,
  };
}

double _actualFps(List<FrameTiming> timings, Duration fallbackDuration) {
  if (timings.length < 2) {
    return timings.length /
        math.max(0.001, fallbackDuration.inMicroseconds / 1000000);
  }
  final first = timings.first.timestampInMicroseconds(FramePhase.rasterFinish);
  final last = timings.last.timestampInMicroseconds(FramePhase.rasterFinish);
  return (timings.length - 1) * 1000000 / math.max(1, last - first);
}

Map<String, double> _summary(List<int> values, {required double divisor}) {
  if (values.isEmpty) {
    return const <String, double>{'p50': 0, 'p95': 0, 'p99': 0, 'max': 0};
  }
  final sorted = values.toList()..sort();
  double at(double percentile) =>
      sorted[((sorted.length - 1) * percentile).round()] / divisor;
  return <String, double>{
    'p50': at(0.5),
    'p95': at(0.95),
    'p99': at(0.99),
    'max': sorted.last / divisor,
  };
}

Map<String, Object?> _evaluateRenderingGate(
  List<Map<String, Object?>> reports,
) {
  final grouped = <String, List<Map<String, Object?>>>{};
  for (final report in reports) {
    final key = <Object?>[
      report['pointCount'],
      report['dataset'],
      report['quality'],
      report['rangeRatio'],
      report['dragMode'],
    ].join('|');
    grouped.putIfAbsent(key, () => <Map<String, Object?>>[]).add(report);
  }

  final failed = <String>[];
  final groupResults = <Map<String, Object?>>[];
  for (final entry in grouped.entries) {
    final group = entry.value;
    final quality = PlotLodQuality.values.byName(
      group.first['quality']! as String,
    );
    final pointCount = group.first['pointCount']! as int;
    final minimumFps = switch (quality) {
      PlotLodQuality.performance => 50.0,
      PlotLodQuality.balanced => pointCount <= 80000 ? 50.0 : 30.0,
      PlotLodQuality.quality => 30.0,
    };
    final fps = _median(
      group.map((item) => (item['fps']! as num).toDouble()).toList(),
    );
    final gpuSubmissionFps = _median(
      group
          .map((item) => (item['gpuSubmissionFps']! as num).toDouble())
          .toList(),
    );
    final effectiveFps =
        _renderEngine == PlotRenderEngine.d3d11 ? gpuSubmissionFps : fps;
    final totalP95 = _median(
      group
          .map((item) => (item['frameTotalMs']! as Map<String, double>)['p95']!)
          .toList(),
    );
    final over50Ratio = _median(
      group.map((item) => (item['over50Ratio']! as num).toDouble()).toList(),
    );
    // 单轮一秒的 quick 仅用于筛查，初次纹理生成会显著放大长帧比例；
    // “超过 50 ms 不高于 1%”只由三轮八秒的正式组合判定。
    final failedFrameGate =
        effectiveFps <= minimumFps ||
        totalP95 > 33.3 ||
        (group.length >= 3 && over50Ratio > 0.01);
    if (failedFrameGate) failed.add(entry.key);
    groupResults.add(<String, Object?>{
      'group': entry.key,
      'repeats': group.length,
      'medianFps': fps,
      'medianGpuSubmissionFps': gpuSubmissionFps,
      'medianTotalP95Ms': totalP95,
      'medianOver50Ratio': over50Ratio,
      'passed': !failedFrameGate,
    });
  }
  return <String, Object?>{
    'failedGroups': failed,
    'groupResults': groupResults,
    'renderingPerformanceGatePassed': failed.isEmpty,
    'canvasPerformanceGatePassed':
        _renderEngine == PlotRenderEngine.canvas && failed.isEmpty,
    'gpuPrototypeRequired':
        _renderEngine == PlotRenderEngine.canvas && failed.isNotEmpty,
  };
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  values.sort();
  final middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

Future<void> _writeReport(Map<String, Object?> report) async {
  final directory = Directory(_outputDirectory);
  await directory.create(recursive: true);
  await File('${directory.path}/$_label.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );

  final scenarios = report['scenarios']! as List<Map<String, Object?>>;
  final buffer =
      StringBuffer()
        ..writeln('# LOD 拖动性能报告：$_label')
        ..writeln()
        ..writeln(
          '| 场景 | FPS | GPU FPS | GPU P95 | 线段 | Total P95 | Build P95 | Raster P95 | LOD P95 | Geometry P95 | Cache | >33ms | >50ms |',
        )
        ..writeln(
          '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|',
        );
  for (final scenario in scenarios) {
    double p95(String key) => (scenario[key]! as Map<String, double>)['p95']!;
    buffer.writeln(
      '| ${scenario['name']} '
      '| ${(scenario['fps']! as num).toDouble().toStringAsFixed(1)} '
      '| ${(scenario['gpuSubmissionFps']! as num).toDouble().toStringAsFixed(1)} '
      '| ${p95('gpuSubmitMs').toStringAsFixed(2)} '
      '| ${p95('gpuSegmentCount').toStringAsFixed(0)} '
      '| ${p95('frameTotalMs').toStringAsFixed(2)} '
      '| ${p95('frameBuildMs').toStringAsFixed(2)} '
      '| ${p95('frameRasterMs').toStringAsFixed(2)} '
      '| ${p95('lodQueryMs').toStringAsFixed(2)} '
      '| ${p95('geometryBuildMs').toStringAsFixed(2)} '
      '| ${((scenario['cacheHitRatio']! as num) * 100).toStringAsFixed(1)}% '
      '| ${((scenario['over33Ratio']! as num) * 100).toStringAsFixed(1)}% '
      '| ${((scenario['over50Ratio']! as num) * 100).toStringAsFixed(1)}% |',
    );
  }
  buffer
    ..writeln()
    ..writeln('```json')
    ..writeln(const JsonEncoder.withIndent('  ').convert(report['gate']))
    ..writeln('```');
  await File(
    '${directory.path}/$_label.md',
  ).writeAsString(buffer.toString(), flush: true);
}

class _LodDragSurface extends StatefulWidget {
  const _LodDragSurface({
    super.key,
    required this.lod,
    required this.pointCount,
    required this.quality,
    required this.rangeRatio,
  });

  final PlotLodIndex lod;
  final int pointCount;
  final PlotLodQuality quality;
  final double rangeRatio;

  @override
  State<_LodDragSurface> createState() => _LodDragSurfaceState();
}

class _LodDragSurfaceState extends State<_LodDragSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();
  final channels = <ChannelConfig>[
    ChannelConfig(index: 0, color: Colors.red),
    ChannelConfig(index: 1, color: Colors.green),
    ChannelConfig(index: 2, color: Colors.blue),
    ChannelConfig(index: 3, color: Colors.orange),
  ];
  _DragMode _mode = _DragMode.x;

  void stop() => _controller.stop();

  void setMode(_DragMode value) {
    if (_mode == value) return;
    _controller
      ..value = 0
      ..repeat();
    setState(() => _mode = value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final total = (widget.pointCount - 1).toDouble();
        final range = total * widget.rangeRatio;
        final travel = widget.rangeRatio == 1 ? total * 0.04 : total - range;
        final elapsedSeconds = _controller.value * 20;
        final horizontalProgress = switch (_mode) {
          _DragMode.x ||
          _DragMode.diagonal => _triangleWave(elapsedSeconds / 10),
          // 每两次同向大幅拖动后停留约一秒查看波形，再向相反方向重复。
          _DragMode.largeSweep => _largeSweepProgress(elapsedSeconds),
          // 更高频地左右往返，覆盖用户连续反复拖动造成的缓存换窗压力。
          _DragMode.rapidHorizontal => _triangleWave(elapsedSeconds * 4),
        };
        final start =
            (widget.rangeRatio == 1 ? -total * 0.02 : 0) +
            travel * horizontalProgress;
        final yShift =
            _mode == _DragMode.diagonal
                ? (horizontalProgress - 0.5) * 6000
                : 0.0;
        return PlotLayerStack(
          snapshot: PlotRenderSnapshot(
            viewport: PlotViewport(
              xMin: start,
              xMax: start + range,
              yMin: -12000 + yShift,
              yMax: 12000 + yShift,
            ),
            data: const [],
            dataRevision: 1,
            viewportRevision: (_controller.value * 1000000).round(),
            lodIndex: widget.lod,
            lodQuality: widget.quality,
            renderEngine: _renderEngine,
            interactionActive: true,
            channels: channels,
            activeChannelCount: 4,
            showGrid: true,
            backgroundStyle: PlotBackgroundStyle.light,
          ),
        );
      },
    );
  }

  double _triangleWave(double cycles) {
    final phase = cycles % 2;
    return phase <= 1 ? phase : 2 - phase;
  }

  double _largeSweepProgress(double elapsedSeconds) {
    const dragPairSeconds = 0.7;
    const inspectionPauseSeconds = 1.0;
    const halfCycleSeconds = dragPairSeconds + inspectionPauseSeconds;
    final phase = elapsedSeconds % (halfCycleSeconds * 2);
    final movingForward = phase < halfCycleSeconds;
    final local = phase % halfCycleSeconds;
    final pairProgress = (local / dragPairSeconds).clamp(0.0, 1.0);
    return movingForward ? pairProgress : 1 - pairProgress;
  }
}

enum _DragMode {
  x('x'),
  diagonal('diagonal'),
  largeSweep('large-sweep'),
  rapidHorizontal('rapid-horizontal');

  const _DragMode(this.id);
  final String id;
}
