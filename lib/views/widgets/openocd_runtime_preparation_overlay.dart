import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/bundled_openocd_runtime.dart';

/// 内置 OpenOCD 首次解压时覆盖整个应用，明确告知用户当前正在准备运行文件。
class OpenOcdRuntimePreparationOverlay extends StatelessWidget {
  const OpenOcdRuntimePreparationOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BundledOpenOcdRuntime>().state;
    if (!state.preparing) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Color(0x59000000)),
          Center(
            child: Dialog(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '正在准备内置 OpenOCD',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        state.message,
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 18),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 10),
                      Text(
                        '运行文件将解压到程序目录，完成后会自动继续。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
