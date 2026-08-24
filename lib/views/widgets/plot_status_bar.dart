import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/plot_viewmodel.dart';
import 'common_widgets.dart';

/// 绘图页面状态栏
///
/// 显示视口范围、数据点数、接收速率、运行状态及用户提示。
/// 从 PlotViewModel 获取所有数据，独立于页面布局。
class PlotStatusBar extends StatelessWidget {
  const PlotStatusBar({this.frameRate, super.key});

  final ValueListenable<double?>? frameRate;

  @override
  Widget build(BuildContext context) {
    return Selector<PlotViewModel, String>(
      selector: (_, vm) => vm.statusText,
      builder: (context, statusText, child) {
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
              _PlotFpsMonitor(frameRate: frameRate),
              const SizedBox(width: 8),
              // 左侧：视口范围、数据点数、速率、运行状态
              Expanded(
                child: Text(
                  statusText,
                  key: const ValueKey('plot-status-text'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kPageStatusBarTextStyle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 绘图状态栏中的实际渲染帧率监控。
///
/// 只显示绘图数据层上报的实际完成帧，约每半秒更新一次。
/// 该组件独立 setState，因此帧率文本刷新不会触发主图或状态栏数据选择器重建。
class _PlotFpsMonitor extends StatelessWidget {
  const _PlotFpsMonitor({this.frameRate});

  final ValueListenable<double?>? frameRate;

  @override
  Widget build(BuildContext context) {
    final listenable = frameRate;
    if (listenable == null) return _buildValue(null);
    return ValueListenableBuilder<double?>(
      valueListenable: listenable,
      builder: (_, fps, _) => _buildValue(fps),
    );
  }

  Widget _buildValue(double? fps) => SizedBox(
    width: 48,
    child: Text(
      'FPS: ${fps?.round().toString() ?? '--'}',
      maxLines: 1,
      style: kPageStatusBarTextStyle,
    ),
  );
}
