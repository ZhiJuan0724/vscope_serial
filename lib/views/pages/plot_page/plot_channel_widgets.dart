part of '../plot_page.dart';

void _showMathChannelDialog(
  BuildContext context,
  PlotViewModel vm,
  MathChannelConfig channel,
) {
  showDialog(
    context: context,
    builder: (context) => _MathChannelEditDialog(vm: vm, channel: channel),
  );
}

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

class _RProtocolAddressInputFormatter extends TextInputFormatter {
  const _RProtocolAddressInputFormatter();

  static final RegExp _decimalPattern = RegExp(r'^[0-9]+$');
  static final RegExp _hexPattern = RegExp(r'^0[xX][0-9a-fA-F]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;

    final isHex = _hexPattern.hasMatch(text);
    final isDecimal = _decimalPattern.hasMatch(text);
    if (!isHex && !isDecimal) return oldValue;

    final digits = isHex ? text.substring(2) : text;
    if (digits.isEmpty) return newValue;
    final value = int.tryParse(digits, radix: isHex ? 16 : 10);
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

  Widget _buildDisplayName(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = TextStyle(
          fontSize: 14,
          color: widget.ch.visible ? null : Colors.grey,
          decoration: widget.ch.visible ? null : TextDecoration.lineThrough,
        );
        final text = Text(
          _displayName,
          style: style,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        );
        final textPainter = TextPainter(
          text: TextSpan(text: _displayName, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final content = GestureDetector(
          onDoubleTap: _startEditingName,
          child: text,
        );
        if (textPainter.width <= constraints.maxWidth) return content;
        return Tooltip(
          message: _displayName,
          waitDuration: const Duration(milliseconds: 500),
          child: content,
        );
      },
    );
  }

  void _saveZobowId() {
    if (widget.vm.isPlotting || widget.vm.isStopping) return;
    final text = _idController.text.trim();
    final hex = text.replaceAll('0x', '').replaceAll('0X', '');
    final id = int.tryParse(hex, radix: 16);
    if (id != null && id >= 0 && id <= 0xFFFFFFFF) {
      widget.vm.setZobowChannelId(widget.ch.index, id);
    }
  }

  void _saveRAddress() {
    if (widget.vm.isPlotting || widget.vm.isStopping) return;
    final text = _idController.text.trim();
    final address = PlotViewModel.parseRProtocolAddress(text);
    if (text.isEmpty || (address != null && address >= 0)) {
      widget.vm.setRChannelAddress(widget.ch.index, text);
      return;
    }
    _idController.text = widget.vm.rChannelAddresses[widget.ch.index];
    widget.vm.showStatusMessage(AppStrings.plot.invalidRProtocolAddress);
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

  double _rProtocolAddressWidth(BuildContext context, String text) {
    final displayText = text.trim().isEmpty ? '0' : text.trim();
    final textPainter = TextPainter(
      text: TextSpan(
        text: displayText,
        style: const TextStyle(fontSize: 14, fontFamily: 'SarasaUiSC'),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    return (textPainter.width + 14).clamp(
      PlotConfiguration.rProtocolAddressMinWidth,
      PlotConfiguration.rProtocolAddressMaxWidth,
    );
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
      padding: const EdgeInsets.symmetric(
        horizontal: PlotConfiguration.channelPanelHorizontalPadding,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: widget.ch.color,
              borderRadius: BorderRadius.circular(2),
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
                          : _buildDisplayName(context),
                ),
                // 众邦电控模式下显示地址，常驻可编辑 TextField
                if (showsAddress) ...[
                  const SizedBox(width: 6),
                  Container(
                    width:
                        isRProtocolMode
                            ? _rProtocolAddressWidth(context, addressText)
                            : usesShortZobowAddress &&
                                !_addressFocusNode.hasFocus
                            ? 58
                            : PlotConfiguration.rProtocolAddressWidth,
                    height: 26,
                    alignment: Alignment.centerLeft,
                    child: Focus(
                      focusNode: _addressFocusNode,
                      onFocusChange: _onAddressFocusChange,
                      child: TextField(
                        controller: _idController,
                        enabled: !widget.vm.isPlotting && !widget.vm.isStopping,
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
                            const _RProtocolAddressInputFormatter()
                          else
                            const _ZobowChannelIdInputFormatter(),
                        ],
                        onChanged:
                            isRProtocolMode
                                ? (_) {
                                  if (mounted) setState(() {});
                                }
                                : null,
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
                  const SizedBox(
                    width: PlotConfiguration.rProtocolAddressMinWidth,
                    height: 26,
                  ),
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
          _ChannelVisibilityButton(
            visible: widget.ch.visible,
            onToggle:
                () => widget.vm.setChannelVisible(
                  widget.ch.index,
                  !widget.ch.visible,
                ),
          ),
        ],
      ),
    );
  }

  /// 构建预设选择按钮
  Widget _buildPresetButton(BuildContext context) {
    final canEditAddress = !widget.vm.isPlotting && !widget.vm.isStopping;
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
        onTap:
            canEditAddress
                ? () => _showPresetSelectorDialog(context, profile)
                : null,
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
            color:
                canEditAddress
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  /// 显示预设选择弹窗
  void _showPresetSelectorDialog(
    BuildContext context,
    AddressConfigProfile profile,
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

class _MathChannelItem extends StatelessWidget {
  final PlotViewModel vm;
  final MathChannelConfig channel;

  const _MathChannelItem({super.key, required this.vm, required this.channel});

  @override
  Widget build(BuildContext context) {
    final display = channel.display;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(
        horizontal: PlotConfiguration.channelPanelHorizontalPadding,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: display.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: channel.expression,
              child: Text(
                channel.name,
                style: TextStyle(
                  fontSize: 14,
                  color: display.visible ? null : Colors.grey,
                  decoration:
                      display.visible ? null : TextDecoration.lineThrough,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Tooltip(
            message:
                display.offsetEnabled
                    ? AppStrings.plot.closeOffset
                    : AppStrings.plot.openOffset,
            child: SizedBox(
              width: 20,
              height: 24,
              child: Checkbox(
                value: display.offsetEnabled,
                onChanged: (value) {
                  final next = display.copyWith(
                    offsetEnabled: value ?? false,
                    yOffset: value == true ? display.yOffset : 0,
                    yScale: value == true ? display.yScale : 1,
                  );
                  vm.updateMathChannelDisplay(channel.index, next);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 5),
          _ChannelVisibilityButton(
            visible: display.visible,
            onToggle:
                () => vm.updateMathChannelDisplay(
                  channel.index,
                  display.copyWith(visible: !display.visible),
                ),
          ),
        ],
      ),
    );
  }
}

class _ChannelVisibilityButton extends StatelessWidget {
  final bool visible;
  final String? tooltip;
  final VoidCallback onToggle;

  const _ChannelVisibilityButton({
    required this.visible,
    this.tooltip,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          tooltip ??
          (visible ? AppStrings.plot.hideChannel : AppStrings.plot.showChannel),
      child: SizedBox(
        width: 22,
        height: 24,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onToggle,
            child: Icon(
              visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18,
              color:
                  visible
                      ? colorScheme.onSurface.withValues(alpha: 0.82)
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _MathChannelEditDialog extends StatefulWidget {
  final PlotViewModel vm;
  final MathChannelConfig channel;

  const _MathChannelEditDialog({required this.vm, required this.channel});

  @override
  State<_MathChannelEditDialog> createState() => _MathChannelEditDialogState();
}

class _MathChannelEditDialogState extends State<_MathChannelEditDialog> {
  late final TextEditingController _expressionController;
  late Color _selectedColor;
  late bool _showLine;
  late double _pointSize;
  late double _lineWidth;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final display = widget.channel.display;
    _expressionController = TextEditingController(
      text: widget.channel.expression,
    );
    _selectedColor = display.color;
    _selectedColor = ChannelConfig.colorForBackground(
      _selectedColor,
      widget.vm.plotBackground,
    );
    _showLine = display.showLine;
    _pointSize = display.pointSize;
    _lineWidth = display.lineWidth;
  }

  @override
  void dispose() {
    _expressionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contentMaxHeight =
        (MediaQuery.sizeOf(context).height - 220)
            .clamp(240.0, 540.0)
            .toDouble();
    final expressionText = _expressionController.text.trim();
    final validationError =
        expressionText.isEmpty
            ? null
            : widget.vm.validateMathExpression(expressionText);
    final validationIcon =
        expressionText.isEmpty
            ? null
            : Icon(
              validationError == null ? Icons.check : Icons.close,
              color: validationError == null ? Colors.green : Colors.red,
              size: 18,
            );

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text('${AppStrings.plot.editMathChannel} ${widget.channel.name}'),
      content: SizedBox(
        width: 280,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: contentMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.plot.mathExpression,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _expressionController,
                  decoration: secondaryDialogFieldDecoration(
                    hintText: AppStrings.plot.mathExpressionHint,
                  ).copyWith(
                    errorText: _errorText,
                    suffixIcon: validationIcon,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                  onChanged: (_) {
                    setState(() => _errorText = null);
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  AppStrings.plot.mathExpressionHelp,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 14),
                Text(
                  AppStrings.plot.color,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildColorPicker(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      AppStrings.plot.showLine,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Switch(
                      value: _showLine,
                      onChanged: (value) => setState(() => _showLine = value),
                    ),
                  ],
                ),
                if (_showLine)
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
                          max: 8,
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
                        max: 12,
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
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.cancel),
        ),
        TextButton(
          onPressed: () {
            widget.vm.resetMathChannel(widget.channel.index);
            Navigator.of(context).pop();
          },
          child: Text(AppStrings.common.reset),
        ),
        ElevatedButton(
          onPressed: _save,
          child: Text(AppStrings.common.confirm),
        ),
      ],
    );
  }

  Widget _buildColorPicker() {
    final presetColors = _channelPresetColors(widget.vm.plotBackground);
    return _buildTwoRowColorSwatches([
      ...presetColors.map((color) {
        final selected = color.toARGB32() == _selectedColor.toARGB32();
        return InkWell(
          onTap: () => setState(() => _selectedColor = color),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border:
                  selected ? Border.all(color: Colors.white, width: 2) : null,
              boxShadow:
                  selected
                      ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ]
                      : null,
            ),
            child:
                selected
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
              color: _usesCustomColor ? _selectedColor : Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color:
                    _usesCustomColor
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.shade400,
                width: _usesCustomColor ? 2 : 1,
              ),
            ),
            child: Icon(
              Icons.palette_outlined,
              size: 18,
              color:
                  _usesCustomColor
                      ? _foregroundForColor(_selectedColor)
                      : Colors.grey.shade700,
            ),
          ),
        ),
      ),
    ]);
  }

  bool get _usesCustomColor =>
      !_channelPresetColors(
        widget.vm.plotBackground,
      ).any((color) => color.toARGB32() == _selectedColor.toARGB32());

  Future<void> _showCustomColorPicker() async {
    final selectedColor = await _showChannelCustomColorPicker(
      context,
      _selectedColor,
    );
    if (selectedColor != null && mounted) {
      setState(() => _selectedColor = selectedColor);
    }
  }

  Color _foregroundForColor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }

  void _save() {
    final expression = _expressionController.text.trim();
    final error = widget.vm.validateMathExpression(expression);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }

    final display = widget.channel.display.copyWith(
      color: _selectedColor,
      showLine: _showLine,
      pointSize: _pointSize,
      lineWidth: _lineWidth,
      offsetEnabled: widget.channel.display.offsetEnabled,
      yOffset: widget.channel.display.yOffset,
      yScale: widget.channel.display.yScale,
    );
    widget.vm.configureMathChannel(widget.channel.index, expression, display);
    Navigator.of(context).pop();
  }
}

List<Color> _channelPresetColors(String background) =>
    ChannelConfig.presetColorsForBackground(background);

Widget _buildTwoRowColorSwatches(List<Widget> swatches) {
  Widget row(List<Widget> children) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );
  }

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      row(swatches.take(8).toList(growable: false)),
      const SizedBox(height: 8),
      row(swatches.skip(8).take(8).toList(growable: false)),
    ],
  );
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
  late DataType _zobowDataType;
  late final TextEditingController _aliasController;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _selectedColor = ChannelConfig.colorForBackground(
      widget.ch.color,
      widget.vm.plotBackground,
    );
    _alias = widget.ch.alias;
    _showLine = widget.ch.showLine;
    _pointSize = widget.ch.pointSize;
    _lineWidth = widget.ch.lineWidth;
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
                  decoration: secondaryDialogFieldDecoration(
                    hintText: AppStrings.plot.aliasHint,
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
                        width: PlotConfiguration.dataTypeDropdownWidth,
                        child: NoAnimDropdown<DataType>(
                          value: _zobowDataType,
                          hint: AppStrings.plot.typeHint,
                          decoration: secondaryDialogFieldDecoration(),
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
                    width: PlotConfiguration.dataTypeDropdownWidth,
                    child: NoAnimDropdown<DataType>(
                      value: _zobowDataType,
                      hint: AppStrings.plot.typeHint,
                      decoration: secondaryDialogFieldDecoration(),
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
    final defaultColor = ChannelConfig.colorForIndex(
      widget.ch.index,
      widget.vm.plotBackground,
    );
    setState(() {
      _selectedColor = defaultColor;
      _alias = '';
      _aliasController.text = '';
      _showLine = true;
      _pointSize = 3.0;
      _lineWidth = 1.5;
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
              (dialogContext) => _PlotFileProgressDialog(
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

  /// 构建颜色选择器（15 个当前背景预设色 + 自选色入口）
  Widget _buildColorPicker() {
    final presetColors = _channelPresetColors(widget.vm.plotBackground);
    final usesCustomColor =
        !presetColors.any(
          (color) => color.toARGB32() == _selectedColor.toARGB32(),
        );
    return _buildTwoRowColorSwatches([
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
                  isSelected ? Border.all(color: Colors.white, width: 2) : null,
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
    ]);
  }

  Future<void> _showCustomColorPicker() async {
    final selectedColor = await _showChannelCustomColorPicker(
      context,
      _selectedColor,
    );
    if (selectedColor != null && mounted) {
      setState(() => _selectedColor = selectedColor);
    }
  }

  Color _foregroundForColor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }
}

Future<Color?> _showChannelCustomColorPicker(
  BuildContext context,
  Color initialColor,
) async {
  var selectedColor = _opaqueColor(initialColor);
  var selectedHsv = HSVColor.fromColor(selectedColor);
  var hasError = false;
  final redController = TextEditingController();
  final greenController = TextEditingController();
  final blueController = TextEditingController();
  final hexController = TextEditingController();

  void syncControllersFromColor(
    Color color, {
    TextEditingController? editingController,
  }) {
    final value = color.toARGB32();
    if (editingController != redController) {
      redController.text = ((value >> 16) & 0xFF).toString();
    }
    if (editingController != greenController) {
      greenController.text = ((value >> 8) & 0xFF).toString();
    }
    if (editingController != blueController) {
      blueController.text = (value & 0xFF).toString();
    }
    if (editingController != hexController) {
      hexController.text = _formatHexColor(color);
    }
  }

  syncControllersFromColor(selectedColor);
  final result = await showDialog<Color>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          void setColor(
            Color color, {
            TextEditingController? editingController,
          }) {
            selectedColor = _opaqueColor(color);
            selectedHsv = HSVColor.fromColor(selectedColor);
            hasError = false;
            syncControllersFromColor(
              selectedColor,
              editingController: editingController,
            );
          }

          void updateFromRgb(TextEditingController editingController) {
            final r = int.tryParse(redController.text);
            final g = int.tryParse(greenController.text);
            final b = int.tryParse(blueController.text);
            if (!_isRgbByte(r) || !_isRgbByte(g) || !_isRgbByte(b)) {
              setDialogState(() => hasError = true);
              return;
            }
            setDialogState(() {
              setColor(
                Color.fromARGB(255, r!, g!, b!),
                editingController: editingController,
              );
            });
          }

          void updateFromHex(String value) {
            final parsed = _parseHexColor(value);
            if (parsed == null) {
              setDialogState(() => hasError = value.trim().isNotEmpty);
              return;
            }
            setDialogState(() {
              setColor(parsed, editingController: hexController);
            });
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.customColor),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.plot.customColorPreview,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SaturationValuePalette(
                    hsvColor: selectedHsv,
                    onChanged: (saturation, value) {
                      setDialogState(() {
                        setColor(
                          selectedHsv
                              .withSaturation(saturation)
                              .withValue(value)
                              .toColor(),
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  _HuePalette(
                    hue: selectedHsv.hue,
                    onChanged: (hue) {
                      setDialogState(() {
                        setColor(selectedHsv.withHue(hue).toColor());
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.redChannel,
                          controller: redController,
                          onChanged: () => updateFromRgb(redController),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.greenChannel,
                          controller: greenController,
                          onChanged: () => updateFromRgb(greenController),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.blueChannel,
                          controller: blueController,
                          onChanged: () => updateFromRgb(blueController),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: hexController,
                    decoration: secondaryDialogFieldDecoration(
                      labelText: AppStrings.plot.hexColor,
                      hintText: AppStrings.plot.hexColorHint,
                    ).copyWith(
                      errorText:
                          hasError ? AppStrings.plot.colorInputInvalid : null,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[#0-9a-fA-F]'),
                      ),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    textCapitalization: TextCapitalization.characters,
                    onChanged: updateFromHex,
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
                onPressed:
                    hasError
                        ? null
                        : () => Navigator.pop(context, selectedColor),
                child: Text(AppStrings.common.confirm),
              ),
            ],
          );
        },
      );
    },
  );

  redController.dispose();
  greenController.dispose();
  blueController.dispose();
  hexController.dispose();
  return result;
}

class _SaturationValuePalette extends StatelessWidget {
  final HSVColor hsvColor;
  final void Function(double saturation, double value) onChanged;

  const _SaturationValuePalette({
    required this.hsvColor,
    required this.onChanged,
  });

  void _update(Offset position, Size size) {
    final saturation = (position.dx / size.width).clamp(0.0, 1.0);
    final value = 1 - (position.dy / size.height).clamp(0.0, 1.0);
    onChanged(saturation, value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 150);
        return GestureDetector(
          key: const ValueKey('channel-color-palette'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _update(details.localPosition, size),
          onPanStart: (details) => _update(details.localPosition, size),
          onPanUpdate: (details) => _update(details.localPosition, size),
          child: CustomPaint(
            size: size,
            painter: _SaturationValuePainter(hsvColor),
          ),
        );
      },
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  final HSVColor hsvColor;

  const _SaturationValuePainter(this.hsvColor);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = const Radius.circular(4);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white,
            HSVColor.fromAHSV(1, hsvColor.hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.grey.shade500,
    );

    final center = Offset(
      hsvColor.saturation * size.width,
      (1 - hsvColor.value) * size.height,
    );
    canvas.drawCircle(
      center,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) =>
      oldDelegate.hsvColor != hsvColor;
}

class _HuePalette extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HuePalette({required this.hue, required this.onChanged});

  void _update(double dx, double width) {
    onChanged((dx / width).clamp(0.0, 1.0) * 360);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 18);
        return GestureDetector(
          key: const ValueKey('channel-color-hue'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _update(details.localPosition.dx, size.width),
          onPanStart:
              (details) => _update(details.localPosition.dx, size.width),
          onPanUpdate:
              (details) => _update(details.localPosition.dx, size.width),
          child: CustomPaint(size: size, painter: _HuePainter(hue)),
        );
      },
    );
  }
}

class _HuePainter extends CustomPainter {
  final double hue;

  const _HuePainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = const Radius.circular(4);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    canvas.restore();

    final x = (hue / 360) * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height / 2),
          width: 5,
          height: 22,
        ),
        const Radius.circular(2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height / 2),
          width: 7,
          height: 24,
        ),
        const Radius.circular(3),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => oldDelegate.hue != hue;
}

class _ColorNumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;

  const _ColorNumberField({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: secondaryDialogFieldDecoration(labelText: label),
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(3),
      ],
      onChanged: (_) => onChanged(),
    );
  }
}

bool _isRgbByte(int? value) => value != null && value >= 0 && value <= 255;

Color _opaqueColor(Color color) {
  final value = color.toARGB32();
  return Color.fromARGB(
    255,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  );
}

String _formatHexColor(Color color) {
  final value = color.toARGB32() & 0xFFFFFF;
  return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? _parseHexColor(String text) {
  final raw = text.trim();
  final hex = raw.startsWith('#') ? raw.substring(1) : raw;
  if (hex.length != 6 || !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
    return null;
  }
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}
