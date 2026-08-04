import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
                                child: const Text(
                                  '高权限操作可能停核、复位、擦除或改写目标。请确认目标硬件已处于允许编程的安全状态。',
                                ),
                              ),
                              CheckboxListTile(
                                value: dismissRiskWarning,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text('以后不再显示此高权限提示'),
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
                          child: const Text('取消'),
                        ),
                        DialogPrimaryActionButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          label: '确认',
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
      dialogTitle: '选择烧写文件',
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
            title: const Text('设置BIN基地址'),
            content: SizedBox(
              width: 360,
              child: AppDialogTextField(
                controller: controller,
                autofocus: true,
                labelText: '基地址（32位）',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              DialogPrimaryActionButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                label: '打开',
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
      '确认烧写Flash',
      '芯片：${service.config?.target}\n后端：${service.activeBackendName}\n'
          'HEX文档：${document.name}\n'
          '${request.erase ? '将先擦除相关Flash。' : '不执行预擦除。'}\n'
          '此操作可能导致现有固件和数据不可恢复。',
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
            ? '全片'
            : '0x${address!.toRadixString(16)} ～ '
                '0x${(address + length!).toRadixString(16)}';
    if (!await _confirm(
      '确认不可恢复的擦除操作',
      '芯片：${service.config?.target}\n后端：${service.activeBackendName}\n'
          '范围：$range\n\n擦除内容无法恢复，成功后目标将保持停止。',
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
      '确认读取Flash',
      '芯片：${service.config?.target}\n后端：${service.activeBackendName}\n'
          '地址：0x${address.toRadixString(16)}\n'
          '长度：0x${length.toRadixString(16)}\n\n'
          '读取过程中后端可能短暂停止目标，完成后将尝试恢复原运行状态。',
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
      dialogTitle: '保存Flash数据',
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
                  title: const Text('HEX显示设置'),
                  size: AppDialogSize.medium,
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
                      throw const FormatException(
                        '每行字节数必须为合并字节数的整数倍，范围1～0x100',
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
                        labelText: '每行字节数',
                        helperText: '支持十进制或0x开头的十六进制，默认0x10',
                      ),
                      const SizedBox(height: 14),
                      AppDialogDropdown<int>(
                        value: groupBits,
                        hint: '选择合并位宽',
                        labelText: '合并显示',
                        items: const [
                          DropdownMenuItem(value: 8, child: Text('8位：FF')),
                          DropdownMenuItem(value: 16, child: Text('16位：FFFF')),
                          DropdownMenuItem(
                            value: 32,
                            child: Text('32位：FFFFFFFF'),
                          ),
                        ],
                        onChanged:
                            (value) => setDialogState(
                              () => groupBits = value ?? groupBits,
                            ),
                      ),
                      AppCheckboxRow(
                        value: autoExpand,
                        title: const Text('宽度足够时自动扩展为每行0x20字节'),
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
      '强制终止Flash后端',
      '强制终止后目标状态将标记为未知，程序不会自动发送reset或resume补救命令。是否继续？',
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
                tooltip: '打开ELF、HEX或BIN文件',
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
                tooltip: 'HEX显示工具',
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
                tooltip: '工具输出',
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
                  tooltip: '强制终止Flash后端',
                  onPressed: _forceTerminate,
                ),
                overflowActions: [
                  ToolbarOverflowAction(
                    icon: const Icon(Icons.dangerous_outlined),
                    label: '强制终止Flash后端',
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
      _sectionTitle('烧写'),
      AppDialogDropdown<String>(
        value: programDocument?.id,
        hint: '选择HEX显示中的数据',
        labelText: '烧写数据',
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
          '基地址：0x${programDocument.firstAddress.toRadixString(16).toUpperCase().padLeft(8, '0')}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 2,
        children: [
          _optionCheckbox(
            '烧写前擦除',
            _eraseBeforeProgram,
            (value) => setState(() => _eraseBeforeProgram = value),
          ),
          _optionCheckbox(
            '烧写后校验',
            _verifyAfterProgram,
            (value) => setState(() => _verifyAfterProgram = value),
          ),
          _optionCheckbox(
            '完成后复位',
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
          label: const Text('擦除、烧写并校验'),
        ),
      ),
      const Divider(height: 28),
      _sectionTitle('擦除'),
      Row(
        children: [
          Expanded(child: _input(_eraseAddress, '起始地址')),
          const SizedBox(width: 8),
          Expanded(child: _input(_eraseLength, '长度')),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed:
                connected && !service.isBusy ? () => _erase(false) : null,
            child: const Text('范围擦除'),
          ),
          ElevatedButton(
            onPressed: connected && !service.isBusy ? () => _erase(true) : null,
            child: const Text('全片擦除'),
          ),
        ],
      ),
      const Divider(height: 28),
      _sectionTitle('读取'),
      Row(
        children: [
          Expanded(child: _input(_readAddress, '起始地址')),
          const SizedBox(width: 8),
          Expanded(child: _input(_readLength, '长度')),
        ],
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: connected && !service.isBusy ? _read : null,
          icon: const Icon(Icons.download_outlined),
          label: const Text('读取'),
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
            const Padding(
              padding: EdgeInsets.only(left: 14),
              child: Text('工具输出'),
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
              tooltip: '清空工具输出',
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
                  ? const Center(child: Text('暂无工具输出'))
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
            onChanged: (next) => onChanged(next ?? false),
          ),
          Text(label),
        ],
      ),
    ),
  );
}
