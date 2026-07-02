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

abstract class _AddressProfileBehavior {
  const _AddressProfileBehavior();

  AddressProfileProtocolType get protocolType;
  bool get supportsCImport;
  String get defaultAddressText;
  String get addressHint;

  String formatAddress(AddressChannelPreset preset);
  AddressChannelPreset? parsePreset(String name, String text);
  Future<AddressConfigProfile?> createProfile(PlotViewModel vm, String name);
  Future<void> updateProfile(PlotViewModel vm, AddressConfigProfile profile);
  Future<void> deleteProfile(PlotViewModel vm, String id);
  void selectProfile(PlotViewModel vm, String id);
}

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
  late final TextEditingController _nameController;
  late final List<_PresetRow> _rows;
  int? _selectedRowIndex;
  bool _ignoreCImportComments = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.profile?.name ?? AppStrings.profile.defaultConfigName,
    );
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
        width: 520,
        height: 400,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            isSelected
                                ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1)
                                : null,
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(
                              context,
                            ).dividerColor.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          // 拖动手柄
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
                              message: _rows[index].nameController.text,
                              waitDuration: const Duration(milliseconds: 500),
                              child: TextField(
                                controller: _rows[index].nameController,
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 4,
                                  ),
                                  border: InputBorder.none,
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 150,
                            child: TextField(
                              controller: _rows[index].addressController,
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

      for (final row in _rows) {
        row.dispose();
      }
      setState(() {
        _nameController.text = profile.name;
        _rows
          ..clear()
          ..addAll(
            profile.presets.map(
              (preset) => _PresetRow(
                nameController: TextEditingController(text: preset.name),
                addressController: TextEditingController(
                  text: widget.behavior.formatAddress(preset),
                ),
              ),
            ),
          );
        _selectedRowIndex = null;
      });
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

    for (final row in _rows) {
      row.dispose();
    }
    setState(() {
      if (profileName != null && profileName.trim().isNotEmpty) {
        _nameController.text = profileName.trim();
      }
      _rows
        ..clear()
        ..addAll(imported.presets.map(_rowFromPreset));
      _selectedRowIndex = null;
    });
    AppNotifications.show(
      AppStrings.profile.importedPresetCount(imported.presets.length),
      messenger: ScaffoldMessenger.of(context),
    );
  }

  void _applyImportedPresets(
    List<AddressChannelPreset> presets, {
    String? profileName,
  }) {
    for (final row in _rows) {
      row.dispose();
    }
    setState(() {
      if (profileName != null && profileName.trim().isNotEmpty) {
        _nameController.text = profileName.trim();
      }
      _rows
        ..clear()
        ..addAll(presets.map(_rowFromPreset));
      _selectedRowIndex = null;
    });
    AppNotifications.show(
      AppStrings.profile.importedPresetCount(presets.length),
      messenger: ScaffoldMessenger.of(context),
    );
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
  final TextEditingController nameController;
  final TextEditingController addressController;

  _PresetRow({required this.nameController, required this.addressController});

  void dispose() {
    nameController.dispose();
    addressController.dispose();
  }
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
