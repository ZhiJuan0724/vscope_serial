part of '../plot_page.dart';

class _ZobowChannelIdInputFormatter extends TextInputFormatter {
  const _ZobowChannelIdInputFormatter();

  static final RegExp _partialHexPattern = RegExp(r'^(?:0[xX]?)?[0-9a-fA-F]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    if (!_partialHexPattern.hasMatch(text)) return oldValue;

    final hex =
        text.startsWith('0x') || text.startsWith('0X')
            ? text.substring(2)
            : text;
    if (hex.isEmpty) return newValue;

    final value = int.tryParse(hex, radix: 16);
    if (value == null || value > 0xFFFFFFFF) return oldValue;
    return newValue;
  }
}

/// 绘图页面左侧通道列表、通道编辑弹窗和通道预设入口。
class _ChannelItem extends StatefulWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelItem({super.key, required this.vm, required this.ch});

  @override
  State<_ChannelItem> createState() => _ChannelItemState();
}

class _ChannelItemState extends State<_ChannelItem> {
  bool _isEditingName = false;
  late final TextEditingController _nameController;
  late final TextEditingController _idController;
  late final FocusNode _nameFocusNode;
  late final FocusNode _addressFocusNode;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _idController = TextEditingController();
    _nameFocusNode = FocusNode()..addListener(_handleNameFocusChange);
    _addressFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _nameFocusNode.dispose();
    _addressFocusNode.dispose();
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  /// 获取显示名称（别名优先，空则回退到 ChN）
  String get _displayName =>
      widget.ch.alias.isNotEmpty ? widget.ch.alias : 'Ch${widget.ch.index}';

  void _saveAlias() {
    final text = _nameController.text.trim();
    // 空输入则恢复默认名称（清空别名）
    widget.vm.setChannelAlias(widget.ch.index, text);
    if (mounted) {
      setState(() => _isEditingName = false);
    }
  }

  void _handleNameFocusChange() {
    if (!_nameFocusNode.hasFocus && _isEditingName) {
      _saveAlias();
    }
  }

  void _startEditingName() {
    setState(() {
      _isEditingName = true;
      _nameController.text = _displayName;
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isEditingName) return;
      _nameFocusNode.requestFocus();
    });
  }

  void _saveZobowId() {
    final text = _idController.text.trim();
    final hex = text.replaceAll('0x', '').replaceAll('0X', '');
    final id = int.tryParse(hex, radix: 16);
    if (id != null && id >= 0 && id <= 0xFFFFFFFF) {
      widget.vm.setZobowChannelId(widget.ch.index, id);
    }
  }

  void _saveRAddress() {
    final text = _idController.text.trim();
    final address = PlotViewModel.parseRProtocolAddress(text);
    if (text.isEmpty || (address != null && address >= 0)) {
      widget.vm.setRChannelAddress(widget.ch.index, text);
    }
  }

  void _onAddressFocusChange(bool hasFocus) {
    if (mounted) {
      setState(() {});
    }
    if (!hasFocus) {
      // 失去焦点时取消文本选择
      _idController.selection = TextSelection.collapsed(
        offset: _idController.text.length,
      );
      if (widget.vm.effectiveSendProtocolType == SendProtocolType.rProtocol) {
        _saveRAddress();
      } else {
        _saveZobowId();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZobowMode =
        widget.vm.parserType == ParserType.zobow &&
        widget.ch.index < widget.vm.parserConfig.zobowChannelCount;
    final isRProtocolMode =
        widget.vm.effectiveSendProtocolType == SendProtocolType.rProtocol &&
        widget.ch.index < SendProtocolConfig.maxChannelCount;
    final showsAddress = isZobowMode || isRProtocolMode;
    final zobowAddress =
        isZobowMode
            ? widget.vm.parserConfig.zobowChannelIds[widget.ch.index]
            : 0;
    final usesShortZobowAddress =
        isZobowMode && (zobowAddress & 0xFFFF0000) == 0;
    final rAddress =
        isRProtocolMode ? widget.vm.rChannelAddresses[widget.ch.index] : '';
    final reservesRAddressSpace =
        !showsAddress &&
        widget.vm.effectiveSendProtocolType == SendProtocolType.none;
    final addressText =
        isRProtocolMode
            ? rAddress
            : _formatZobowAddress(zobowAddress, compact: usesShortZobowAddress);
    if (!_addressFocusNode.hasFocus && _idController.text != addressText) {
      _idController.text = addressText;
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // 颜色指示器（点击打开编辑弹窗）
          InkWell(
            onTap: () => _showChannelEditDialog(context),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: widget.ch.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 通道名/别名（双击编辑）+ 众邦电控ID（直接编辑）并排显示
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 通道名称：双击进入编辑模式
                Flexible(
                  child:
                      _isEditingName
                          ? SizedBox(
                            height: 24,
                            child: TextField(
                              controller: _nameController,
                              focusNode: _nameFocusNode,
                              autofocus: true,
                              maxLength: 8,
                              style: const TextStyle(fontSize: 14),
                              decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 0,
                                ),
                                border: UnderlineInputBorder(),
                                counterText: '',
                              ),
                              onSubmitted: (_) => _saveAlias(),
                              onEditingComplete: _saveAlias,
                              onTapOutside: (_) => _nameFocusNode.unfocus(),
                            ),
                          )
                          : GestureDetector(
                            onDoubleTap: _startEditingName,
                            child: Text(
                              _displayName,
                              style: TextStyle(
                                fontSize: 14,
                                color: widget.ch.visible ? null : Colors.grey,
                                decoration:
                                    widget.ch.visible
                                        ? null
                                        : TextDecoration.lineThrough,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                ),
                // 众邦电控模式下显示地址，常驻可编辑 TextField
                if (showsAddress) ...[
                  const SizedBox(width: 6),
                  Container(
                    width:
                        isRProtocolMode
                            ? kRProtocolAddressWidth
                            : usesShortZobowAddress &&
                                !_addressFocusNode.hasFocus
                            ? 58
                            : kRProtocolAddressWidth,
                    height: 26,
                    alignment: Alignment.centerLeft,
                    child: Focus(
                      focusNode: _addressFocusNode,
                      onFocusChange: _onAddressFocusChange,
                      child: TextField(
                        controller: _idController,
                        style: TextStyle(
                          fontSize: 14,
                          fontFamily: 'SarasaUiSC',
                          color: Theme.of(context).colorScheme.onSurface,
                          height: 1.15,
                        ),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 2,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Colors.grey.shade400,
                              width: 1,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Colors.grey.shade400,
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(2),
                            borderSide: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1,
                            ),
                          ),
                        ),
                        inputFormatters: [
                          if (isRProtocolMode)
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9a-fA-FxX]'),
                            )
                          else
                            const _ZobowChannelIdInputFormatter(),
                        ],
                        onSubmitted:
                            (_) =>
                                isRProtocolMode
                                    ? _saveRAddress()
                                    : _saveZobowId(),
                        onEditingComplete:
                            isRProtocolMode ? _saveRAddress : _saveZobowId,
                      ),
                    ),
                  ),
                  // 预设选择按钮
                  _buildPresetButton(context),
                ] else if (reservesRAddressSpace) ...[
                  const SizedBox(width: 6),
                  const SizedBox(width: kRProtocolAddressWidth, height: 26),
                ],
              ],
            ),
          ),
          Tooltip(
            message:
                widget.ch.offsetEnabled
                    ? AppStrings.plot.closeOffset
                    : AppStrings.plot.openOffset,
            child: SizedBox(
              width: 20,
              height: 24,
              child: Checkbox(
                value: widget.ch.offsetEnabled,
                onChanged:
                    (value) => widget.vm.setChannelOffsetEnabled(
                      widget.ch.index,
                      value!,
                    ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 5),
          // 绘图开关
          Tooltip(
            message:
                widget.ch.visible
                    ? AppStrings.plot.hideChannel
                    : AppStrings.plot.showChannel,
            child: SizedBox(
              width: 20,
              height: 24,
              child: Checkbox(
                value: widget.ch.visible,
                onChanged:
                    (value) =>
                        widget.vm.setChannelVisible(widget.ch.index, value!),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          // 编辑按钮
          Tooltip(
            message: AppStrings.plot.editChannel,
            child: InkWell(
              onTap: () => _showChannelEditDialog(context),
              child: const SizedBox(
                width: 20,
                height: 24,
                child: Icon(Icons.settings, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示通道编辑弹窗
  void _showChannelEditDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _ChannelEditDialog(vm: widget.vm, ch: widget.ch),
    );
  }

  /// 构建预设选择按钮
  Widget _buildPresetButton(BuildContext context) {
    final isRProtocol =
        widget.vm.effectiveSendProtocolType == SendProtocolType.rProtocol;
    final profile =
        isRProtocol
            ? widget.vm.selectedRProfile
            : widget.vm.selectedZobowProfile;
    if (profile == null || profile.presets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: AppStrings.plot.selectAddress,
      child: InkWell(
        onTap: () => _showPresetSelectorDialog(context, profile),
        child: Container(
          width: 20,
          height: 20,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Icon(
            Icons.chevron_right,
            size: 14,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  /// 显示预设选择弹窗
  void _showPresetSelectorDialog(
    BuildContext context,
    ZobowConfigProfile profile,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return _PresetSelectorDialog(
          profile: profile,
          onSelect: (preset) {
            if (widget.vm.effectiveSendProtocolType ==
                SendProtocolType.rProtocol) {
              widget.vm.applyRProtocolPresetToChannel(widget.ch.index, preset);
            } else {
              widget.vm.applyPresetToChannel(widget.ch.index, preset);
            }
          },
        );
      },
    );
  }
}

/// 通道编辑对话框
///
/// 可修改通道颜色、别名、连线开关。
class _ChannelEditDialog extends StatefulWidget {
  final PlotViewModel vm;
  final ChannelConfig ch;

  const _ChannelEditDialog({required this.vm, required this.ch});

  @override
  State<_ChannelEditDialog> createState() => _ChannelEditDialogState();
}

class _ChannelEditDialogState extends State<_ChannelEditDialog> {
  static const int _progressDialogFrameThreshold = 50000;

  late Color _selectedColor;
  late String _alias;
  late bool _showLine;
  late double _pointSize;
  late double _lineWidth;
  late bool _offsetEnabled;
  late DataType _zobowDataType;
  late final TextEditingController _aliasController;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.ch.color;
    _alias = widget.ch.alias;
    _showLine = widget.ch.showLine;
    _pointSize = widget.ch.pointSize;
    _lineWidth = widget.ch.lineWidth;
    _offsetEnabled = widget.ch.offsetEnabled;
    final parserConfig = widget.vm.parserConfig;
    if (widget.vm.parserType == ParserType.zobow &&
        widget.ch.index < parserConfig.zobowChannelCount) {
      final zobowType = parserConfig.zobowChannelTypes[widget.ch.index];
      _zobowDataType =
          zobowType == DataType.int16 ? DataType.int16 : DataType.uint16;
    } else if (widget.vm.parserType == ParserType.fixedFrame &&
        widget.ch.index < parserConfig.channelCount) {
      _zobowDataType = parserConfig.fixedFrameChannelTypes[widget.ch.index];
    } else {
      _zobowDataType = widget.ch.dataType;
    }
    _aliasController = TextEditingController(text: _alias);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contentMaxHeight =
        (MediaQuery.sizeOf(context).height - 220)
            .clamp(240.0, 540.0)
            .toDouble();

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text(AppStrings.plot.editChannelTitle(widget.ch.index)),
      content: SizedBox(
        width: 280,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: contentMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 颜色选择
                Text(
                  AppStrings.plot.color,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _buildColorPicker(),
                const SizedBox(height: 14),
                // 别名输入
                Text(
                  AppStrings.plot.alias,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _aliasController,
                  maxLength: 16,
                  decoration: InputDecoration(
                    hintText: AppStrings.plot.aliasHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    counterText: '',
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                // 连线开关
                Row(
                  children: [
                    Text(
                      AppStrings.plot.showLine,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _showLine,
                      onChanged: (value) => setState(() => _showLine = value),
                    ),
                  ],
                ),
                if (_showLine) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        AppStrings.plot.lineWidth,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: _lineWidth,
                          min: 0.5,
                          max: 8.0,
                          divisions: 15,
                          label: _lineWidth.toStringAsFixed(1),
                          onChanged:
                              (value) => setState(() => _lineWidth = value),
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          _lineWidth.toStringAsFixed(1),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      AppStrings.plot.pointRadius,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _pointSize,
                        min: 0.5,
                        max: 12.0,
                        divisions: 23,
                        label: _pointSize.toStringAsFixed(1),
                        onChanged:
                            (value) => setState(() => _pointSize = value),
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text(
                        _pointSize.toStringAsFixed(1),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                // 偏移开关
                Row(
                  children: [
                    Text(
                      AppStrings.plot.showOffset,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _offsetEnabled,
                      onChanged:
                          (value) => setState(() => _offsetEnabled = value),
                    ),
                  ],
                ),
                if (_offsetEnabled) ...[
                  const SizedBox(height: 2),
                  Text(
                    AppStrings.plot.offsetHint,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
                // 众邦电控模式下显示数据类型选择
                if (widget.vm.parserType == ParserType.zobow &&
                    widget.ch.index <
                        widget.vm.parserConfig.zobowChannelCount) ...[
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.plot.dataType,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.plot.zobowDataTypeHelp,
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: kDataTypeDropdownWidth,
                        child: NoAnimDropdown<DataType>(
                          value: _zobowDataType,
                          hint: AppStrings.plot.typeHint,
                          decoration: _compactDropdownDecoration(),
                          items:
                              [DataType.uint16, DataType.int16].map((type) {
                                return DropdownMenuItem(
                                  value: type,
                                  child: Text(
                                    type.label,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                );
                              }).toList(),
                          onChanged:
                              widget.vm.isPlotting
                                  ? null
                                  : (value) {
                                    if (value != null) {
                                      setState(() => _zobowDataType = value);
                                    }
                                  },
                        ),
                      ),
                    ],
                  ),
                ],
                if (widget.vm.parserType == ParserType.fixedFrame &&
                    !widget.vm.parserConfig.fixedFrameUniformDataType &&
                    widget.ch.index < widget.vm.parserConfig.channelCount) ...[
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.plot.dataType,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.plot.fixedFrameDataTypeHelp,
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: kDataTypeDropdownWidth,
                    child: NoAnimDropdown<DataType>(
                      value: _zobowDataType,
                      hint: AppStrings.plot.typeHint,
                      decoration: _compactDropdownDecoration(),
                      items:
                          DataType.values
                              .map(
                                (type) => DropdownMenuItem(
                                  value: type,
                                  child: Text(type.label),
                                ),
                              )
                              .toList(),
                      onChanged:
                          widget.vm.isPlotting
                              ? null
                              : (value) {
                                if (value != null) {
                                  setState(() => _zobowDataType = value);
                                }
                              },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isClosing ? null : _closeDialog,
          child: Text(AppStrings.common.cancel),
        ),
        TextButton(
          onPressed: _resetLocalChannel,
          child: Text(AppStrings.common.reset),
        ),
        ElevatedButton(
          onPressed: _isClosing ? null : _saveChannel,
          child: Text(AppStrings.common.confirm),
        ),
      ],
    );
  }

  void _closeDialog() {
    if (_isClosing) return;
    _isClosing = true;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _resetLocalChannel() {
    if (_isClosing) return;
    final defaultColor =
        ChannelConfig.defaultColors[widget.ch.index %
            ChannelConfig.defaultColors.length];
    setState(() {
      _selectedColor = defaultColor;
      _alias = '';
      _aliasController.text = '';
      _showLine = true;
      _pointSize = 3.0;
      _lineWidth = 1.5;
      _offsetEnabled = false;
      _zobowDataType = DataType.uint16;
    });
  }

  Future<void> _saveChannel() async {
    if (_isClosing) return;
    _isClosing = true;
    widget.vm.setChannelColor(widget.ch.index, _selectedColor);
    widget.vm.setChannelAlias(widget.ch.index, _aliasController.text.trim());
    widget.vm.setChannelShowLine(widget.ch.index, _showLine);
    widget.vm.setChannelLineWidth(widget.ch.index, _lineWidth);
    widget.vm.setChannelPointSize(widget.ch.index, _pointSize);
    widget.vm.setChannelOffsetEnabled(widget.ch.index, _offsetEnabled);

    if (widget.vm.parserType == ParserType.zobow &&
        widget.ch.index < widget.vm.parserConfig.zobowChannelCount &&
        _zobowDataType !=
            widget.vm.parserConfig.zobowChannelTypes[widget.ch.index]) {
      await _applyZobowDataType();
    }
    if (widget.vm.parserType == ParserType.fixedFrame &&
        !widget.vm.parserConfig.fixedFrameUniformDataType &&
        widget.ch.index < widget.vm.parserConfig.channelCount &&
        _zobowDataType !=
            widget.vm.parserConfig.fixedFrameChannelTypes[widget.ch.index]) {
      await widget.vm.setFixedFrameChannelType(widget.ch.index, _zobowDataType);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _applyZobowDataType() async {
    final showProgress =
        widget.vm.zobowRawFrameCount >= _progressDialogFrameThreshold;
    final progressNotifier = ValueNotifier<PlotImportProgress>(
      PlotImportProgress(
        stage: '准备重新解释众邦数据',
        current: 0,
        total: widget.vm.zobowRawFrameCount,
      ),
    );
    var dialogClosed = false;

    if (showProgress) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder:
              (dialogContext) => _PlotImportProgressDialog(
                title: '更新通道数据类型',
                progressListenable: progressNotifier,
              ),
        ).whenComplete(() => dialogClosed = true),
      );
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      await SchedulerBinding.instance.endOfFrame;
    }

    await widget.vm.setZobowChannelType(
      widget.ch.index,
      _zobowDataType,
      onProgress: (progress) => progressNotifier.value = progress,
    );

    if (mounted && showProgress && !dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progressNotifier.dispose();
  }

  /// 构建颜色选择器（15 个黑底可识别预设色 + 自选色入口）
  Widget _buildColorPicker() {
    final presetColors = ChannelConfig.defaultColors.take(15).toList();
    final usesCustomColor =
        !presetColors.any(
          (color) => color.toARGB32() == _selectedColor.toARGB32(),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...presetColors.map((color) {
          final isSelected = color.toARGB32() == _selectedColor.toARGB32();
          return InkWell(
            onTap: () => setState(() => _selectedColor = color),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border:
                    isSelected
                        ? Border.all(color: Colors.white, width: 2)
                        : null,
                boxShadow:
                    isSelected
                        ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                          ),
                        ]
                        : null,
              ),
              child:
                  isSelected
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
            ),
          );
        }),
        Tooltip(
          message: AppStrings.plot.customColor,
          child: InkWell(
            onTap: _showCustomColorPicker,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: usesCustomColor ? _selectedColor : Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color:
                      usesCustomColor
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade400,
                  width: usesCustomColor ? 2 : 1,
                ),
              ),
              child: Icon(
                Icons.palette_outlined,
                size: 18,
                color:
                    usesCustomColor
                        ? _foregroundForColor(_selectedColor)
                        : Colors.grey.shade700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showCustomColorPicker() async {
    var selectedHsv = HSVColor.fromColor(_selectedColor);
    final selectedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final color = selectedHsv.toColor();
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              title: Text(AppStrings.plot.customColor),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 46,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade400),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildColorSlider(
                      label: AppStrings.plot.hue,
                      value: selectedHsv.hue,
                      max: 360,
                      displayValue: '${selectedHsv.hue.round()}°',
                      onChanged: (value) {
                        setDialogState(() {
                          selectedHsv = selectedHsv.withHue(value);
                        });
                      },
                    ),
                    _buildColorSlider(
                      label: AppStrings.plot.saturation,
                      value: selectedHsv.saturation * 100,
                      max: 100,
                      displayValue:
                          '${(selectedHsv.saturation * 100).round()}%',
                      onChanged: (value) {
                        setDialogState(() {
                          selectedHsv = selectedHsv.withSaturation(value / 100);
                        });
                      },
                    ),
                    _buildColorSlider(
                      label: AppStrings.plot.brightness,
                      value: selectedHsv.value * 100,
                      max: 100,
                      displayValue: '${(selectedHsv.value * 100).round()}%',
                      onChanged: (value) {
                        setDialogState(() {
                          selectedHsv = selectedHsv.withValue(value / 100);
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppStrings.common.cancel),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, color),
                  child: Text(AppStrings.common.confirm),
                ),
              ],
            );
          },
        );
      },
    );
    if (selectedColor != null && mounted) {
      setState(() => _selectedColor = selectedColor);
    }
  }

  Widget _buildColorSlider({
    required String label,
    required double value,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Slider(value: value, min: 0, max: max, onChanged: onChanged),
        ),
        SizedBox(
          width: 38,
          child: Text(
            displayValue,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Color _foregroundForColor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }
}
