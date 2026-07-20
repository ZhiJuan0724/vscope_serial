part of '../plot_page.dart';

/// 绘图页面的解析器配置弹窗，负责维护弹窗内的临时配置副本。
class _ParserConfigDialog extends StatefulWidget {
  final PlotViewModel vm;

  const _ParserConfigDialog({required this.vm});

  @override
  State<_ParserConfigDialog> createState() => _ParserConfigDialogState();
}

/// [_ParserConfigDialog] 的状态类
class _ParserConfigDialogState extends State<_ParserConfigDialog> {
  /// 解析器配置的本地副本（确定后才同步到 ViewModel）
  late ParserConfig _config;

  /// FireWater 通道数输入控制器
  late final TextEditingController _fireWaterController;

  /// 固定帧通道数输入控制器
  late final TextEditingController _fixedFrameController;

  late final TextEditingController _fixedFrameHeaderController;
  late final TextEditingController _fixedFrameTailController;

  late final TextEditingController _justFloatController;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _config = widget.vm.parserConfig.copyWith();
    _fireWaterController = TextEditingController(
      text: _config.fireWaterChannelCount.toString(),
    );
    _fixedFrameController = TextEditingController(
      text: _config.channelCount.toString(),
    );
    _fixedFrameHeaderController = TextEditingController(
      text: _formatHexBytes(
        _config.frameHeader.take(_config.frameHeaderLength).toList(),
      ),
    );
    _fixedFrameTailController = TextEditingController(
      text: _formatHexBytes(_config.frameTail ?? const []),
    );
    _justFloatController = TextEditingController(
      text: _config.channelCount.toString(),
    );
    if (_config.hasChecksum) {
      _setCrcType(
        _isCrcChecksum(_config.checksumType)
            ? _config.checksumType
            : ChecksumType.crc16,
      );
    }
  }

  @override
  void dispose() {
    _fireWaterController.dispose();
    _fixedFrameController.dispose();
    _fixedFrameHeaderController.dispose();
    _fixedFrameTailController.dispose();
    _justFloatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      title: Text(AppStrings.plot.parserConfigTitle),
      content: SizedBox(width: 300, child: _buildConfigContent()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.common.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (_config.type == ParserType.fixedFrame) {
              final error = _config.fixedFrameValidationError;
              if (error != null) {
                setState(() => _validationError = error);
                return;
              }
            }
            widget.vm.updateParserConfig(_config);
            Navigator.of(context).pop();
          },
          child: Text(AppStrings.common.confirm),
        ),
      ],
    );
  }

  /// 构建 FireWater 解析器配置界面
  Widget _buildFireWaterConfig() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'FireWater 格式:',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('以 "," 分割数据'),
        const Text('所有数据默认 double 类型'),
        const Text('以 "\\n" 结尾'),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('${AppStrings.plot.channelCount}:'),
            const SizedBox(width: 8),
            SizedBox(
              width: kSecondaryDialogFieldWidth,
              child: TextField(
                controller: _fireWaterController,
                keyboardType: TextInputType.number,
                decoration: secondaryDialogFieldDecoration(),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null && count >= 0 && count <= 16) {
                    setState(() => _config.fireWaterChannelCount = count);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(
              AppStrings.plot.autoDetectHint,
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ],
    );
  }

  /// 根据当前解析器类型构建对应的配置界面
  Widget _buildConfigContent() {
    switch (widget.vm.parserType) {
      case ParserType.fireWater:
        return _buildFireWaterConfig();
      case ParserType.fixedFrame:
        return _buildFixedFrameConfig();
      case ParserType.zobow:
        return _buildZobowConfig();
      case ParserType.justFloat:
        return _buildJustFloatConfig();
    }
  }

  Widget _buildJustFloatConfig() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'JustFloat 格式:',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('小端 float32 数组'),
        const Text('帧尾: 00 00 80 7F'),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('${AppStrings.plot.channelCount}:'),
            const SizedBox(width: 8),
            SizedBox(
              width: kSecondaryDialogFieldWidth,
              child: TextField(
                controller: _justFloatController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: secondaryDialogFieldDecoration(),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null && count >= 0 && count <= 16) {
                    setState(() => _config.channelCount = count);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(
              AppStrings.plot.autoDetectHint,
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建 众邦电控解析器配置界面
  ///
  /// 众邦通道号和数据类型在通道面板中维护，此处只选择通道数。
  Widget _buildZobowConfig() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.plot.zobowConfig,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              '${AppStrings.plot.channelCount}:',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: kSecondaryDialogFieldWidth,
              child: NoAnimDropdown<int>(
                value: _config.zobowChannelCount,
                hint: AppStrings.plot.channelCountHint,
                decoration: secondaryDialogFieldDecoration(),
                items:
                    const [4, 8].map((count) {
                      return DropdownMenuItem(
                        value: count,
                        child: Text('$count 通道'),
                      );
                    }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _config.channelCount = value);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.plot.zobowFrameDescription(_config.zobowChannelCount * 2),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.plot.zobowChannelPanelHelp,
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  /// 构建固定帧解析器配置界面
  ///
  /// 包含帧头长度、帧头值、数据类型、通道数设置。
  Widget _buildFixedFrameConfig() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.plot.frameHeaderSettings,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(AppStrings.plot.enableFrameHeader),
            value: _config.hasFrameHeader,
            onChanged: (value) {
              setState(() {
                _config.hasFrameHeader = value ?? false;
                if (_config.hasFrameHeader && _config.frameHeader.isEmpty) {
                  _config.frameHeader = [0xAA, 0x55];
                  _config.frameHeaderLength = 2;
                  _fixedFrameHeaderController.text = _formatHexBytes(
                    _config.frameHeader,
                  );
                }
              });
            },
          ),
          if (_config.hasFrameHeader)
            TextField(
              controller: _fixedFrameHeaderController,
              decoration: secondaryDialogFieldDecoration(
                labelText: AppStrings.plot.frameHeaderBytes,
                hintText: AppStrings.plot.frameHeaderExample,
              ),
              inputFormatters: const [_HexByteInputFormatter()],
              onChanged: (value) {
                final bytes = _parseHexBytes(value);
                if (bytes != null) {
                  setState(() {
                    _config.frameHeader = bytes;
                    _config.frameHeaderLength = bytes.length;
                  });
                }
              },
            ),
          const SizedBox(height: 16),
          Text(
            AppStrings.plot.dataSettings,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: PlotConfiguration.fixedFrameConfigLabelWidth,
                child: Text(AppStrings.plot.channelType, softWrap: false),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: PlotConfiguration.dataTypeDropdownWidth,
                child: NoAnimDropdown<bool>(
                  value: _config.fixedFrameUniformDataType,
                  hint: AppStrings.plot.channelTypeModeHint,
                  decoration: secondaryDialogFieldDecoration(),
                  items: [
                    DropdownMenuItem(
                      value: true,
                      child: Text(AppStrings.plot.uniform),
                    ),
                    DropdownMenuItem(
                      value: false,
                      child: Text(AppStrings.plot.nonUniform),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _config.fixedFrameUniformDataType = value;
                        if (!value) {
                          _config.fixedFrameChannelTypes = List.generate(
                            SendProtocolConfig.maxChannelCount,
                            (index) =>
                                index < widget.vm.channels.length
                                    ? widget.vm.channels[index].dataType
                                    : _config.dataType,
                          );
                        }
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          if (_config.fixedFrameUniformDataType) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: PlotConfiguration.fixedFrameConfigLabelWidth,
                  child: Text('${AppStrings.plot.dataType}:', softWrap: false),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: PlotConfiguration.dataTypeDropdownWidth,
                  child: NoAnimDropdown<DataType>(
                    value: _config.dataType,
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
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _config.dataType = value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              AppStrings.plot.selectDataTypeInChannelList,
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text('${AppStrings.plot.channelCount}:'),
              const SizedBox(width: 8),
              SizedBox(
                width: kSecondaryDialogFieldWidth,
                child: TextField(
                  controller: _fixedFrameController,
                  keyboardType: TextInputType.number,
                  decoration: secondaryDialogFieldDecoration(),
                  onChanged: (value) {
                    final count = int.tryParse(value);
                    if (count != null && count >= 1 && count <= 16) {
                      setState(() => _config.channelCount = count);
                    }
                  },
                ),
              ),
            ],
          ),
          if (_validationError != null) ...[
            const SizedBox(height: 8),
            Text(
              _validationError!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            AppStrings.plot.frameTailSettings,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(AppStrings.plot.enableFrameTail),
            value: _config.hasFrameTail,
            onChanged: (value) {
              setState(() {
                _config.hasFrameTail = value ?? false;
                if (_config.hasFrameTail &&
                    (_config.frameTail == null || _config.frameTail!.isEmpty)) {
                  _config.frameTail = [0x0D, 0x0A];
                  _fixedFrameTailController.text = _formatHexBytes(
                    _config.frameTail!,
                  );
                }
              });
            },
          ),
          if (_config.hasFrameTail)
            TextField(
              controller: _fixedFrameTailController,
              decoration: secondaryDialogFieldDecoration(
                labelText: AppStrings.plot.frameTailBytes,
                hintText: AppStrings.plot.frameTailExample,
              ),
              inputFormatters: const [_HexByteInputFormatter()],
              onChanged: (value) {
                final bytes = _parseHexBytes(value);
                if (bytes != null) {
                  setState(() => _config.frameTail = bytes);
                }
              },
            ),
          const SizedBox(height: 16),
          Text(
            AppStrings.plot.crcSettings,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(AppStrings.plot.enableCrc),
            value: _config.hasChecksum,
            onChanged: (value) {
              setState(() {
                _config.hasChecksum = value ?? false;
                if (_config.hasChecksum &&
                    !_isCrcChecksum(_config.checksumType)) {
                  _setCrcType(ChecksumType.crc16);
                }
              });
            },
          ),
          if (_config.hasChecksum) ...[
            NoAnimDropdown<ChecksumType>(
              value: _config.checksumType,
              hint: AppStrings.plot.crcType,
              decoration: secondaryDialogFieldDecoration(),
              items:
                  const [
                    ChecksumType.crc8,
                    ChecksumType.crc16,
                    ChecksumType.crc32,
                  ].map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.label),
                    );
                  }).toList(),
              onChanged: (value) {
                if (value != null) setState(() => _setCrcType(value));
              },
            ),
            const SizedBox(height: 8),
            NoAnimDropdown<String>(
              value: _config.crcPolynomialName,
              hint: AppStrings.plot.crcPolynomial,
              decoration: secondaryDialogFieldDecoration(),
              items:
                  _crcPolynomialNames
                      .map(
                        (name) => DropdownMenuItem(
                          value: name,
                          child: Text(
                            name,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _config.crcPolynomialName = value);
                }
              },
            ),
            const SizedBox(height: 8),
            NoAnimDropdown<ChecksumPosition>(
              value: _config.checksumPosition,
              hint: AppStrings.plot.crcPosition,
              decoration: secondaryDialogFieldDecoration(),
              items:
                  ChecksumPosition.values
                      .map(
                        (position) => DropdownMenuItem(
                          value: position,
                          child: Text(
                            AppStrings.plot.crcPositionLabel(position.label),
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _config.checksumPosition = value);
                }
              },
            ),
            const SizedBox(height: 8),
            NoAnimDropdown<ChecksumEndian>(
              value: _config.checksumEndian,
              hint: AppStrings.plot.crcEndian,
              decoration: secondaryDialogFieldDecoration(),
              items:
                  ChecksumEndian.values
                      .map(
                        (endian) => DropdownMenuItem(
                          value: endian,
                          child: Text(
                            AppStrings.plot.crcEndianLabel(endian.label),
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _config.checksumEndian = value);
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  bool _isCrcChecksum(ChecksumType type) {
    return type == ChecksumType.crc8 ||
        type == ChecksumType.crc16 ||
        type == ChecksumType.crc32;
  }

  List<String> get _crcPolynomialNames {
    final type = switch (_config.checksumType) {
      ChecksumType.crc8 => CrcType.crc8,
      ChecksumType.crc32 => CrcType.crc32,
      _ => CrcType.crc16,
    };
    return getPolysByType(type).keys.toList();
  }

  void _setCrcType(ChecksumType type) {
    _config.checksumType = type;
    _config.checksumBytes = _config.effectiveChecksumBytes;
    final names = _crcPolynomialNames;
    if (!names.contains(_config.crcPolynomialName)) {
      _config.crcPolynomialName = names.first;
    }
  }

  String _formatHexBytes(List<int> bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
  }

  List<int>? _parseHexBytes(String value) {
    final hex = value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (hex.isEmpty) return const [];
    if (hex.length.isOdd) return null;
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null || byte < 0 || byte > 0xFF) return null;
      bytes.add(byte);
    }
    return bytes;
  }
}

/// 帧头、帧尾等字节输入的格式化器，统一将输入限制为两位十六进制字节。
class _HexByteInputFormatter extends TextInputFormatter {
  const _HexByteInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final formatted = <String>[];
    for (var i = 0; i < raw.length; i += 2) {
      final end = math.min(i + 2, raw.length);
      formatted.add(raw.substring(i, end).toUpperCase());
    }
    final text = formatted.join(' ');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
