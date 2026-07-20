import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/multi_send_profile.dart';
import '../../viewmodels/multi_send_viewmodel.dart';
import 'hex_input_formatter.dart';

/// 数据收发页右侧的多条发送扩展面板。
///
/// 面板只负责配置与操作呈现；发送顺序、取消令牌和运行锁由
/// [MultiSendViewModel] 持有，运行期间必须禁止会改变执行序列的编辑操作。
class MultiSendPanel extends StatelessWidget {
  final VoidCallback onClose;

  const MultiSendPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Consumer<MultiSendViewModel>(
      builder: (context, vm, _) {
        if (vm.loading) return const Center(child: CircularProgressIndicator());
        final profile = vm.selectedProfile;
        // 批量发送开始后锁定配置选择、编辑、排序和单条发送，避免执行序列漂移。
        final locked = vm.isRunning;
        final manualSendEnabled = vm.canSendManually;
        return Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(
            children: [
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(
                    bottom: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.playlist_play, size: 20),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        '多条发送',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: '收起多条发送',
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: profile?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        hint: const Text('选择发送配置'),
                        items:
                            vm.profiles
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item.id,
                                    child: Text(
                                      item.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            locked ? null : (value) => vm.selectProfile(value),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: Tooltip(
                        message: '新建配置',
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkResponse(
                            onTap:
                                locked
                                    ? null
                                    : () => _editProfileName(context, vm),
                            containedInkWell: true,
                            highlightShape: BoxShape.circle,
                            radius: 16,
                            child: Icon(
                              Icons.add,
                              size: 20,
                              color:
                                  locked
                                      ? Theme.of(context).disabledColor
                                      : IconTheme.of(context).color,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: PopupMenuButton<String>(
                        tooltip: '配置操作',
                        enabled: !locked && profile != null,
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        splashRadius: 18,
                        onSelected:
                            (action) =>
                                _handleProfileAction(context, vm, action),
                        itemBuilder:
                            (_) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名配置'),
                              ),
                              PopupMenuItem(
                                value: 'import',
                                child: Text('导入配置'),
                              ),
                              PopupMenuItem(
                                value: 'export',
                                child: Text('导出配置'),
                              ),
                              PopupMenuDivider(),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('删除配置'),
                              ),
                            ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child:
                    profile == null
                        ? _EmptyProfile(
                          onCreate:
                              locked
                                  ? null
                                  : () => _editProfileName(context, vm),
                        )
                        : profile.entries.isEmpty
                        ? _EmptyEntries(
                          onAdd: locked ? null : () => _editEntry(context, vm),
                        )
                        : ReorderableListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          buildDefaultDragHandles: false,
                          itemCount: profile.entries.length,
                          onReorderItem: locked ? (_, _) {} : vm.reorderEntries,
                          itemBuilder: (context, index) {
                            final entry = profile.entries[index];
                            return _EntryRow(
                              key: ValueKey(entry.id),
                              entry: entry,
                              active: vm.currentEntryId == entry.id,
                              locked: locked,
                              sendEnabled: manualSendEnabled,
                              onToggle:
                                  (enabled) => vm.updateEntry(
                                    entry.copyWith(enabled: enabled),
                                  ),
                              onSend: () => vm.sendEntry(entry),
                              onEdit:
                                  () => _editEntry(context, vm, entry: entry),
                              onDelete: () => vm.deleteEntry(entry.id),
                              index: index,
                            );
                          },
                        ),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          profile == null || locked
                              ? null
                              : () => _editEntry(context, vm),
                      icon: const Icon(Icons.add),
                      label: const Text('添加条目'),
                    ),
                    const SizedBox(height: 8),
                    if (locked) ...[
                      Text(
                        '正在发送 ${vm.completedRounds > 0 ? '第${vm.completedRounds + 1}轮' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton.icon(
                        onPressed: vm.stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('停止发送'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: vm.canRun ? vm.runOnce : null,
                              icon: const Icon(Icons.skip_next),
                              label: const Text('执行一轮'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: vm.canRun ? vm.runLoop : null,
                              icon: const Icon(Icons.repeat),
                              label: const Text('持续循环'),
                            ),
                          ),
                        ],
                      ),
                      if (profile != null && vm.enabledEntries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            '请先启用至少一个条目',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleProfileAction(
    BuildContext context,
    MultiSendViewModel vm,
    String action,
  ) async {
    switch (action) {
      case 'rename':
        await _editProfileName(context, vm, rename: true);
      case 'import':
        final result = await file_picker.FilePicker.pickFiles(
          type: file_picker.FileType.custom,
          allowedExtensions: ['json'],
        );
        final path = result?.files.single.path;
        if (path != null) await vm.importProfile(path);
      case 'export':
        final profile = vm.selectedProfile;
        if (profile == null) return;
        final path = await file_picker.FilePicker.saveFile(
          dialogTitle: '导出多条发送配置',
          fileName: '${profile.name}.json',
          type: file_picker.FileType.custom,
          allowedExtensions: ['json'],
        );
        if (path != null) {
          await vm.exportSelectedProfile(
            path.endsWith('.json') ? path : '$path.json',
          );
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('删除配置'),
                content: Text('确定删除“${vm.selectedProfile?.name ?? ''}”吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
        );
        if (confirmed == true) await vm.deleteSelectedProfile();
    }
  }

  Future<void> _editProfileName(
    BuildContext context,
    MultiSendViewModel vm, {
    bool rename = false,
  }) async {
    final controller = TextEditingController(
      text: rename ? vm.selectedProfile?.name : '',
    );
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(rename ? '重命名配置' : '新建发送配置'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '配置名称',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('确定'),
              ),
            ],
          ),
    );
    if (name == null) return;
    if (rename) {
      await vm.renameProfile(name);
    } else {
      await vm.createProfile(name);
    }
  }

  Future<void> _editEntry(
    BuildContext context,
    MultiSendViewModel vm, {
    MultiSendEntry? entry,
  }) async {
    final result = await showDialog<MultiSendEntry>(
      context: context,
      builder:
          (_) => _EntryEditor(
            entry: entry,
            nextIndex: vm.selectedProfile?.entries.length ?? 0,
          ),
    );
    if (result == null) return;
    if (entry == null) {
      await vm.addEntry(result);
    } else {
      await vm.updateEntry(result);
    }
  }
}

/// 单个发送条目的紧凑行；拖动排序和操作按钮共享 ViewModel 的运行锁。
class _EntryRow extends StatelessWidget {
  final MultiSendEntry entry;
  final bool active;
  final bool locked;
  final bool sendEnabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSend;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final int index;

  const _EntryRow({
    super.key,
    required this.entry,
    required this.active,
    required this.locked,
    required this.sendEnabled,
    required this.onToggle,
    required this.onSend,
    required this.onEdit,
    required this.onDelete,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        active
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            enabled: !locked,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_indicator, size: 18),
            ),
          ),
          Checkbox(
            value: entry.enabled,
            onChanged: locked ? null : (value) => onToggle(value ?? false),
          ),
          Expanded(
            child: InkWell(
              onTap: locked ? null : onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (entry.isHex)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Text(
                              'HEX',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.deepOrange,
                              ),
                            ),
                          ),
                        if (!entry.isHex && entry.textLineEnding.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              entry.textLineEnding
                                  .replaceAll('\r', r'\r')
                                  .replaceAll('\n', r'\n'),
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '${entry.intervalMs}ms',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.content.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 32,
            height: 32,
            child: Tooltip(
              message: '发送此条',
              child: Material(
                type: MaterialType.transparency,
                child: InkResponse(
                  onTap: sendEnabled ? onSend : null,
                  containedInkWell: true,
                  highlightShape: BoxShape.circle,
                  radius: 16,
                  child: Icon(
                    Icons.send,
                    size: 18,
                    color:
                        sendEnabled
                            ? IconTheme.of(context).color
                            : Theme.of(context).disabledColor,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 32,
            height: 32,
            child: PopupMenuButton<String>(
              tooltip: '更多操作',
              enabled: !locked,
              padding: EdgeInsets.zero,
              iconSize: 20,
              splashRadius: 18,
              onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 发送条目编辑器，同时负责文本/HEX 模式切换时的输入归一化。
class _EntryEditor extends StatefulWidget {
  final MultiSendEntry? entry;
  final int nextIndex;
  const _EntryEditor({this.entry, required this.nextIndex});
  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry?.name ?? '条目${widget.nextIndex + 1}',
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.entry?.content ?? '',
  );
  late final TextEditingController _interval = TextEditingController(
    text: '${widget.entry?.intervalMs ?? 1000}',
  );
  late bool _hex = widget.entry?.isHex ?? false;
  late String _textLineEnding = widget.entry?.textLineEnding ?? '';
  late bool _enabled = widget.entry?.enabled ?? true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    _interval.dispose();
    super.dispose();
  }

  void _submit() {
    final interval = int.tryParse(_interval.text);
    final name = _name.text.trim();
    final content = _content.text;
    final hex = content.replaceAll(RegExp(r'\s+'), '');
    if (name.isEmpty || content.isEmpty) {
      setState(() => _error = '名称和内容不能为空');
      return;
    }
    if (interval == null ||
        interval < MultiSendEntry.minIntervalMs ||
        interval > MultiSendEntry.maxIntervalMs) {
      setState(() => _error = '间隔请输入 1 ~ 3600000 ms');
      return;
    }
    if (_hex &&
        (hex.isEmpty ||
            hex.length.isOdd ||
            !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex))) {
      setState(() => _error = '请输入偶数字节的 HEX 数据');
      return;
    }
    Navigator.pop(
      context,
      MultiSendEntry(
        id:
            widget.entry?.id ??
            'entry_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        content: content,
        enabled: _enabled,
        isHex: _hex,
        textLineEnding: _hex ? '' : _textLineEnding,
        intervalMs: interval,
      ),
    );
  }

  void _setHexMode(bool value) {
    // 从文本切到 HEX 时清空旧内容，不能把任意文本误解释为字节序列。
    final wasHex = _hex;
    setState(() => _hex = value);
    if (!wasHex && value) {
      _content.clear();
    }
  }

  void _formatHexContent(String value) {
    // 使用与普通发送区相同的格式化规则，输入始终按两位字节分组。
    final newText = formatHexByteGroups(value);
    if (newText != value) {
      _content.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.entry == null ? '添加发送条目' : '编辑发送条目'),
    content: SizedBox(
      width: 430,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称',
              border: OutlineInputBorder(),
            ),
          ),
          if (!_hex) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _textLineEnding,
              decoration: const InputDecoration(
                labelText: '文本行尾',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: '', child: Text('不追加')),
                DropdownMenuItem(value: '\r', child: Text(r'\r')),
                DropdownMenuItem(value: '\n', child: Text(r'\n')),
                DropdownMenuItem(value: '\r\n', child: Text(r'\r\n')),
              ],
              onChanged:
                  (value) => setState(() => _textLineEnding = value ?? ''),
            ),
          ],
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('文本')),
              ButtonSegment(value: true, label: Text('HEX')),
            ],
            selected: {_hex},
            onSelectionChanged: (value) => _setHexMode(value.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            minLines: 3,
            maxLines: 7,
            decoration: InputDecoration(
              labelText: _hex ? 'HEX 内容' : '发送内容',
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            inputFormatters: _hex ? const [HexInputFormatter()] : null,
            onChanged: _hex ? _formatHexContent : null,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '发送后间隔 (ms)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('循环启用'),
                  Switch(
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                  ),
                ],
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      ElevatedButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}

class _EmptyProfile extends StatelessWidget {
  final VoidCallback? onCreate;
  const _EmptyProfile({this.onCreate});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.folder_open, size: 36, color: Colors.grey),
        const SizedBox(height: 8),
        const Text('还没有发送配置'),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('新建配置'),
        ),
      ],
    ),
  );
}

class _EmptyEntries extends StatelessWidget {
  final VoidCallback? onAdd;
  const _EmptyEntries({this.onAdd});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.playlist_add, size: 36, color: Colors.grey),
        const SizedBox(height: 8),
        const Text('此配置还没有发送条目'),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('添加条目'),
        ),
      ],
    ),
  );
}
