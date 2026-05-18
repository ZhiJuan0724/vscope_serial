import 'package:flutter/material.dart';

/// 协议页面 - Phase 3 实现
class ProtocolPage extends StatelessWidget {
  const ProtocolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.settings_ethernet,
            size: 64,
            color: Colors.grey,
          ),
          SizedBox(height: 16),
          Text(
            '协议解析',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Phase 3 实现',
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
