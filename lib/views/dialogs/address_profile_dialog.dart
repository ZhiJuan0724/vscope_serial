import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/app_strings.dart';
import '../../core/utils/file_name_sanitizer.dart';
import '../../data/models/address_config_profile.dart';
import '../../services/app_notifications.dart';
import '../../services/address_profile_csv_importer.dart';
import '../../services/zobow_c_profile_importer.dart';
import '../../viewmodels/plot_viewmodel.dart';
import '../widgets/common_widgets.dart';

/// 地址配置弹窗的协议差异策略。
///
/// UI 共享导入、编辑和预设流程，地址格式化与校验规则委托给具体协议实现。
abstract class _AddressProfileBehavior {
  const _AddressProfileBehavior();

  AddressProfileProtocolType get protocolType;
  bool get supportsCImport;
  String get defaultAddressText;
  String get addressHint;

  String formatAddress(AddressChannelPreset preset);
  String normalizeAddressText(String text);
  AddressChannelPreset? parsePreset(String name, String text);
  Future<AddressConfigProfile?> createProfile(PlotViewModel vm, String name);
  Future<void> updateProfile(PlotViewModel vm, AddressConfigProfile profile);
  Future<void> deleteProfile(PlotViewModel vm, String id);
  void selectProfile(PlotViewModel vm, String id);
}

/// Zobow 配置行为：地址按十六进制数值处理，可导入 C 定义。
class _ZobowProfileBehavior extends _AddressProfileBehavior {
  const _ZobowProfileBehavior();

  @override
  AddressProfileProtocolType get protocolType =>
      AddressProfileProtocolType.zobow;
  @override
  bool get supportsCImport => true;
  @override
  String get defaultAddressText => '0x00000001';
  @override
  String get addressHint => '0x00000000';

  @override
  String formatAddress(AddressChannelPreset preset) {
    final digits = (preset.address & 0xFFFFFFFF)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(8, '0');
    return '0x$digits';
  }

  @override
  String normalizeAddressText(String text) {
    final preset = parsePreset('', text);
    return preset == null ? text : formatAddress(preset);
  }

  @override
  AddressChannelPreset? parsePreset(String name, String text) {
    return AddressChannelPreset.tryParseAddress(
      name: name,
      text: text,
      protocolType: protocolType,
    );
  }

  @override
  Future<AddressConfigProfile?> createProfile(PlotViewModel vm, String name) =>
      vm.createZobowProfile(name);
  @override
  Future<void> updateProfile(PlotViewModel vm, AddressConfigProfile profile) =>
      vm.updateZobowProfile(profile);
  @override
  Future<void> deleteProfile(PlotViewModel vm, String id) =>
      vm.deleteZobowProfile(id);
  @override
  void selectProfile(PlotViewModel vm, String id) => vm.selectZobowProfile(id);
}

/// r 协议配置行为：保留用户输入的十进制或 `0x` 十六进制文本。
class _RProtocolProfileBehavior extends _AddressProfileBehavior {
  const _RProtocolProfileBehavior();

  @override
  AddressProfileProtocolType get protocolType =>
      AddressProfileProtocolType.rProtocol;
  @override
  bool get supportsCImport => false;
  @override
  String get defaultAddressText => '1';
  @override
  String get addressHint => '1 或 0x1';

  @override
  String formatAddress(AddressChannelPreset preset) => preset.formatAddress();

  @override
  String normalizeAddressText(String text) => text;

  @override
  AddressChannelPreset? parsePreset(String name, String text) {
    return AddressChannelPreset.tryParseAddress(
      name: name,
      text: text,
      protocolType: protocolType,
    );
  }

  @override
  Future<AddressConfigProfile?> createProfile(PlotViewModel vm, String name) =>
      vm.createRProfile(name);
  @override
  Future<void> updateProfile(PlotViewModel vm, AddressConfigProfile profile) =>
      vm.updateRProfile(profile);
  @override
  Future<void> deleteProfile(PlotViewModel vm, String id) =>
      vm.deleteRProfile(id);
  @override
  void selectProfile(PlotViewModel vm, String id) => vm.selectRProfile(id);
}

/// Zobow 通道地址预设管理窗口入口。
class ZobowProfileDialog extends StatelessWidget {
  final PlotViewModel vm;
  final AddressConfigProfile? profile;

  const ZobowProfileDialog({super.key, required this.vm, this.profile});

  @override
  Widget build(BuildContext context) {
    return _AddressProfileDialog(
      vm: vm,
      profile: profile,
      behavior: const _ZobowProfileBehavior(),
    );
  }
}

/// r 协议通道地址预设管理窗口入口。
class RProtocolProfileDialog extends StatelessWidget {
  final PlotViewModel vm;
  final AddressConfigProfile? profile;

  const RProtocolProfileDialog({super.key, required this.vm, this.profile});

  @override
  Widget build(BuildContext context) {
    return _AddressProfileDialog(
      vm: vm,
      profile: profile,
      behavior: const _RProtocolProfileBehavior(),
    );
  }
}

/// 地址配置的共同编辑界面；协议差异由 [_AddressProfileBehavior] 提供。
class _AddressProfileDialog extends StatefulWidget {
  final PlotViewModel vm;
  final AddressConfigProfile? profile;
  final _AddressProfileBehavior behavior;

  const _AddressProfileDialog({
    required this.vm,
    required this.profile,
    required this.behavior,
  });

  @override
  State<_AddressProfileDialog> createState() => _AddressProfileDialogState();
}

class _AddressProfileDialogState extends State<_AddressProfileDialog> {
  static const double _presetRowExtent = 36.0;

  late final TextEditingController _nameController;
  late final TextEditingController _searchController;
  late final ScrollController _presetListScrollController;
  late final List<_PresetRow> _rows;
  int? _selectedRowIndex;
  String _searchText = '';
  bool _ignoreCImportComments = false;
  AddressImportConflictPolicy _importConflictPolicy =
      AddressImportConflictPolicy.overwriteExisting;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.profile?.name ?? AppStrings.profile.defaultConfigName,
    );
    _searchController = TextEditingController();
    _presetListScrollController = ScrollController();
    _rows =
        widget.profile?.presets
            .map(
              (p) => _PresetRow(
                nameController: TextEditingController(text: p.name),
                addressController: TextEditingController(
                  text: widget.behavior.formatAddress(p),
                ),
              ),
            )
            .toList() ??
        [];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    _presetListScrollController.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text(
        widget.profile == null
            ? AppStrings.profile.createProfile
            : AppStrings.profile.editProfile,
      ),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 配置文件名称
            Row(
              children: [
                Text(
                  AppStrings.profile.nameLabel,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('address-profile-search'),
              controller: _searchController,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIconConstraints: const BoxConstraints.tightFor(
                  width: kFieldIconButtonExtent,
                  height: kFieldIconButtonExtent,
                ),
                suffixIcon:
                    _searchText.isEmpty
                        ? null
                        : AppFieldIconButton(
                          key: const ValueKey('address-profile-clear-search'),
                          tooltip: AppStrings.profile.clearSearch,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchText = '');
                          },
                        ),
                hintText: AppStrings.profile.searchNameOrAddress,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _searchText = value),
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
              child: Row(
                children: [
                  const SizedBox(
                    width: 32,
                    child: Text(
                      '#',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 32),
                  Expanded(
                    child: Text(
                      AppStrings.profile.nameColumn,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: Text(
                      AppStrings.profile.addressColumn,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 表格内容（支持拖动排序）
            Expanded(
              child:
                  _searchText.trim().isEmpty
                      ? _buildEditablePresetList()
                      : _buildFilteredPresetList(context),
            ),
            const SizedBox(height: 8),
            // 操作按钮
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _addRow,
                  icon: const Icon(Icons.add, size: 14),
                  label: Text(
                    AppStrings.profile.add,
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed:
                      _selectedRowIndex != null ? _deleteSelectedRow : null,
                  icon: const Icon(Icons.delete, size: 14),
                  label: Text(
                    AppStrings.common.delete,
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
                const Spacer(),
                Text(
                  AppStrings.profile.presetCount(_rows.length),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.profile != null) ...[
              TextButton.icon(
                onPressed: _confirmDeleteProfile,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(AppStrings.profile.deleteProfile),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _exportProfile,
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: Text(AppStrings.profile.exportProfile),
              ),
              const SizedBox(width: 8),
            ],
            TextButton.icon(
              onPressed: _showExternalImportDialog,
              icon: const Icon(Icons.file_upload_outlined, size: 16),
              label: Text(AppStrings.profile.importExternal),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.common.cancel),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _saveProfile,
              child: Text(AppStrings.common.save),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditablePresetList() {
    return ReorderableListView.builder(
      scrollController: _presetListScrollController,
      // 跳转逻辑依赖固定行高计算未构建条目的滚动偏移。显式约束行高后，
      // 搜索结果有多项时也能准确跳到原列表中的真实索引。
      itemExtent: _presetRowExtent,
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
        final row = _rows[index];
        final isSelected = _selectedRowIndex == index;
        return InkWell(
          key: row.rowKey,
          onTap: () => setState(() => _selectedRowIndex = index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: _rowDecoration(context, isSelected: isSelected),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: GestureDetector(
                    key: ValueKey('address-profile-row-sequence-$index'),
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () => _editRowSequence(index),
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(
                      Icons.drag_handle,
                      size: 16,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Expanded(
                  child: Tooltip(
                    message: row.nameController.text,
                    waitDuration: const Duration(milliseconds: 500),
                    child: TextField(
                      key: ValueKey('address-profile-row-name-$index'),
                      controller: row.nameController,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: Focus(
                    onFocusChange: (hasFocus) {
                      if (!hasFocus) _normalizeAddressText(row);
                    },
                    child: TextField(
                      key: ValueKey('address-profile-row-address-$index'),
                      controller: row.addressController,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'SarasaUiSC',
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        border: InputBorder.none,
                        hintText: widget.behavior.addressHint,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9a-fA-FxX]'),
                        ),
                      ],
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

  Widget _buildFilteredPresetList(BuildContext context) {
    final matches = _matchingRowIndexes();
    if (matches.isEmpty) {
      return Center(
        child: Text(
          AppStrings.profile.noSearchResult,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).disabledColor,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final rowIndex = matches[index];
        final row = _rows[rowIndex];
        final isSelected = _selectedRowIndex == rowIndex;
        return InkWell(
          onTap: () => _jumpToRow(rowIndex, clearSearch: true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: _rowDecoration(context, isSelected: isSelected),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () async {
                      _jumpToRow(rowIndex, clearSearch: true);
                      await _editRowSequence(rowIndex);
                    },
                    child: Text(
                      '${rowIndex + 1}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Text(
                    row.nameController.text.trim().isEmpty
                        ? AppStrings.profile.presetName(rowIndex + 1)
                        : row.nameController.text.trim(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: Text(
                    row.addressController.text.trim(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'SarasaUiSC',
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

  BoxDecoration _rowDecoration(
    BuildContext context, {
    required bool isSelected,
  }) {
    return BoxDecoration(
      color:
          isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : null,
      border: Border(
        bottom: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }

  List<int> _matchingRowIndexes() {
    final query = _searchText.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final result = <int>[];
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      final name = row.nameController.text.toLowerCase();
      final address = row.addressController.text.toLowerCase();
      if (name.contains(query) || address.contains(query)) {
        result.add(i);
      }
    }
    return result;
  }

  void _jumpToRow(int index, {bool clearSearch = false}) {
    if (index < 0 || index >= _rows.length) return;
    final rowKey = _rows[index].rowKey;
    setState(() {
      if (clearSearch) {
        _searchController.clear();
        _searchText = '';
      }
      _selectedRowIndex = index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = rowKey.currentContext;
      if (rowContext != null) {
        _ensureRowVisible(rowContext);
        return;
      }
      if (!_presetListScrollController.hasClients) return;
      final maxExtent = _presetListScrollController.position.maxScrollExtent;
      final target = (index * _presetRowExtent).clamp(0.0, maxExtent);
      _presetListScrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted) return;
            final visibleContext = rowKey.currentContext;
            if (visibleContext != null && visibleContext.mounted) {
              _ensureRowVisible(visibleContext, duration: Duration.zero);
            }
          });
    });
  }

  void _ensureRowVisible(
    BuildContext rowContext, {
    Duration duration = const Duration(milliseconds: 180),
  }) {
    Scrollable.ensureVisible(
      rowContext,
      duration: duration,
      curve: Curves.easeOutCubic,
      alignment: 0.2,
    );
  }

  void _normalizeAddressText(_PresetRow row) {
    final current = row.addressController.text.trim();
    final normalized = widget.behavior.normalizeAddressText(current);
    if (current == normalized) return;
    row.addressController.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }

  Future<void> _confirmDeleteProfile() async {
    final profile = widget.profile;
    if (profile == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.profile.deleteProfileTitle(profile.name)),
            content: Text(
              AppStrings.profile.deleteProfileMessage(profile.name),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: Text(AppStrings.common.delete),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    await widget.behavior.deleteProfile(widget.vm, profile.id);
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _showExternalImportDialog() async {
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (dialogContext, setDialogState) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: Text(AppStrings.profile.importExternal),
                  content: SizedBox(
                    width: 340,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.profile != null) ...[
                          Text(AppStrings.profile.importConflictHandling),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: AppSegmentedSelector<
                              AddressImportConflictPolicy
                            >(
                              value: _importConflictPolicy,
                              minItemWidth: 130,
                              items: {
                                AddressImportConflictPolicy
                                    .overwriteExisting: Text(
                                  AppStrings.profile.overwriteSameAddress,
                                ),
                                AddressImportConflictPolicy.keepBoth: Text(
                                  AppStrings.profile.keepSameAddress,
                                ),
                              },
                              onChanged: (value) {
                                setDialogState(
                                  () => _importConflictPolicy = value,
                                );
                                setState(() => _importConflictPolicy = value);
                              },
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            AppStrings.profile.importConflictHelp,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (widget.behavior.supportsCImport)
                          CheckboxListTile(
                            value: _ignoreCImportComments,
                            onChanged: (value) {
                              final checked = value ?? false;
                              setDialogState(
                                () => _ignoreCImportComments = checked,
                              );
                              setState(() => _ignoreCImportComments = checked);
                            },
                            title: Text(AppStrings.profile.ignoreComments),
                            subtitle: Text(
                              AppStrings.profile.ignoreCommentsHelp,
                            ),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                        if (widget.behavior.supportsCImport)
                          const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            _importJsonProfile();
                          },
                          icon: const Icon(
                            Icons.file_upload_outlined,
                            size: 16,
                          ),
                          label: Text(AppStrings.profile.importJson),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            _importCsvProfile();
                          },
                          icon: const Icon(Icons.table_chart, size: 16),
                          label: Text(AppStrings.profile.importCsv),
                        ),
                        if (widget.behavior.supportsCImport)
                          const SizedBox(height: 8),
                        if (widget.behavior.supportsCImport)
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              _importCProfileFile();
                            },
                            icon: const Icon(Icons.code, size: 16),
                            label: Text(AppStrings.profile.importCFile),
                          ),
                        if (widget.behavior.supportsCImport)
                          const SizedBox(height: 8),
                        if (widget.behavior.supportsCImport)
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              _pasteCProfileCode();
                            },
                            icon: const Icon(Icons.content_paste, size: 16),
                            label: Text(AppStrings.profile.pasteCCode),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(AppStrings.common.cancel),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _importJsonProfile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.profile.importZobowProfileDialogTitle,
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    try {
      final json = jsonDecode(await File(path).readAsString());
      if (json is! Map<String, dynamic>) {
        throw FormatException(AppStrings.profile.invalidProfileFormat);
      }
      final profile = AddressConfigProfile.fromJson(json);
      if (profile.presets.isEmpty) {
        throw FormatException(AppStrings.profile.emptyProfilePresets);
      }

      _applyImportedPresets(profile.presets, profileName: profile.name);
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.importProfileFailed(error.toString()),
        messenger: ScaffoldMessenger.of(context),
      );
    }
  }

  Future<void> _importCsvProfile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.profile.importAddressCsvDialogTitle,
      type: FileType.custom,
      allowedExtensions: ['csv'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    try {
      final presets = AddressProfileCsvImporter.parse(
        await File(path).readAsString(),
        protocolType: widget.behavior.protocolType,
      );
      _applyImportedPresets(presets, profileName: _fileBaseName(path));
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.importCsvFailed(error.toString()),
        messenger: ScaffoldMessenger.of(context),
      );
    }
  }

  Future<void> _importCProfileFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: AppStrings.profile.importZobowCDialogTitle,
      type: FileType.custom,
      allowedExtensions: ['c', 'h', 'txt'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    try {
      final imported = await ZobowCProfileImporter.parseFile(
        path,
        useComments: !_ignoreCImportComments,
      );
      _applyImportedCProfile(imported, profileName: _fileBaseName(path));
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.importCFailed(error.toString()),
        messenger: ScaffoldMessenger.of(context),
      );
    }
  }

  Future<void> _pasteCProfileCode() async {
    final code = await _showPasteCCodeDialog();
    if (code == null || code.trim().isEmpty || !mounted) return;

    try {
      final imported = ZobowCProfileImporter.parseSource(
        code,
        useComments: !_ignoreCImportComments,
      );
      _applyImportedCProfile(imported);
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.importCFailed(error.toString()),
        messenger: ScaffoldMessenger.of(context),
      );
    }
  }

  Future<String?> _showPasteCCodeDialog() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              title: Text(AppStrings.profile.pasteCCode),
              content: SizedBox(
                width: 560,
                height: 360,
                child: TextField(
                  controller: controller,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                    fontFamily: 'SarasaUiSC',
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: AppStrings.profile.pasteCCodeHint,
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppStrings.common.cancel),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, controller.text),
                  child: Text(AppStrings.profile.importAction),
                ),
              ],
            ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _applyImportedCProfile(
    ZobowCProfileImportResult imported, {
    String? profileName,
  }) {
    if (imported.presets.isEmpty) {
      AppNotifications.show(
        AppStrings.profile.noCProfileSwitchFound,
        messenger: ScaffoldMessenger.of(context),
      );
      return;
    }

    _applyImportedPresets(imported.presets, profileName: profileName);
  }

  void _applyImportedPresets(
    List<AddressChannelPreset> presets, {
    String? profileName,
  }) {
    final mergedPresets =
        widget.profile == null
            ? presets.map((preset) => preset.copyWith()).toList()
            : _mergeWithCurrentPresets(presets);
    if (mergedPresets == null) return;

    for (final row in _rows) {
      row.dispose();
    }
    setState(() {
      if (widget.profile == null &&
          profileName != null &&
          profileName.trim().isNotEmpty) {
        _nameController.text = profileName.trim();
      }
      _rows
        ..clear()
        ..addAll(mergedPresets.map(_rowFromPreset));
      _selectedRowIndex = null;
    });
    AppNotifications.show(
      AppStrings.profile.importedPresetCount(presets.length),
      messenger: ScaffoldMessenger.of(context),
    );
  }

  List<AddressChannelPreset>? _mergeWithCurrentPresets(
    List<AddressChannelPreset> imported,
  ) {
    final existing = <AddressChannelPreset>[];
    for (final row in _rows) {
      final name = row.nameController.text.trim();
      if (name.isEmpty) continue;
      final preset = widget.behavior.parsePreset(
        name,
        row.addressController.text.trim(),
      );
      if (preset == null) {
        AppNotifications.show(
          AppStrings.profile.invalidPresetAddress(name),
          messenger: ScaffoldMessenger.of(context),
        );
        return null;
      }
      existing.add(preset);
    }
    return mergeImportedAddressPresets(
      existing: existing,
      imported: imported,
      policy: _importConflictPolicy,
    );
  }

  Future<void> _editRowSequence(int currentIndex) async {
    if (currentIndex < 0 || currentIndex >= _rows.length) return;
    final requested = await showDialog<int>(
      context: context,
      builder:
          (_) => _SequenceEditDialog(
            initialSequence: currentIndex + 1,
            maximumSequence: _rows.length + 1,
          ),
    );
    if (!mounted || requested == null) return;
    final sequence = normalizeAddressPresetSequence(requested, _rows.length);
    final targetIndex = (sequence - 1).clamp(0, _rows.length - 1);
    if (targetIndex == currentIndex) return;
    setState(() {
      final row = _rows.removeAt(currentIndex);
      final insertionIndex = targetIndex.clamp(0, _rows.length);
      _rows.insert(insertionIndex, row);
      _selectedRowIndex = insertionIndex;
    });
    _jumpToRow(_selectedRowIndex!);
  }

  void _addRow() {
    setState(() {
      _rows.add(
        _PresetRow(
          nameController: TextEditingController(
            text: AppStrings.profile.presetName(_rows.length + 1),
          ),
          addressController: TextEditingController(
            text: widget.behavior.defaultAddressText,
          ),
        ),
      );
      _selectedRowIndex = _rows.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_presetListScrollController.hasClients) return;
      _presetListScrollController.animateTo(
        _presetListScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  _PresetRow _rowFromPreset(AddressChannelPreset preset) {
    return _PresetRow(
      nameController: TextEditingController(text: preset.name),
      addressController: TextEditingController(
        text: widget.behavior.formatAddress(preset),
      ),
    );
  }

  String _fileBaseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void _deleteSelectedRow() {
    if (_selectedRowIndex == null) return;
    setState(() {
      _rows[_selectedRowIndex!].dispose();
      _rows.removeAt(_selectedRowIndex!);
      _selectedRowIndex = null;
    });
  }

  AddressConfigProfile? _buildProfileFromInput({required bool keepExistingId}) {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;

    final presets = <AddressChannelPreset>[];
    for (final row in _rows) {
      final presetName = row.nameController.text.trim();
      if (presetName.isEmpty) continue;

      final addrText = row.addressController.text.trim();
      final preset = widget.behavior.parsePreset(presetName, addrText);
      if (preset == null) {
        AppNotifications.show(
          AppStrings.profile.invalidPresetAddress(presetName),
          messenger: ScaffoldMessenger.of(context),
        );
        return null;
      }
      presets.add(preset);
    }

    return AddressConfigProfile(
      id:
          keepExistingId && widget.profile != null
              ? widget.profile!.id
              : sanitizeFileName(name, fallback: 'profile'),
      name: name,
      protocolType: widget.behavior.protocolType,
      presets: presets,
    );
  }

  Future<void> _exportProfile() async {
    final profile = _buildProfileFromInput(keepExistingId: true);
    if (profile == null) return;

    try {
      final defaultName =
          '${sanitizeFileName(profile.name, fallback: AppStrings.profile.defaultConfigName)}.json';
      final selectedPath = await FilePicker.saveFile(
        dialogTitle: AppStrings.profile.exportProfileDialogTitle,
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (selectedPath == null || !mounted) return;

      final exportPath =
          selectedPath.toLowerCase().endsWith('.json')
              ? selectedPath
              : '$selectedPath.json';
      await _runWithProgressDialog(
        title: AppStrings.profile.exportingProfile,
        message: AppStrings.profile.exportProfileWriting,
        action: () async {
          await File(
            exportPath,
          ).writeAsString(profile.toJsonString(), encoding: utf8);
        },
      );
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.exportProfileCompleted(exportPath),
        messenger: ScaffoldMessenger.of(context),
      );
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        AppStrings.profile.exportProfileFailed(error.toString()),
        messenger: ScaffoldMessenger.of(context),
      );
    }
  }

  Future<void> _runWithProgressDialog({
    required String title,
    required String message,
    required Future<void> Function() action,
  }) async {
    var dialogClosed = false;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => _ProfileProgressDialog(title: title, message: message),
      ).whenComplete(() => dialogClosed = true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      await action();
    } finally {
      if (mounted && !dialogClosed) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  void _saveProfile() {
    final inputProfile = _buildProfileFromInput(keepExistingId: true);
    if (inputProfile == null) return;

    if (widget.profile == null) {
      // 创建新配置
      final create = widget.behavior.createProfile(
        widget.vm,
        inputProfile.name,
      );
      create.then((profile) {
        if (profile != null) {
          profile.presets = inputProfile.presets;
          final update = widget.behavior.updateProfile(widget.vm, profile);
          update.then((_) {
            widget.behavior.selectProfile(widget.vm, profile.id);
            if (mounted) Navigator.pop(context);
          });
        }
      });
    } else {
      // 更新现有配置
      final updated = widget.profile!.copyWith(
        name: inputProfile.name,
        protocolType: widget.behavior.protocolType,
        presets: inputProfile.presets,
      );
      final update = widget.behavior.updateProfile(widget.vm, updated);
      update.then((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }
}

/// 表格行数据包装
class _PresetRow {
  final GlobalKey rowKey = GlobalKey();
  final TextEditingController nameController;
  final TextEditingController addressController;

  _PresetRow({required this.nameController, required this.addressController});

  void dispose() {
    nameController.dispose();
    addressController.dispose();
  }
}

/// 序号编辑弹窗自行持有输入控制器，确保退场动画结束后再释放资源。
class _SequenceEditDialog extends StatefulWidget {
  const _SequenceEditDialog({
    required this.initialSequence,
    required this.maximumSequence,
  });

  final int initialSequence;
  final int maximumSequence;

  @override
  State<_SequenceEditDialog> createState() => _SequenceEditDialogState();
}

class _SequenceEditDialogState extends State<_SequenceEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initialSequence}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, int.tryParse(_controller.text));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(AppStrings.profile.editSequence),
    content: SizedBox(
      width: 280,
      child: AppNumberField(
        key: const ValueKey('address-profile-sequence-input'),
        controller: _controller,
        autofocus: true,
        labelText: AppStrings.profile.sequence,
        helperText: AppStrings.profile.sequenceRangeHelp(
          widget.maximumSequence,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppStrings.common.cancel),
      ),
      ElevatedButton(
        onPressed: _submit,
        child: Text(AppStrings.common.confirm),
      ),
    ],
  );
}

class _ProfileProgressDialog extends StatelessWidget {
  final String title;
  final String message;

  const _ProfileProgressDialog({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: Text(title),
        content: SizedBox(
          width: 280,
          child: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}
