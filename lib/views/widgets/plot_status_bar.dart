import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/scheduler.dart';

import '../../core/utils/plot_value_formatter.dart';
import '../../viewmodels/plot_viewmodel.dart';
import 'common_widgets.dart';

/// 绘图页面状态栏
///
/// 显示视口范围、数据点数、接收速率、运行状态、用户提示及光标信息。
/// 从 PlotViewModel 获取所有数据，独立于页面布局。
class PlotStatusBar extends StatelessWidget {
  const PlotStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<
      PlotViewModel,
      ({String statusText, int overlayRevision, int channelConfigRevision})
    >(
      selector:
          (_, vm) => (
            statusText: vm.statusText,
            overlayRevision: vm.overlayRevision,
            channelConfigRevision: vm.channelConfigRevision,
          ),
      builder: (context, selection, child) {
        final vm = context.read<PlotViewModel>();
        return Container(
          height: kPageStatusBarHeight,
          padding: kPageStatusBarPadding,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              // 最左侧独立统计实际完成渲染的帧率，不显示目标刷新率。
              const _PlotFpsMonitor(),
              const SizedBox(width: 8),
              // 左侧：视口范围、数据点数、速率、运行状态
              Text(selection.statusText, style: kPageStatusBarTextStyle),
              const Spacer(),
              // 右侧：垂直光标信息
              if (vm.cursor != null && vm.vCursorEnabled) _buildCursorInfo(vm),
            ],
          ),
        );
      },
    );
  }

  /// 构建光标信息文本
  ///
  /// 显示当前 X 位置及最近数据点各通道的 Y 值。
  Widget _buildCursorInfo(PlotViewModel vm) {
    final cursor = vm.cursor!;
    final buffer = StringBuffer();
    buffer.write('X: ${cursor.x.toInt()} ');

    // 查找最近的数据点
    final points = vm.displayDataPoints;
    if (points.isNotEmpty) {
      final target = cursor.x.round();
      var left = 0;
      var right = points.length - 1;
      while (left < right) {
        final mid = (left + right) >> 1;
        if (points[mid].index < target) {
          left = mid + 1;
        } else {
          right = mid;
        }
      }
      var nearest = points[left];
      if (left > 0) {
        final previous = points[left - 1];
        if ((previous.index - cursor.x).abs() <
            (nearest.index - cursor.x).abs()) {
          nearest = previous;
        }
      }

      final channels = vm.displayChannels;
      for (int i = 0; i < nearest.channelCount && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        final value = nearest.values[i];
        final name =
            channels[i].alias.isNotEmpty
                ? channels[i].alias
                : 'Ch${channels[i].index}';
        buffer.write('$name: ${formatPlotValue(value)} ');
      }
    }

    return Text(buffer.toString(), style: kPageStatusBarTextStyle);
  }
}

/// 绘图状态栏中的实际渲染帧率监控。
///
/// 直接使用引擎上报的 FrameTiming 统计完成渲染的帧，约每半秒更新一次。
/// 该组件独立 setState，因此帧率文本刷新不会触发主图或状态栏数据选择器重建。
class _PlotFpsMonitor extends StatefulWidget {
  const _PlotFpsMonitor();

  @override
  State<_PlotFpsMonitor> createState() => _PlotFpsMonitorState();
}

class _PlotFpsMonitorState extends State<_PlotFpsMonitor> {
  /// 兼顾数值稳定性和状态栏更新开销的最短统计窗口。
  static const int _sampleWindowMicros = 500000;

  int? _windowStartMicros;
  int _frameCount = 0;
  double? _fps;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
    super.dispose();
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    double? latestFps;
    for (final timing in timings) {
      final timestamp = timing.timestampInMicroseconds(FramePhase.rasterFinish);
      _windowStartMicros ??= timestamp;
      _frameCount++;

      final elapsed = timestamp - _windowStartMicros!;
      if (elapsed < _sampleWindowMicros) continue;

      // 首帧作为时间窗口起点，因此有效帧间隔数量比帧数少一。
      latestFps = (_frameCount - 1) * Duration.microsecondsPerSecond / elapsed;
      _windowStartMicros = timestamp;
      _frameCount = 1;
    }

    if (!mounted || latestFps == null) return;
    setState(() => _fps = latestFps);
  }

  @override
  Widget build(BuildContext context) {
    final value = _fps?.round().toString() ?? '--';
    return SizedBox(
      width: 48,
      child: Text('FPS: $value', maxLines: 1, style: kPageStatusBarTextStyle),
    );
  }
}
