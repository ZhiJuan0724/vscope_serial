import 'package:flutter/material.dart';

import '../../core/localization/app_strings.dart';

/// 协议页面 - Phase 3 实现
class ProtocolPage extends StatelessWidget {
  const ProtocolPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.settings_ethernet, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            AppStrings.nav.protocol,
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.nav.protocolComingSoon,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
