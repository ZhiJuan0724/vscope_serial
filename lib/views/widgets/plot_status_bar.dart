import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/plot_viewmodel.dart';

/// 绘图页面状态栏
///
/// 显示视口范围、数据点数、接收速率、运行状态、用户提示及光标信息。
/// 从 PlotViewModel 获取所有数据，独立于页面布局。
class PlotStatusBar extends StatelessWidget {
  const PlotStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlotViewModel>(
      builder: (context, vm, child) {
        return Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              // 左侧：视口范围、数据点数、速率、运行状态
              Text(
                vm.statusText,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
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
    final points = vm.dataPoints;
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

      for (int i = 0; i < nearest.channelCount && i < vm.channels.length; i++) {
        if (!vm.channels[i].visible) continue;
        final value = nearest.values[i];
        buffer.write('Ch$i: ${_formatExactNumber(value)} ');
      }
    }

    return Text(
      buffer.toString(),
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    );
  }

  String _formatExactNumber(double value) {
    if (!value.isFinite) return value.toString();
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }
}
