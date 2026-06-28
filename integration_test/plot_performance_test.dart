import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/utils/plot_performance_metrics.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';

const _preset = String.fromEnvironment(
  'PLOT_BENCHMARK_PRESET',
  defaultValue: 'quick',
);
const _label = String.fromEnvironment(
  'PLOT_BENCHMARK_LABEL',
  defaultValue: 'optimized',
);
const _outputDirectory = String.fromEnvironment(
  'PLOT_BENCHMARK_OUTPUT_DIR',
  defaultValue: 'build/performance',
);

void main() {
  // 集成测试绑定会启动真实 Flutter 应用实例；这里不是普通单元测试，
  // 而是通过 `flutter drive --profile --device-id=windows` 在 Windows 桌面
  // Profile 模式下采集接近真实运行状态的帧耗时。
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 默认测试策略会尽量让测试环境可控，但性能基准需要真实连续出帧。
  // `fullyLive` 让 Scheduler 按应用实际节奏调度帧，FrameTiming 才有参考价值。
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('绘图性能基准', (tester) async {
    // 计数器默认在正式/普通测试中关闭，避免给应用运行时增加额外开销。
    // 只有 run_plot_benchmark.ps1 传入 PLOT_PERF_METRICS=true 时才允许执行。
    expect(
      PlotPerformanceMetrics.enabled,
      isTrue,
      reason: '请通过 test_tools/run_plot_benchmark.ps1 运行性能基准',
    );

    // 这里手动搭建绘图页需要的最小 Provider 环境，不启动完整 main.dart。
    // 好处是测试只覆盖绘图页面和 PlotViewModel，减少更新检查、窗口管理等
    // 与绘图性能无关的因素对结果的干扰。
    final serialService = SerialService();
    final vm = PlotViewModel(serialService);
    addTearDown(() {
      vm.dispose();
      serialService.dispose();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // quick 用于日常前后对比，soak 用于长时间高频压测。
    // 具体场景定义在文件底部，脚本通过 PLOT_BENCHMARK_PRESET 选择。
    final scenarios = _preset == 'soak' ? _soakScenarios : _quickScenarios;
    final reports = <Map<String, Object?>>[];
    for (final scenario in scenarios) {
      reports.add(await _runScenario(vm, scenario));
    }

    final report = <String, Object?>{
      'label': _label,
      'preset': _preset,
      'createdAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystemVersion,
      'scenarios': reports,
    };
    await _writeReport(report);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

Future<Map<String, Object?>> _runScenario(
  PlotViewModel vm,
  _BenchmarkScenario scenario,
) async {
  // 每个场景开始前恢复到干净状态，避免前一个场景留下的数据量、
  // 数学通道、跟随状态或解析器配置污染当前场景。
  if (vm.isPlotting) await vm.stopPlotting();
  vm.clearData();

  // 性能基准固定使用随机 FireWater 源：它不依赖真实串口设备，
  // 但仍走解析、ViewModel、数据缓存、LOD 和绘图链路。
  vm.setParserType(ParserType.fireWater);
  vm.updateParserConfig(
    ParserConfig.fireWaterDefault()
      ..fireWaterChannelCount = scenario.channelCount,
  );
  vm.setRandomFrequency(scenario.frequencyHz.toDouble());
  vm.setUseRandomSource(true);
  vm.setFollowEnabled(scenario.followEnabled);
  if (scenario.mathChannelEnabled) {
    vm.configureMathChannel(0, 'CH0 + CH1', vm.mathChannels.first.display);
  } else if (vm.mathChannels.first.enabled) {
    vm.disableMathChannel(0);
  }

  // PlotPerformanceMetrics 记录开发者计数器，例如页面各区域 build 次数、
  // 各 Painter paint 次数和 ViewModel 通知次数。它用于判断优化是否真的
  // 减少了无关重建，而不仅仅是帧时间偶然变好。
  PlotPerformanceMetrics.instance.reset();

  // FrameTiming 来自 Flutter 引擎，包含 build、raster 和总帧耗时。
  // 这部分只能在真实应用调度帧时采集，所以放在 integration_test 中。
  final frameTimings = <FrameTiming>[];
  void onTimings(List<FrameTiming> timings) => frameTimings.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(onTimings);

  // RSS 不是每帧采集，避免采集本身干扰性能；250ms 足够观察峰值趋势。
  var peakRss = ProcessInfo.currentRss;
  final rssTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
    peakRss = math.max(peakRss, ProcessInfo.currentRss);
  });
  final startRss = ProcessInfo.currentRss;
  final stopwatch = Stopwatch()..start();

  // 场景运行期间不主动操作 UI，只让随机源持续推数据。
  // 这样采到的是“持续接收 + 自动刷新”的基线性能。
  vm.startPlotting();
  await Future<void>.delayed(scenario.duration);

  // 停止绘图后 highRateMode 会恢复，因此运行时状态要在 stop 前记录。
  final effectiveRefreshFpsDuringRun = vm.effectiveRefreshFps;
  final highRateModeDuringRun = vm.highRateMode;
  await vm.stopPlotting();

  stopwatch.stop();
  rssTimer.cancel();
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  final endRss = ProcessInfo.currentRss;
  final elapsedSeconds = stopwatch.elapsedMicroseconds / 1000000;

  // 排序后统一计算 p50/p95/p99/max。性能基准不做硬性通过阈值，
  // 这些指标用于本机 baseline/optimized 的前后对比。
  final totalMicros = frameTimings
    .map((timing) => timing.totalSpan.inMicroseconds)
    .toList(growable: false)..sort();
  final buildMicros = frameTimings
    .map((timing) => timing.buildDuration.inMicroseconds)
    .toList(growable: false)..sort();
  final rasterMicros = frameTimings
    .map((timing) => timing.rasterDuration.inMicroseconds)
    .toList(growable: false)..sort();

  return <String, Object?>{
    'name': scenario.name,
    'targetPacketsPerSecond': scenario.frequencyHz,
    'channelCount': scenario.channelCount,
    'durationSeconds': elapsedSeconds,
    'mathChannelEnabled': scenario.mathChannelEnabled,
    'followEnabled': scenario.followEnabled,
    'receivedPoints': vm.pointCount,
    'actualPacketsPerSecond': vm.pointCount / elapsedSeconds,
    'effectiveRefreshFps': effectiveRefreshFpsDuringRun,
    'highRateMode': highRateModeDuringRun,
    'frameCount': frameTimings.length,
    'frameTotalMs': _timingSummary(totalMicros),
    'frameBuildMs': _timingSummary(buildMicros),
    'frameRasterMs': _timingSummary(rasterMicros),
    'rssBytes': <String, int>{
      'start': startRss,
      'end': endRss,
      'peak': peakRss,
    },
    'counters': PlotPerformanceMetrics.instance.snapshot(),
  };
}

Map<String, double> _timingSummary(List<int> sortedMicros) {
  if (sortedMicros.isEmpty) {
    return const <String, double>{'p50': 0, 'p95': 0, 'p99': 0, 'max': 0};
  }
  double percentile(double value) {
    // 使用 round 选择最接近目标分位的样本点。这里不做插值，
    // 因为报告只需要稳定、易读的近似值。
    final index = ((sortedMicros.length - 1) * value).round();
    return sortedMicros[index] / 1000;
  }

  return <String, double>{
    'p50': percentile(0.50),
    'p95': percentile(0.95),
    'p99': percentile(0.99),
    'max': sortedMicros.last / 1000,
  };
}

Future<void> _writeReport(Map<String, Object?> report) async {
  final directory = Directory(_outputDirectory);
  await directory.create(recursive: true);

  // 当 Label 不是 baseline 且目录中已有 baseline.json 时，Markdown 报告会
  // 自动增加变化百分比，方便同一台机器上比较优化前后。
  final baselineFile = File('${directory.path}/baseline.json');
  Map<String, Object?>? baseline;
  if (_label != 'baseline' && await baselineFile.exists()) {
    baseline = Map<String, Object?>.from(
      jsonDecode(await baselineFile.readAsString()) as Map,
    );
  }
  final jsonFile = File('${directory.path}/$_label.json');
  await jsonFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );

  // JSON 保存完整机器可读数据；Markdown 只输出关键场景摘要，
  // 便于开发时快速看速率、帧耗时和内存峰值。
  final buffer =
      StringBuffer()
        ..writeln('# 绘图性能报告：$_label')
        ..writeln();
  if (baseline == null) {
    buffer
      ..writeln('| 场景 | 实际包/s | 帧P95(ms) | 最大帧(ms) | 峰值RSS(MB) |')
      ..writeln('|---|---:|---:|---:|---:|');
  } else {
    buffer
      ..writeln('| 场景 | 实际包/s | 速率变化 | 帧P95(ms) | P95变化 | 峰值RSS(MB) |')
      ..writeln('|---|---:|---:|---:|---:|---:|');
  }
  final baselineScenarios =
      baseline == null
          ? <String, Map<String, Object?>>{}
          : _indexScenarios(baseline);
  for (final scenario in report['scenarios']! as List<Map<String, Object?>>) {
    final frame = scenario['frameTotalMs']! as Map<String, double>;
    final rss = scenario['rssBytes']! as Map<String, int>;
    final actualRate = scenario['actualPacketsPerSecond']! as double;
    final baselineScenario = baselineScenarios[scenario['name']];
    if (baselineScenario == null) {
      buffer.writeln(
        '| ${scenario['name']} '
        '| ${actualRate.toStringAsFixed(1)} '
        '| - '
        '| ${frame['p95']!.toStringAsFixed(2)} '
        '| - '
        '| ${(rss['peak']! / 1024 / 1024).toStringAsFixed(1)} |',
      );
      continue;
    }
    final baselineRate = baselineScenario['actualPacketsPerSecond']! as double;
    final baselineFrame =
        baselineScenario['frameTotalMs']! as Map<String, dynamic>;
    final rateChange = (actualRate / baselineRate - 1) * 100;
    final p95Change =
        (frame['p95']! / (baselineFrame['p95']! as num).toDouble() - 1) * 100;
    buffer.writeln(
      '| ${scenario['name']} '
      '| ${actualRate.toStringAsFixed(1)} '
      '| ${_formatPercent(rateChange)} '
      '| ${frame['p95']!.toStringAsFixed(2)} '
      '| ${_formatPercent(p95Change)} '
      '| ${(rss['peak']! / 1024 / 1024).toStringAsFixed(1)} |',
    );
  }
  await File(
    '${directory.path}/$_label.md',
  ).writeAsString(buffer.toString(), flush: true);
}

String _formatPercent(double value) {
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(1)}%';
}

Map<String, Map<String, Object?>> _indexScenarios(Map<String, Object?> report) {
  final result = <String, Map<String, Object?>>{};
  for (final rawScenario in report['scenarios']! as List<dynamic>) {
    final scenario = Map<String, Object?>.from(rawScenario as Map);
    result[scenario['name']! as String] = scenario;
  }
  return result;
}

// quick 场景控制在几十秒内，适合每次性能改动后手动运行：
// - 10K/1CH：普通高频边界。
// - 64K/4CH：接近常见多通道高频使用。
// - 100K/16CH：当前随机源上限和最宽通道数。
// - 100K/16CH + 数学通道 + 跟随：绘图压力最大的常用组合。
const _quickScenarios = <_BenchmarkScenario>[
  _BenchmarkScenario('10K-1CH', 10000, 1, Duration(seconds: 5)),
  _BenchmarkScenario('64K-4CH', 64000, 4, Duration(seconds: 5)),
  _BenchmarkScenario('100K-16CH', 100000, 16, Duration(seconds: 5)),
  _BenchmarkScenario(
    '100K-16CH-MATH-FOLLOW',
    100000,
    16,
    Duration(seconds: 10),
    mathChannelEnabled: true,
    followEnabled: true,
  ),
];

// soak 场景用于长时间观察内存和卡顿风险，不建议放进 CI。
// 这里仍然沿用随机源，不依赖外部串口设备，方便在同一机器上复测。
const _soakScenarios = <_BenchmarkScenario>[
  _BenchmarkScenario('100K-16CH-400K', 100000, 16, Duration(seconds: 4)),
  _BenchmarkScenario(
    '100K-16CH-1M',
    100000,
    16,
    Duration(seconds: 10),
    mathChannelEnabled: true,
    followEnabled: true,
  ),
  _BenchmarkScenario(
    '100K-16CH-SOAK',
    100000,
    16,
    Duration(minutes: 5),
    mathChannelEnabled: true,
    followEnabled: true,
  ),
];

/// 单个性能场景的参数。
///
/// [frequencyHz] 表示随机源目标包速率，不是通道值数量；
/// [channelCount] 决定每包 FireWater 数据包含多少个通道值；
/// [mathChannelEnabled] 和 [followEnabled] 用于叠加数学通道和跟随刷新压力。
class _BenchmarkScenario {
  final String name;
  final int frequencyHz;
  final int channelCount;
  final Duration duration;
  final bool mathChannelEnabled;
  final bool followEnabled;

  const _BenchmarkScenario(
    this.name,
    this.frequencyHz,
    this.channelCount,
    this.duration, {
    this.mathChannelEnabled = false,
    this.followEnabled = false,
  });
}
