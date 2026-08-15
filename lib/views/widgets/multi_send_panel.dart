import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/multi_send_profile.dart';
import '../../viewmodels/multi_send_viewmodel.dart';
import 'common_widgets.dart';
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
                    Expanded(
                      child: Text(
                        AppStrings.multiSend.multiSend,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: AppStrings.multiSend.collapseMultiSend,
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
                      child: AppDropdown<String>(
                        value: profile?.id,
                        hint: AppStrings.multiSend.selectSendProfile,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
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
                        message: AppStrings.multiSend.createProfile,
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
                        tooltip: AppStrings.multiSend.profileActions,
                        enabled: !locked && profile != null,
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        splashRadius: 18,
                        onSelected:
                            (action) =>
                                _handleProfileAction(context, vm, action),
                        itemBuilder:
                            (_) => [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text(AppStrings.multiSend.renameProfile),
                              ),
                              PopupMenuItem(
                                value: 'import',
                                child: Text(AppStrings.multiSend.importProfile),
                              ),
                              PopupMenuItem(
                                value: 'export',
                                child: Text(AppStrings.multiSend.exportProfile),
                              ),
                              const PopupMenuDivider(),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(AppStrings.multiSend.deleteProfile),
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
                      label: Text(AppStrings.multiSend.addEntry),
                    ),
                    const SizedBox(height: 8),
                    if (locked) ...[
                      Text(
                        AppStrings.multiSend.sendingStatus(
                          round:
                              vm.completedRounds > 0
                                  ? vm.completedRounds + 1
                                  : null,
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton.icon(
                        onPressed: vm.stop,
                        icon: const Icon(Icons.stop),
                        label: Text(AppStrings.multiSend.stopSending),
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
                              label: Text(AppStrings.multiSend.runOnce),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: vm.canRun ? vm.runLoop : null,
                              icon: const Icon(Icons.repeat),
                              label: Text(AppStrings.multiSend.runLoop),
                            ),
                          ),
                        ],
                      ),
                      if (profile != null && vm.enabledEntries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            AppStrings.multiSend.enableAtLeastOneEntry,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
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
          dialogTitle: AppStrings.multiSend.exportProfileDialogTitle,
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
                title: Text(AppStrings.multiSend.deleteProfile),
                content: Text(
                  AppStrings.multiSend.deleteProfileMessage(
                    vm.selectedProfile?.name ?? '',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(AppStrings.common.cancel),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(AppStrings.common.delete),
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
            title: Text(
              rename
                  ? AppStrings.multiSend.renameProfile
                  : AppStrings.multiSend.createProfileDialogTitle,
            ),
            content: AppDialogTextField(
              controller: controller,
              autofocus: true,
              labelText: AppStrings.multiSend.profileName,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: Text(AppStrings.common.confirm),
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
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              AppStrings.multiSend.hexMode,
                              style: const TextStyle(
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
              message: AppStrings.multiSend.sendEntry,
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
              tooltip: AppStrings.multiSend.moreActions,
              enabled: !locked,
              padding: EdgeInsets.zero,
              iconSize: 20,
              splashRadius: 18,
              onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
              itemBuilder:
                  (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(AppStrings.multiSend.edit),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(AppStrings.common.delete),
                    ),
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
    text:
        widget.entry?.name ??
        AppStrings.multiSend.defaultEntryName(widget.nextIndex + 1),
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
      setState(() => _error = AppStrings.multiSend.nameAndContentRequired);
      return;
    }
    if (interval == null ||
        interval < MultiSendEntry.minIntervalMs ||
        interval > MultiSendEntry.maxIntervalMs) {
      setState(
        () =>
            _error = AppStrings.multiSend.intervalError(
              min: MultiSendEntry.minIntervalMs,
              max: MultiSendEntry.maxIntervalMs,
            ),
      );
      return;
    }
    if (_hex &&
        (hex.isEmpty ||
            hex.length.isOdd ||
            !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex))) {
      setState(() => _error = AppStrings.multiSend.invalidHexData);
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
    title: Text(
      widget.entry == null
          ? AppStrings.multiSend.addEntryTitle
          : AppStrings.multiSend.editEntryTitle,
    ),
    content: SizedBox(
      width: 430,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppDialogTextField(
            controller: _name,
            labelText: AppStrings.multiSend.name,
          ),
          if (!_hex) ...[
            const SizedBox(height: 12),
            AppDialogDropdown<String>(
              value: _textLineEnding,
              hint: AppStrings.multiSend.textLineEnding,
              labelText: AppStrings.multiSend.textLineEnding,
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(AppStrings.multiSend.noAppend),
                ),
                const DropdownMenuItem(value: '\r', child: Text(r'\r')),
                const DropdownMenuItem(value: '\n', child: Text(r'\n')),
                const DropdownMenuItem(value: '\r\n', child: Text(r'\r\n')),
              ],
              onChanged:
                  (value) => setState(() => _textLineEnding = value ?? ''),
            ),
          ],
          const SizedBox(height: 12),
          AppSegmentedSelector<bool>(
            value: _hex,
            items: {
              false: Text(AppStrings.multiSend.textMode),
              true: Text(AppStrings.multiSend.hexMode),
            },
            onChanged: _setHexMode,
          ),
          const SizedBox(height: 12),
          AppDialogTextField(
            controller: _content,
            minLines: 3,
            maxLines: 7,
            labelText:
                _hex
                    ? AppStrings.multiSend.hexContent
                    : AppStrings.multiSend.sendContent,
            inputFormatters: _hex ? const [HexInputFormatter()] : null,
            onChanged: _hex ? _formatHexContent : null,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppDialogTextField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  labelText: AppStrings.multiSend.sendIntervalLabel,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(AppStrings.multiSend.loopEnabled),
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
        child: Text(AppStrings.common.cancel),
      ),
      ElevatedButton(onPressed: _submit, child: Text(AppStrings.common.save)),
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
        Text(AppStrings.multiSend.noProfile),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: Text(AppStrings.multiSend.createProfile),
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
        Text(AppStrings.multiSend.noEntries),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text(AppStrings.multiSend.addEntry),
        ),
      ],
    ),
  );
}
