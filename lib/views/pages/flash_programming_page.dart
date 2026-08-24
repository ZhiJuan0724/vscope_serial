import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_strings.dart';
import '../../data/models/flash_programming_models.dart';
import '../../data/models/flash_data_document.dart';
import '../../services/app_notifications.dart';
import '../../services/app_settings.dart';
import '../../services/flash_programming_service.dart';
import '../widgets/common_widgets.dart';
import '../widgets/flash_hex_viewer.dart';

class FlashProgrammingPage extends StatefulWidget {
  const FlashProgrammingPage({super.key});

  @override
  State<FlashProgrammingPage> createState() => _FlashProgrammingPageState();
}

class _FlashProgrammingPageState extends State<FlashProgrammingPage> {
  final _binAddress = TextEditingController(text: '0x08000000');
  final _eraseAddress = TextEditingController(text: '0x08000000');
  final _eraseLength = TextEditingController(text: '0x1000');
  final _readAddress = TextEditingController(text: '0x08000000');
  final _readLength = TextEditingController(text: '0x1000');
  bool _eraseBeforeProgram = true;
  bool _verifyAfterProgram = true;
  bool _resetAfterProgram = true;
  bool _showHexViewer = true;
  bool _showToolOutput = true;
  int _bytesPerRow = 16;
  int _hexGroupBits = 8;
  bool _autoExpandHexRows = true;
  double _hexPanelFraction = 0.65;
  double? _splitDragStartY;
  double? _splitDragStartHexHeight;
  final List<FlashDataDocument> _documents = [];
  String? _selectedDocumentId;
  String? _programDocumentId;

  @override
  void dispose() {
    for (final controller in [
      _binAddress,
      _eraseAddress,
      _eraseLength,
      _readAddress,
      _readLength,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _parseAddress(String value) {
    final text = value.trim().toLowerCase();
    return int.tryParse(
      text.startsWith('0x') ? text.substring(2) : text,
      radix: text.startsWith('0x') ? 16 : 10,
    );
  }

  Future<bool> _confirm(
    String title,
    String message, {
    bool includeOperationRiskWarning = false,
  }) async {
    final settings = AppSettings();
    final showRiskWarning =
        includeOperationRiskWarning &&
        !settings.flashOperationRiskWarningDismissed;
    var dismissRiskWarning = false;
    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder:
              (dialogContext) => StatefulBuilder(
                builder:
                    (context, setDialogState) => AlertDialog(
                      shape: kAdvancedSettingsDialogShape,
                      title: Text(title),
                      content: SizedBox(
                        width: 460,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(message),
                            if (showRiskWarning) ...[
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .errorContainer
                                      .withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  AppStrings.flash.operationRiskWarning,
                                ),
                              ),
                              CheckboxListTile(
                                value: dismissRiskWarning,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  AppStrings.flash.dismissRiskWarning,
                                ),
                                onChanged:
                                    (value) => setDialogState(
                                      () => dismissRiskWarning = value ?? false,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: Text(AppStrings.common.cancel),
                        ),
                        DialogPrimaryActionButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          label: AppStrings.flash.confirm,
                        ),
                      ],
                    ),
              ),
        ) ??
        false;
    if (confirmed && showRiskWarning && dismissRiskWarning) {
      settings.flashOperationRiskWarningDismissed = true;
      await settings.save();
    }
    return confirmed;
  }

  Future<void> _pickProgramFile() async {
    final result = await file_picker.FilePicker.pickFiles(
      dialogTitle: AppStrings.flash.chooseProgramFile,
      type: file_picker.FileType.custom,
      allowedExtensions: const ['elf', 'hex', 'bin'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    int? binAddress;
    if (path.toLowerCase().endsWith('.bin')) {
      binAddress = await _askBinBaseAddress();
      if (binAddress == null) return;
    }
    try {
      final document = await FlashDataDocument.open(
        path,
        binAddress: binAddress,
      );
      if (!mounted) return;
      setState(() {
        _documents.add(document);
        _selectedDocumentId = document.id;
        _programDocumentId ??= document.id;
        _showHexViewer = true;
      });
    } catch (error) {
      AppNotifications.show('打开Flash数据失败：$error');
    }
  }

  Future<int?> _askBinBaseAddress() async {
    final controller = TextEditingController(text: _binAddress.text);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: kAdvancedSettingsDialogShape,
            title: Text(AppStrings.flash.setBinBaseAddress),
            content: SizedBox(
              width: 360,
              child: AppDialogTextField(
                controller: controller,
                autofocus: true,
                labelText: AppStrings.flash.binBaseAddressLabel,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(AppStrings.common.cancel),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                label: AppStrings.flash.open,
              ),
            ],
          ),
    );
    final address = _parseAddress(controller.text);
    controller.dispose();
    if (confirmed != true) return null;
    if (address == null || address < 0 || address > 0xFFFFFFFF) {
      AppNotifications.show('BIN基地址必须在0x00000000～0xFFFFFFFF之间');
      return null;
    }
    _binAddress.text =
        '0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    return address;
  }

  Future<void> _program() async {
    final document = _documentById(_programDocumentId);
    if (document == null) {
      AppNotifications.show('请先从工具栏打开烧写文件并选择HEX文档');
      return;
    }
    final temporary = document.sourcePath == null;
    final path =
        document.sourcePath ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'vscope_program_${DateTime.now().microsecondsSinceEpoch}.bin';
    final request = FlashProgramRequest(
      filePath: path,
      binAddress:
          path.toLowerCase().endsWith('.bin')
              ? document.sourceBinAddress ?? document.firstAddress
              : null,
      erase: _eraseBeforeProgram,
      verify: _verifyAfterProgram,
      keepHalted: !_resetAfterProgram,
    );
    try {
      request.validate();
    } catch (error) {
      AppNotifications.show('$error');
      return;
    }
    final service = context.read<FlashProgrammingService>();
    if (!await _confirm(
      AppStrings.flash.confirmProgramTitle,
      AppStrings.flash.programConfirmMessage(
        chip: service.config?.target,
        backend: service.activeBackendName,
        documentName: document.name,
        erase: request.erase,
      ),
      includeOperationRiskWarning: true,
    )) {
      return;
    }
    try {
      if (temporary) {
        await File(path).writeAsBytes(document.toBinary(), flush: true);
      }
      await service.program(request);
      AppNotifications.show('Flash烧写完成');
    } catch (error) {
      AppNotifications.show('Flash烧写失败：$error');
    } finally {
      if (temporary) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _erase(bool wholeChip) async {
    final address = _parseAddress(_eraseAddress.text);
    final length = _parseAddress(_eraseLength.text);
    if (!wholeChip &&
        (address == null ||
            address < 0 ||
            address > 0xFFFFFFFF ||
            length == null ||
            length <= 0 ||
            address + length > 0x100000000)) {
      AppNotifications.show('擦除地址或长度无效');
      return;
    }
    final service = context.read<FlashProgrammingService>();
    final range =
        wholeChip
            ? AppStrings.flash.wholeChip
            : '0x${address!.toRadixString(16)} ～ '
                '0x${(address + length!).toRadixString(16)}';
    if (!await _confirm(
      AppStrings.flash.confirmEraseTitle,
      AppStrings.flash.eraseConfirmMessage(
        chip: service.config?.target,
        backend: service.activeBackendName,
        range: range,
      ),
      includeOperationRiskWarning: true,
    )) {
      return;
    }
    try {
      await service.erase(
        wholeChip
            ? const FlashEraseRequest.chip()
            : FlashEraseRequest.range(address: address!, length: length!),
      );
      AppNotifications.show('Flash擦除完成，目标保持停止');
    } catch (error) {
      AppNotifications.show('Flash擦除失败：$error');
    }
  }

  Future<void> _read() async {
    final address = _parseAddress(_readAddress.text);
    final length = _parseAddress(_readLength.text);
    if (address == null ||
        address < 0 ||
        address > 0xFFFFFFFF ||
        length == null ||
        length <= 0 ||
        address + length > 0x100000000) {
      AppNotifications.show('读取地址或长度无效');
      return;
    }
    final service = context.read<FlashProgrammingService>();
    if (!await _confirm(
      AppStrings.flash.confirmReadTitle,
      AppStrings.flash.readConfirmMessage(
        chip: service.config?.target,
        backend: service.activeBackendName,
        address: '0x${address.toRadixString(16)}',
        length: '0x${length.toRadixString(16)}',
      ),
      includeOperationRiskWarning: true,
    )) {
      return;
    }
    try {
      final data = await service.readBytes(address: address, length: length);
      if (!mounted) return;
      final target =
          (service.config?.target.trim().isNotEmpty ?? false)
              ? service.config!.target.trim()
              : 'MCU';
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final time =
          '${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final document = FlashDataDocument.fromRead(
        name:
            '$target-0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')}-$time',
        address: address,
        data: data,
      );
      setState(() {
        _documents.add(document);
        _selectedDocumentId = document.id;
        _programDocumentId ??= document.id;
        _showHexViewer = true;
      });
      AppNotifications.show('Flash读取完成，已在HEX查看器中打开');
    } catch (error) {
      AppNotifications.show('Flash读取失败：$error');
    }
  }

  FlashDataDocument? _documentById(String? id) {
    for (final document in _documents) {
      if (document.id == id) return document;
    }
    return null;
  }

  void _closeDocument(String id) {
    final index = _documents.indexWhere((item) => item.id == id);
    if (index < 0) return;
    setState(() {
      _documents.removeAt(index);
      if (_selectedDocumentId == id) {
        _selectedDocumentId =
            _documents.isEmpty
                ? null
                : _documents[index.clamp(0, _documents.length - 1)].id;
      }
      if (_programDocumentId == id) {
        _programDocumentId = _documents.firstOrNull?.id;
      }
    });
  }

  Future<void> _saveSelectedDocument() async {
    final document = _documentById(_selectedDocumentId);
    if (document == null) return;
    var path = await file_picker.FilePicker.saveFile(
      dialogTitle: AppStrings.flash.saveFlashData,
      fileName: '${document.name}.bin',
      type: file_picker.FileType.custom,
      allowedExtensions: const ['bin', 'hex'],
    );
    if (path == null) return;
    final lower = path.toLowerCase();
    if (!lower.endsWith('.bin') && !lower.endsWith('.hex')) path = '$path.bin';
    try {
      final data =
          path.toLowerCase().endsWith('.hex')
              ? document.toIntelHex()
              : document.toBinary();
      await File(path).writeAsBytes(data, flush: true);
      AppNotifications.show('Flash数据已保存：$path');
    } catch (error) {
      AppNotifications.show('保存Flash数据失败：$error');
    }
  }

  Future<void> _configureHexDisplay() async {
    final bytesController = TextEditingController(
      text: '0x${_bytesPerRow.toRadixString(16).toUpperCase()}',
    );
    var groupBits = _hexGroupBits;
    var autoExpand = _autoExpandHexRows;
    await showDialog<void>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AppSettingsDialog(
                  title: Text(AppStrings.flash.hexDisplaySettings),
                  size: AppDialogSize.medium,
                  changeListenables: [bytesController],
                  hasUnsavedChanges:
                      () =>
                          bytesController.text !=
                              '0x${_bytesPerRow.toRadixString(16).toUpperCase()}' ||
                          groupBits != _hexGroupBits ||
                          autoExpand != _autoExpandHexRows,
                  onSave: () async {
                    final text = bytesController.text.trim().toLowerCase();
                    final bytes = int.tryParse(
                      text.startsWith('0x') ? text.substring(2) : text,
                      radix: text.startsWith('0x') ? 16 : 10,
                    );
                    final groupBytes = groupBits ~/ 8;
                    if (bytes == null ||
                        bytes < groupBytes ||
                        bytes > 0x100 ||
                        bytes % groupBytes != 0) {
                      throw FormatException(
                        AppStrings.flash.bytesPerRowInvalid,
                      );
                    }
                    setState(() {
                      _bytesPerRow = bytes;
                      _hexGroupBits = groupBits;
                      _autoExpandHexRows = autoExpand;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppDialogTextField(
                        controller: bytesController,
                        labelText: AppStrings.flash.bytesPerRow,
                        helperText: AppStrings.flash.bytesPerRowHelper,
                      ),
                      const SizedBox(height: 14),
                      AppDialogDropdown<int>(
                        value: groupBits,
                        hint: AppStrings.flash.groupBitsHint,
                        labelText: AppStrings.flash.groupDisplay,
                        items: [
                          DropdownMenuItem(
                            value: 8,
                            child: Text(AppStrings.flash.group8),
                          ),
                          DropdownMenuItem(
                            value: 16,
                            child: Text(AppStrings.flash.group16),
                          ),
                          DropdownMenuItem(
                            value: 32,
                            child: Text(AppStrings.flash.group32),
                          ),
                        ],
                        onChanged:
                            (value) => setDialogState(
                              () => groupBits = value ?? groupBits,
                            ),
                      ),
                      AppCheckboxRow(
                        value: autoExpand,
                        title: Text(AppStrings.flash.autoExpandRows),
                        onChanged:
                            (value) => setDialogState(
                              () => autoExpand = value ?? true,
                            ),
                      ),
                    ],
                  ),
                ),
          ),
    );
    disposeAfterDialogTransition(bytesController.dispose);
  }

  Future<void> _forceTerminate() async {
    if (!await _confirm(
      AppStrings.flash.forceTerminate,
      AppStrings.flash.forceTerminateMessage,
    )) {
      return;
    }
    if (!mounted) return;
    await context.read<FlashProgrammingService>().forceTerminate();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FlashProgrammingService>();
    final connected = service.isConnected;
    final programDocument = _documentById(_programDocumentId);
    final showRightPanel = _showHexViewer || _showToolOutput;
    return Column(
      children: [
        UnifiedToolbar(
          leadingItems: [
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: AppStrings.flash.openFileTooltip,
                onPressed: service.isBusy ? null : _pickProgramFile,
              ),
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarToggleIconButton(
                icon: Icon(
                  _showHexViewer
                      ? Icons.view_stream
                      : Icons.view_stream_outlined,
                ),
                tooltip: AppStrings.flash.hexViewerTooltip,
                selected: _showHexViewer,
                onPressed:
                    () => setState(() => _showHexViewer = !_showHexViewer),
              ),
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarToggleIconButton(
                icon: Icon(
                  _showToolOutput ? Icons.terminal : Icons.terminal_outlined,
                ),
                tooltip: AppStrings.flash.toolOutput,
                selected: _showToolOutput,
                onPressed:
                    () => setState(() => _showToolOutput = !_showToolOutput),
              ),
            ),
          ],
          trailingItems: [
            if (service.isBusy || service.state == FlashOperationState.unknown)
              ToolbarLayoutItem(
                extent: kToolbarControlExtent,
                child: ToolbarIconButton(
                  icon: const Icon(Icons.dangerous_outlined),
                  tooltip: AppStrings.flash.forceTerminate,
                  onPressed: _forceTerminate,
                ),
                overflowActions: [
                  ToolbarOverflowAction(
                    icon: const Icon(Icons.dangerous_outlined),
                    label: AppStrings.flash.forceTerminate,
                    onPressed: _forceTerminate,
                  ),
                ],
              ),
          ],
        ),
        if (service.isBusy || service.progress > 0)
          LinearProgressIndicator(value: service.isBusy ? service.progress : 1),
        Expanded(
          child: Row(
            children: [
              if (showRightPanel)
                SizedBox(
                  width: 480,
                  child: _buildOperationPanel(
                    context,
                    service,
                    connected,
                    programDocument,
                  ),
                )
              else
                Expanded(
                  child: _buildOperationPanel(
                    context,
                    service,
                    connected,
                    programDocument,
                  ),
                ),
              if (showRightPanel) ...[
                const VerticalDivider(width: 1),
                Expanded(child: _buildRightPanel(context, service)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOperationPanel(
    BuildContext context,
    FlashProgrammingService service,
    bool connected,
    FlashDataDocument? programDocument,
  ) => ListView(
    padding: const EdgeInsets.all(14),
    children: [
      _sectionTitle(AppStrings.flash.programSection),
      AppDialogDropdown<String>(
        value: programDocument?.id,
        hint: AppStrings.flash.programDataHint,
        labelText: AppStrings.flash.programDataLabel,
        items: [
          for (var index = 0; index < _documents.length; index++)
            DropdownMenuItem(
              value: _documents[index].id,
              child: Text(
                '${index + 1}. ${_documents[index].name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged:
            service.isBusy
                ? null
                : (value) => setState(() => _programDocumentId = value),
      ),
      if (programDocument != null) ...[
        const SizedBox(height: 6),
        Text(
          AppStrings.flash.baseAddress(programDocument.firstAddress),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 2,
        children: [
          _optionCheckbox(
            AppStrings.flash.eraseBeforeProgram,
            _eraseBeforeProgram,
            (value) => setState(() => _eraseBeforeProgram = value),
          ),
          _optionCheckbox(
            AppStrings.flash.verifyAfterProgram,
            _verifyAfterProgram,
            (value) => setState(() => _verifyAfterProgram = value),
          ),
          _optionCheckbox(
            AppStrings.flash.resetAfterProgram,
            _resetAfterProgram,
            (value) => setState(() => _resetAfterProgram = value),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: ElevatedButton.icon(
          onPressed:
              connected && !service.isBusy && programDocument != null
                  ? _program
                  : null,
          icon: const Icon(Icons.memory),
          label: Text(AppStrings.flash.programVerify),
        ),
      ),
      const Divider(height: 28),
      _sectionTitle(AppStrings.flash.eraseSection),
      Row(
        children: [
          Expanded(child: _input(_eraseAddress, AppStrings.flash.startAddress)),
          const SizedBox(width: 8),
          Expanded(child: _input(_eraseLength, AppStrings.flash.length)),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed:
                connected && !service.isBusy ? () => _erase(false) : null,
            child: Text(AppStrings.flash.rangeErase),
          ),
          ElevatedButton(
            onPressed: connected && !service.isBusy ? () => _erase(true) : null,
            child: Text(AppStrings.flash.chipErase),
          ),
        ],
      ),
      const Divider(height: 28),
      _sectionTitle(AppStrings.flash.readSection),
      Row(
        children: [
          Expanded(child: _input(_readAddress, AppStrings.flash.startAddress)),
          const SizedBox(width: 8),
          Expanded(child: _input(_readLength, AppStrings.flash.length)),
        ],
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: connected && !service.isBusy ? _read : null,
          icon: const Icon(Icons.download_outlined),
          label: Text(AppStrings.flash.read),
        ),
      ),
    ],
  );

  Widget _buildRightPanel(
    BuildContext context,
    FlashProgrammingService service,
  ) {
    final hexViewer = FlashHexViewer(
      documents: _documents,
      selectedId: _selectedDocumentId,
      bytesPerRow: _bytesPerRow,
      groupBits: _hexGroupBits,
      autoExpandRows: _autoExpandHexRows,
      onSelect: (id) => setState(() => _selectedDocumentId = id),
      onClose: _closeDocument,
      onSettings: _configureHexDisplay,
      onSave: _saveSelectedDocument,
    );
    if (_showHexViewer && !_showToolOutput) return hexViewer;
    if (!_showHexViewer && _showToolOutput) {
      return _buildToolOutput(context, service);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const splitterHeight = 8.0;
        const minimumOutputHeight = 88.0;
        final available = constraints.maxHeight - splitterHeight;
        final minimumHexHeight = available * 0.5;
        final maximumHexHeight = (available - minimumOutputHeight).clamp(
          minimumHexHeight,
          available,
        );
        final hexHeight = (available * _hexPanelFraction).clamp(
          minimumHexHeight,
          maximumHexHeight,
        );
        return Column(
          children: [
            SizedBox(height: hexHeight, child: hexViewer),
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (details) {
                  _splitDragStartY = details.globalPosition.dy;
                  _splitDragStartHexHeight = hexHeight;
                },
                onVerticalDragUpdate: (details) {
                  final startY = _splitDragStartY ?? details.globalPosition.dy;
                  final startHeight = _splitDragStartHexHeight ?? hexHeight;
                  final nextHeight = (startHeight +
                          details.globalPosition.dy -
                          startY)
                      .clamp(minimumHexHeight, maximumHexHeight);
                  setState(() => _hexPanelFraction = nextHeight / available);
                },
                onVerticalDragEnd: (_) {
                  _splitDragStartY = null;
                  _splitDragStartHexHeight = null;
                },
                onVerticalDragCancel: () {
                  _splitDragStartY = null;
                  _splitDragStartHexHeight = null;
                },
                child: SizedBox(
                  height: splitterHeight,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 3,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: _buildToolOutput(context, service)),
          ],
        );
      },
    );
  }

  Widget _buildToolOutput(
    BuildContext context,
    FlashProgrammingService service,
  ) => Column(
    children: [
      SizedBox(
        height: 38,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(AppStrings.flash.toolOutput),
            ),
            if (service.stage.isNotEmpty) ...[
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  service.stage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ] else
              const Spacer(),
            if (service.lastError != null)
              Tooltip(
                message: '${service.lastError}',
                child: Icon(
                  Icons.error_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            const SizedBox(width: 6),
            ToolbarIconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: AppStrings.flash.clearToolOutput,
              onPressed:
                  service.outputLines.isEmpty ? null : service.clearOutput,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child:
              service.outputLines.isEmpty
                  ? Center(child: Text(AppStrings.flash.noToolOutput))
                  : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    itemCount: service.outputLines.length,
                    itemBuilder:
                        (_, index) => SelectableText(
                          service.outputLines[index],
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontFamily: 'Consolas',
                            fontSize: 12,
                          ),
                        ),
                  ),
        ),
      ),
    ],
  );

  Widget _sectionTitle(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      value,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  );

  Widget _input(TextEditingController controller, String label) =>
      AppLabeledField(
        label: label,
        child: TextField(
          controller: controller,
          decoration: secondaryDialogFieldDecoration(),
        ),
      );

  Widget _optionCheckbox(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => InkWell(
    borderRadius: BorderRadius.circular(4),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            onChanged: (next) => onChanged(next ?? false),
          ),
          Text(label),
        ],
      ),
    ),
  );
}
