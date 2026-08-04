import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/models/modbus_models.dart';
import '../../services/modbus_client_service.dart';
import '../../services/modbus_value_codec.dart';

typedef ModbusRowStateLookup = ModbusRowState Function(ModbusRegisterRow row);
typedef ModbusRowContextMenu =
    void Function(ModbusRegisterRow row, Offset globalPosition);
typedef ModbusBlankContextMenu = void Function(Offset globalPosition);

enum ModbusRowMenuAction { quickSend, configure, toggleRadix, delete }

class ModbusPaintedMenuItem<T> {
  const ModbusPaintedMenuItem(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final T value;
}

VoidCallback? _closeActiveModbusPaintedMenu;

Future<T?> showModbusPaintedMenu<T>({
  required BuildContext context,
  required Offset position,
  required String title,
  required List<ModbusPaintedMenuItem<T>> items,
}) async {
  _closeActiveModbusPaintedMenu?.call();
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  final completer = Completer<T?>();
  final size = MediaQuery.sizeOf(context);
  const width = 230.0;
  final height = 34.0 + items.length * 40.0;
  final left = position.dx.clamp(8.0, size.width - width - 8).toDouble();
  final top = position.dy.clamp(8.0, size.height - height - 8).toDouble();
  late OverlayEntry entry;
  late void Function([T? value]) close;
  close = ([T? value]) {
    if (!completer.isCompleted) completer.complete(value);
    if (_closeActiveModbusPaintedMenu != null) {
      _closeActiveModbusPaintedMenu = null;
    }
    entry.remove();
    entry.dispose();
  };
  _closeActiveModbusPaintedMenu = () => close();

  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  entry = OverlayEntry(
    builder:
        (overlayContext) => themes.wrap(
          Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: close,
                ),
              ),
              Positioned(
                left: left,
                top: top,
                width: width,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(6),
                  clipBehavior: Clip.antiAlias,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                        for (final item in items)
                          InkWell(
                            onTap: () => close(item.value),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Icon(item.icon, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(item.label)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
  );
  overlay.insert(entry);
  return completer.future;
}

Future<ModbusRowMenuAction?> showModbusRowContextMenu({
  required BuildContext context,
  required ModbusRegisterPage page,
  required ModbusRegisterRow row,
  required Offset position,
}) => showMenu<ModbusRowMenuAction>(
  context: context,
  position: RelativeRect.fromLTRB(
    position.dx,
    position.dy,
    position.dx,
    position.dy,
  ),
  items: [
    if (page.area.isWritable)
      const PopupMenuItem(
        value: ModbusRowMenuAction.quickSend,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.send_outlined, size: 18),
          title: Text('快速发送'),
        ),
      ),
    const PopupMenuItem(
      value: ModbusRowMenuAction.configure,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.settings_outlined, size: 18),
        title: Text('配置寄存器'),
      ),
    ),
    PopupMenuItem(
      value: ModbusRowMenuAction.toggleRadix,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.numbers, size: 18),
        title: Text(
          row.displayRadix == ModbusDisplayRadix.decimal
              ? '切换为十六进制显示'
              : '切换为十进制显示',
        ),
      ),
    ),
    const PopupMenuItem(
      value: ModbusRowMenuAction.delete,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.delete_outline, size: 18),
        title: Text('删除寄存器'),
      ),
    ),
  ],
);

/// 主页面与独立窗口共用的寄存器网格。
class ModbusRegisterGrid extends StatefulWidget {
  const ModbusRegisterGrid({
    super.key,
    required this.page,
    required this.layoutMode,
    required this.rowState,
    required this.onRowContextMenu,
    required this.onBlankContextMenu,
  });

  final ModbusRegisterPage page;
  final ModbusRegisterLayoutMode layoutMode;
  final ModbusRowStateLookup rowState;
  final ModbusRowContextMenu onRowContextMenu;
  final ModbusBlankContextMenu onBlankContextMenu;

  @override
  State<ModbusRegisterGrid> createState() => _ModbusRegisterGridState();
}

class _ModbusRegisterGridState extends State<ModbusRegisterGrid> {
  final ScrollController _scrollController = ScrollController();
  bool _rowMenuHandled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ModbusRegisterGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.key != widget.page.key ||
        oldWidget.layoutMode != widget.layoutMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(0);
      });
    }
  }

  void _handlePointerSignal(PointerSignalEvent event, bool columnMajor) {
    if (!columnMajor || event is! PointerScrollEvent) return;
    if (!_scrollController.hasClients) return;
    final delta =
        event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
    final position = _scrollController.position;
    _scrollController.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnMajor =
            widget.layoutMode == ModbusRegisterLayoutMode.columnMajor;
        return Listener(
          onPointerSignal: (event) => _handlePointerSignal(event, columnMajor),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (details) {
              // 手势竞技场会先把事件分发给子单元格，再传到此父级。
              // 延迟一个微任务，让单元格菜单可以抑制空白区域菜单。
              Future<void>.microtask(() {
                if (_rowMenuHandled) {
                  _rowMenuHandled = false;
                  return;
                }
                widget.onBlankContextMenu(details.globalPosition);
              });
            },
            child: GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              scrollDirection: columnMajor ? Axis.horizontal : Axis.vertical,
              gridDelegate: _FixedRegisterGridDelegate(
                crossAxisExtent: columnMajor ? 36 : 190,
                mainAxisExtent: columnMajor ? 210 : 36,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: widget.page.rows.length,
              itemBuilder: (context, index) {
                final row = widget.page.rows[index];
                return _ModbusRegisterCell(
                  row: row,
                  showVariableType: widget.page.showVariableType,
                  state: widget.rowState(row),
                  onContextMenu: (position) {
                    _rowMenuHandled = true;
                    widget.onRowContextMenu(row, position);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _FixedRegisterGridDelegate extends SliverGridDelegate {
  const _FixedRegisterGridDelegate({
    required this.crossAxisExtent,
    required this.mainAxisExtent,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
  });

  final double crossAxisExtent;
  final double mainAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final count = (constraints.crossAxisExtent /
            (crossAxisExtent + crossAxisSpacing))
        .floor()
        .clamp(1, 1000);
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: mainAxisExtent + mainAxisSpacing,
      crossAxisStride: crossAxisExtent + crossAxisSpacing,
      childMainAxisExtent: mainAxisExtent,
      childCrossAxisExtent: crossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(covariant _FixedRegisterGridDelegate oldDelegate) =>
      oldDelegate.crossAxisExtent != crossAxisExtent ||
      oldDelegate.mainAxisExtent != mainAxisExtent ||
      oldDelegate.crossAxisSpacing != crossAxisSpacing ||
      oldDelegate.mainAxisSpacing != mainAxisSpacing;
}

class _ModbusRegisterCell extends StatelessWidget {
  const _ModbusRegisterCell({
    required this.row,
    required this.showVariableType,
    required this.state,
    required this.onContextMenu,
  });

  final ModbusRegisterRow row;
  final bool showVariableType;
  final ModbusRowState state;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final formattedValue =
        state.value == null
            ? '—'
            : ModbusValueCodec.format(
              row.variableType,
              state.value!,
              radix: row.displayRadix,
              registers: state.rawRegisters,
            );
    final background =
        row.backgroundArgb == null
            ? Theme.of(context).colorScheme.surface
            : Color(row.backgroundArgb!);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) => onContextMenu(details.globalPosition),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text:
                          '${row.address}'
                          '${showVariableType ? '[${row.variableType.label}]' : ''}'
                          '${row.note.isNotEmpty ? '(${row.note})' : ''}: ',
                    ),
                    TextSpan(
                      text: state.error == null ? formattedValue : '失败',
                      style: TextStyle(
                        color:
                            state.error == null
                                ? null
                                : Theme.of(context).colorScheme.error,
                        fontFamily: state.error == null ? null : 'SarasaUiSC',
                        fontWeight:
                            state.error == null
                                ? FontWeight.w600
                                : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
              ),
            ),
            if (state.busy)
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            if (row.pollEnabled || row.sendEnabled) ...[
              const SizedBox(width: 4),
              Tooltip(
                message:
                    row.pollEnabled && row.sendEnabled
                        ? '开启轮询查询和定时发送'
                        : row.pollEnabled
                        ? '开启轮询查询'
                        : '开启定时发送',
                child: Icon(
                  row.pollEnabled && row.sendEnabled
                      ? Icons.swap_vert
                      : row.pollEnabled
                      ? Icons.south
                      : Icons.north,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
