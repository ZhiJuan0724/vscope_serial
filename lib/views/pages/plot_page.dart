import 'package:flutter/material.dart';

/// 绘图页面 - Phase 2 实现
class PlotPage extends StatelessWidget {
  const PlotPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.show_chart,
            size: 64,
            color: Colors.grey,
          ),
          SizedBox(height: 16),
          Text(
            '绘图功能',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Phase 2 实现',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
