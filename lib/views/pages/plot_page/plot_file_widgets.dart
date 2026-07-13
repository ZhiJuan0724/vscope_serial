part of '../plot_page.dart';

/// 绘图页面的文件导入导出辅助 UI，包括格式枚举和文件进度弹窗。
enum _PlotFileFormat { csv, bin, legacyDat }

class _PlotExportOptions {
  final int startIndex;
  final int endIndex;
  final List<int> channelIndices;

  const _PlotExportOptions({
    required this.startIndex,
    required this.endIndex,
    required this.channelIndices,
  });

  int get count => endIndex - startIndex + 1;
}

class _PlotFileProgressDialog extends StatelessWidget {
  final String title;
  final ValueListenable<PlotImportProgress> progressListenable;
  final PlotExportCancelToken? cancelToken;

  const _PlotFileProgressDialog({
    required this.title,
    required this.progressListenable,
    this.cancelToken,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: ValueListenableBuilder<PlotImportProgress>(
            valueListenable: progressListenable,
            builder: (context, progress, _) {
              final fraction = progress.fraction;
              final percent =
                  fraction == null ? null : (fraction * 100).clamp(0, 100);
              final countText =
                  progress.total <= 0
                      ? ''
                      : '${progress.current}/${progress.total}';
              final speedText =
                  progress.bytesPerSecond == null
                      ? null
                      : '${(progress.bytesPerSecond! / 1024 / 1024).toStringAsFixed(1)} MB/s';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: fraction),
                  const SizedBox(height: 12),
                  Text(
                    progress.stage,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (percent != null) '${percent.toStringAsFixed(1)}%',
                      if (countText.isNotEmpty) countText,
                      if (speedText != null) speedText,
                      if (progress.detail != null) progress.detail!,
                    ].join('  '),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions:
            cancelToken == null
                ? null
                : [
                  TextButton(
                    onPressed:
                        cancelToken!.isCancelled ? null : cancelToken!.cancel,
                    child: Text(cancelToken!.isCancelled ? '正在取消...' : '取消'),
                  ),
                ],
      ),
    );
  }
}

String _formatZobowAddress(int address, {bool compact = false}) {
  final value = address & 0xFFFFFFFF;
  final width = compact && (value & 0xFFFF0000) == 0 ? 4 : 8;
  return '0x${value.toRadixString(16).toUpperCase().padLeft(width, '0')}';
}
