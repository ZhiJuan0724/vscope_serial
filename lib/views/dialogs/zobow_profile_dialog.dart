import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/zobow_config_profile.dart';
import '../../viewmodels/plot_viewmodel.dart';

/// 众邦电控配置文件编辑弹窗
///
/// 表格形式编辑配置文件：
/// - 顶部：配置文件名称输入框
/// - 中部：名称列 + 地址列的可编辑表格（支持拖动排序）
/// - 底部：添加行 / 删除选中行 按钮
class ZobowProfileDialog extends StatefulWidget {
  final PlotViewModel vm;

  /// 为 null 时创建新配置，否则编辑现有配置
  final ZobowConfigProfile? profile;

  const ZobowProfileDialog({
    super.key,
    required this.vm,
    this.profile,
  });

  @override
  State<ZobowProfileDialog> createState() => _ZobowProfileDialogState();
}

class _ZobowProfileDialogState extends State<ZobowProfileDialog> {
  late final TextEditingController _nameController;
  late final List<_PresetRow> _rows;
  int? _selectedRowIndex;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.profile?.name ?? '新配置',
    );
    _rows = widget.profile?.presets.map((p) => _PresetRow(
      nameController: TextEditingController(text: p.name),
      addressController: TextEditingController(
        text: '0x${p.address.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      ),
    )).toList() ?? [];
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text(widget.profile == null ? '新建配置文件' : '编辑配置文件'),
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 配置文件名称
            Row(
              children: [
                const Text('名称:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 表头
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: const Row(
                children: [
                  SizedBox(width: 32, child: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                  SizedBox(width: 32),
                  Expanded(
                    flex: 2,
                    child: Text('名称', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text('地址 (hex)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            // 表格内容（支持拖动排序）
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, child) {
                      return Material(
                        elevation: 4,
                        color: Colors.transparent,
                        child: child,
                      );
                    },
                    child: child,
                  );
                },
                itemCount: _rows.length,
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final row = _rows.removeAt(oldIndex);
                    _rows.insert(newIndex, row);
                    _selectedRowIndex = null;
                  });
                },
                itemBuilder: (context, index) {
                  final isSelected = _selectedRowIndex == index;
                  return InkWell(
                    key: ValueKey('preset_$index'),
                    onTap: () => setState(() => _selectedRowIndex = index),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                            : null,
                        border: Border(
                          bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Text('${index + 1}', style: const TextStyle(fontSize: 12)),
                          ),
                          // 拖动手柄
                          SizedBox(
                            width: 32,
                            child: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _rows[index].nameController,
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _rows[index].addressController,
                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                border: InputBorder.none,
                                hintText: '0x0000',
                              ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-FxX]')),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            // 操作按钮
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _addRow,
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _selectedRowIndex != null ? _deleteSelectedRow : null,
                  icon: const Icon(Icons.delete, size: 14),
                  label: const Text('删除', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_rows.length} 个预设',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _saveProfile,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _addRow() {
    setState(() {
      _rows.add(_PresetRow(
        nameController: TextEditingController(text: '预设${_rows.length + 1}'),
        addressController: TextEditingController(text: '0x0001'),
      ));
      _selectedRowIndex = _rows.length - 1;
    });
  }

  void _deleteSelectedRow() {
    if (_selectedRowIndex == null) return;
    setState(() {
      _rows[_selectedRowIndex!].dispose();
      _rows.removeAt(_selectedRowIndex!);
      _selectedRowIndex = null;
    });
  }

  void _saveProfile() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final presets = <ZobowChannelPreset>[];
    for (final row in _rows) {
      final presetName = row.nameController.text.trim();
      final addrText = row.addressController.text.trim();
      final hex = addrText.replaceAll('0x', '').replaceAll('0X', '');
      final address = int.tryParse(hex, radix: 16) ?? 0;

      if (presetName.isNotEmpty) {
        presets.add(ZobowChannelPreset(
          name: presetName,
          address: address & 0xFFFF,
        ));
      }
    }

    if (widget.profile == null) {
      // 创建新配置
      widget.vm.createZobowProfile(name).then((profile) {
        if (profile != null) {
          profile.presets = presets;
          widget.vm.updateZobowProfile(profile).then((_) {
            widget.vm.selectZobowProfile(profile.id);
            if (mounted) Navigator.pop(context);
          });
        }
      });
    } else {
      // 更新现有配置
      final updated = widget.profile!.copyWith(
        name: name,
        presets: presets,
      );
      widget.vm.updateZobowProfile(updated).then((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }
}

/// 表格行数据包装
class _PresetRow {
  final TextEditingController nameController;
  final TextEditingController addressController;

  _PresetRow({
    required this.nameController,
    required this.addressController,
  });

  void dispose() {
    nameController.dispose();
    addressController.dispose();
  }
}
