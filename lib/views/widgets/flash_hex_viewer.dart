import 'package:flutter/material.dart';

import '../../data/models/flash_data_document.dart';
import 'common_widgets.dart';

/// Flash页面右侧的多文档HEX查看器。
class FlashHexViewer extends StatelessWidget {
  const FlashHexViewer({
    super.key,
    required this.documents,
    required this.selectedId,
    required this.bytesPerRow,
    required this.groupBits,
    required this.autoExpandRows,
    required this.onSelect,
    required this.onClose,
    required this.onSettings,
    required this.onSave,
  });

  final List<FlashDataDocument> documents;
  final String? selectedId;
  final int bytesPerRow;
  final int groupBits;
  final bool autoExpandRows;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onSettings;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final expandThreshold = switch (groupBits) {
        32 => 680.0,
        16 => 720.0,
        _ => 840.0,
      };
      final effectiveBytesPerRow =
          autoExpandRows &&
                  bytesPerRow < 32 &&
                  constraints.maxWidth >= expandThreshold
              ? 32
              : bytesPerRow;
      final selected = documents.cast<FlashDataDocument?>().firstWhere(
        (item) => item?.id == selectedId,
        orElse: () => documents.firstOrNull,
      );
      return Column(
        children: [
          SizedBox(
            height: 38,
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 14),
                  child: Text('HEX显示'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    scrollDirection: Axis.horizontal,
                    itemCount: documents.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 3),
                    itemBuilder: (context, index) {
                      final document = documents[index];
                      final active = document.id == selected?.id;
                      return Tooltip(
                        message: document.name,
                        child: Material(
                          color:
                              active
                                  ? Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer
                                  : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => onSelect(document.id),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 190),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      document.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '关闭',
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints.tightFor(
                                      width: 28,
                                      height: 28,
                                    ),
                                    onPressed: () => onClose(document.id),
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                ToolbarIconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'HEX显示设置',
                  onPressed: onSettings,
                ),
                ToolbarIconButton(
                  icon: const Icon(Icons.file_upload_outlined),
                  tooltip: '导出当前数据为BIN或HEX',
                  onPressed: selected == null ? null : onSave,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child:
                selected == null
                    ? const Center(child: Text('请从工具栏打开文件，或从芯片读取数据'))
                    : _HexDataTable(
                      document: selected,
                      bytesPerRow: effectiveBytesPerRow,
                      groupBits: groupBits,
                    ),
          ),
        ],
      );
    },
  );
}

class _HexDataTable extends StatelessWidget {
  const _HexDataTable({
    required this.document,
    required this.bytesPerRow,
    required this.groupBits,
  });

  final FlashDataDocument document;
  final int bytesPerRow;
  final int groupBits;

  @override
  Widget build(BuildContext context) {
    final ranges = _buildRanges(document, bytesPerRow);
    final rowCount = ranges.fold<int>(0, (sum, range) => sum + range.rowCount);
    return ListView.builder(
      itemExtent: 24,
      itemCount: rowCount,
      itemBuilder: (context, index) {
        var localIndex = index;
        late _DisplayRange range;
        for (final candidate in ranges) {
          if (localIndex < candidate.rowCount) {
            range = candidate;
            break;
          }
          localIndex -= candidate.rowCount;
        }
        final address = range.start + localIndex * bytesPerRow;
        final groupBytes = groupBits ~/ 8;
        final values = <String>[];
        for (var offset = 0; offset < bytesPerRow; offset += groupBytes) {
          final bytes = [
            for (var index = 0; index < groupBytes; index++)
              _byteAt(document, address + offset + index),
          ];
          values.add(
            bytes.any((value) => value == null)
                ? List.filled(groupBytes * 2, '-').join()
                : bytes
                    .map(
                      (value) => value!
                          .toRadixString(16)
                          .toUpperCase()
                          .padLeft(2, '0'),
                    )
                    .join(),
          );
        }
        return ColoredBox(
          color:
              index.isEven
                  ? Theme.of(context).colorScheme.surface
                  : Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: SelectableText(
                    '0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    values.join(' '),
                    maxLines: 1,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DisplayRange {
  const _DisplayRange(this.start, this.end, this.rowCount);
  final int start;
  final int end;
  final int rowCount;
}

List<_DisplayRange> _buildRanges(FlashDataDocument document, int width) {
  final ranges = <_DisplayRange>[];
  for (final segment in document.segments) {
    final start = segment.address - segment.address % width;
    final rawEnd = segment.endAddress;
    final end = ((rawEnd + width - 1) ~/ width) * width;
    if (ranges.isNotEmpty && start - ranges.last.end <= 4096) {
      final previous = ranges.removeLast();
      ranges.add(
        _DisplayRange(previous.start, end, (end - previous.start) ~/ width),
      );
    } else {
      // 对很大的稀疏空洞只保留一行“--”作为断层提示，避免ELF的Flash与RAM
      // 地址跨度被展开成数百万空行。
      if (ranges.isNotEmpty && start > ranges.last.end) {
        ranges.add(_DisplayRange(ranges.last.end, ranges.last.end + width, 1));
      }
      ranges.add(_DisplayRange(start, end, (end - start) ~/ width));
    }
  }
  return ranges;
}

int? _byteAt(FlashDataDocument document, int address) {
  for (final segment in document.segments) {
    if (address < segment.address) return null;
    if (address < segment.endAddress) {
      return segment.data[address - segment.address];
    }
  }
  return null;
}
