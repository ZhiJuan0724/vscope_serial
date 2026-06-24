part of '../plot_viewmodel.dart';

/// PlotViewModel 的数据导入导出能力，包含 CSV、BIN 和旧版 DAT 格式。
extension PlotViewModelImportExport on PlotViewModel {
  // ========== 导出 ==========
  /// 导出数据到 CSV 文件
  ///
  /// [selectedPath] 为 null 时，自动保存到可执行文件目录下的 exports 文件夹。
  /// 返回实际保存的文件路径，失败返回 null。
  Future<String?> exportToCsv(String? selectedPath) async {
    try {
      if (_nextIndex == 0) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }

      String path;
      if (selectedPath != null) {
        path = selectedPath;
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.csv';
      }
      final file = File(path);

      // 构建 CSV 内容
      final buffer = StringBuffer();

      // 表头: x,y1,y2,...
      final maxChannels = _exportChannelCount;
      buffer.writeln(
        '# vscope_plot_meta=${jsonEncode(_buildExportMetadata(maxChannels))}',
      );
      buffer.write('x');
      for (int i = 0; i < maxChannels; i++) {
        buffer.write(',y${i + 1}');
      }
      buffer.writeln();

      // 数据行。所有协议导出历史全量数据；Zobow 从原始帧按需解析。
      if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
        for (
          int packetIndex = 0;
          packetIndex < _zobowRawFrames.packetCount;
          packetIndex++
        ) {
          final values = ZobowParser.decodeFrameValues(
            _zobowRawFrames.readPacket(packetIndex),
            _parserConfig,
          );
          buffer.write(packetIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            buffer.write(values[i].toStringAsFixed(6));
          }
          buffer.writeln();
        }
      } else if (_parserType == ParserType.fixedFrame &&
          _fixedFrameRawFrames.isNotEmpty) {
        for (
          int packetIndex = 0;
          packetIndex < _fixedFrameRawFrames.packetCount;
          packetIndex++
        ) {
          final values = FixedFrameParser.decodeFrameValues(
            _fixedFrameRawFrames.readPacket(packetIndex),
            _parserConfig,
          );
          buffer.write(packetIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            if (i < values.length) {
              buffer.write(values[i].toStringAsFixed(6));
            }
          }
          buffer.writeln();
        }
      } else {
        for (
          int pointIndex = 0;
          pointIndex < _parsedHistory.length;
          pointIndex++
        ) {
          final values = _parsedHistory.valuesAt(pointIndex);
          buffer.write(pointIndex);
          for (int i = 0; i < maxChannels; i++) {
            buffer.write(',');
            if (i < values.length) {
              buffer.write(values[i].toStringAsFixed(6));
            }
          }
          buffer.writeln();
        }
      }

      await file.writeAsString(buffer.toString());
      AppLogger().info('已导出 CSV: $path', category: 'PLOT');
      return path;
    } catch (e) {
      AppLogger().error('CSV 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  Future<String?> exportToBin(String? selectedPath) async {
    try {
      final points = _collectExportPoints();
      if (points.isEmpty) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }

      String path;
      if (selectedPath != null) {
        path = selectedPath;
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.bin';
      }

      final channelCount = _exportChannelCount;
      final payloadLength = points.length * (8 + channelCount * 8);
      final payload = ByteData(payloadLength);
      var offset = 0;
      for (final point in points) {
        payload.setFloat64(offset, point.timestamp, Endian.little);
        offset += 8;
        for (int i = 0; i < channelCount; i++) {
          final value = i < point.values.length ? point.values[i] : 0.0;
          payload.setFloat64(offset, value, Endian.little);
          offset += 8;
        }
      }

      final payloadBytes = payload.buffer.asUint8List();
      final metadataBytes = utf8.encode(
        jsonEncode(_buildExportMetadata(channelCount)),
      );
      final dataBlock =
          BytesBuilder(copy: false)
            ..add(metadataBytes)
            ..add(payloadBytes);
      final dataBlockBytes = dataBlock.takeBytes();
      final checksum = calculateCrc(dataBlockBytes, crc32Polys['CRC-32']!);
      final header = ByteData(28);
      const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
      for (int i = 0; i < magic.length; i++) {
        header.setUint8(i, magic[i]);
      }
      header.setUint16(8, 2, Endian.little);
      header.setUint16(10, channelCount, Endian.little);
      header.setUint32(12, points.length, Endian.little);
      header.setUint32(16, payloadLength, Endian.little);
      header.setUint32(20, checksum, Endian.little);
      header.setUint32(24, metadataBytes.length, Endian.little);

      final builder =
          BytesBuilder(copy: false)
            ..add(header.buffer.asUint8List())
            ..add(dataBlockBytes);
      await File(path).writeAsBytes(builder.takeBytes());
      AppLogger().info('已导出 BIN: $path', category: 'PLOT');
      return path;
    } catch (e) {
      AppLogger().error('BIN 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  int get _exportChannelCount {
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      return _parserConfig.zobowChannelCount;
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return _parserConfig.channelCount;
    }
    return _parsedHistory.maxChannelCount;
  }

  Map<String, dynamic> _buildExportMetadata(int channelCount) {
    final names = List<String>.generate(channelCount, (i) {
      if (i >= channels.length) return 'Ch$i';
      return channels[i].alias.isNotEmpty ? channels[i].alias : 'Ch$i';
    }, growable: false);
    final metadata = <String, dynamic>{'channelNames': names};
    final enabledMathChannels = mathChannels
        .where((channel) => channel.enabled)
        .map((channel) => channel.toJson())
        .toList(growable: false);
    if (enabledMathChannels.isNotEmpty) {
      metadata['mathChannels'] = enabledMathChannels;
    }
    if (_importedChannelAddresses != null) {
      metadata['channelAddresses'] = _importedChannelAddresses!
          .take(channelCount)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (_parserType == ParserType.zobow) {
      metadata['parserType'] = ParserType.zobow.name;
      metadata['zobowChannelIds'] = _parserConfig.zobowChannelIds
          .take(channelCount)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    return metadata;
  }

  List<PlotDataPoint> _collectExportPoints() {
    final points = <PlotDataPoint>[];
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      for (int i = 0; i < _zobowRawFrames.packetCount; i++) {
        points.add(
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: ZobowParser.decodeFrameValues(
              _zobowRawFrames.readPacket(i),
              _parserConfig,
            ),
          ),
        );
      }
      return points;
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      for (int i = 0; i < _fixedFrameRawFrames.packetCount; i++) {
        points.add(
          PlotDataPoint(
            index: i,
            timestamp: i.toDouble(),
            values: FixedFrameParser.decodeFrameValues(
              _fixedFrameRawFrames.readPacket(i),
              _parserConfig,
            ),
          ),
        );
      }
      return points;
    }
    for (int i = 0; i < _parsedHistory.length; i++) {
      points.add(
        PlotDataPoint(
          index: i,
          timestamp: i.toDouble(),
          values: _parsedHistory.valuesAt(i),
        ),
      );
    }
    return points;
  }

  // ========== 导入 ==========
  static const int _importProgressBatchSize = 10000;

  Future<void> _reportImportProgress(
    PlotImportProgressCallback? onProgress,
    String stage,
    int current,
    int total, {
    String? detail,
  }) async {
    if (onProgress == null) {
      await Future<void>.delayed(Duration.zero);
      return;
    }

    onProgress.call(
      PlotImportProgress(
        stage: stage,
        current: current,
        total: total,
        detail: detail,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  /// 从 CSV 文件导入数据
  ///
  /// 支持格式：表头 x,y1,y2,...，最大16通道。
  /// 导入成功后会清空现有数据并替换，返回 null；失败返回错误信息。
  Future<String?> importFromCsv(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 CSV', 0, 0);
      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        return '文件为空';
      }
      await _reportImportProgress(
        onProgress,
        '读取 CSV',
        lines.length,
        lines.length,
      );

      final metadata = <String, dynamic>{};
      var headerLineIndex = 0;
      while (headerLineIndex < lines.length &&
          lines[headerLineIndex].trim().startsWith('#')) {
        final line = lines[headerLineIndex].trim();
        const prefix = '# vscope_plot_meta=';
        if (line.startsWith(prefix)) {
          final decoded = jsonDecode(line.substring(prefix.length));
          if (decoded is Map<String, dynamic>) {
            metadata.addAll(decoded);
          }
        }
        headerLineIndex++;
      }
      if (headerLineIndex >= lines.length) {
        return '缺少 CSV 表头';
      }

      // 解析表头
      final header = lines[headerLineIndex].trim();
      if (!header.toLowerCase().startsWith('x')) {
        return '表头格式错误，第一列应为 x';
      }

      final headerParts = header.split(',');
      final channelCount = headerParts.length - 1; // 减去 x 列
      if (channelCount < 1) {
        return '至少需要 1 个数据列';
      }
      if (channelCount > 16) {
        return '通道数超过限制（最大16通道）';
      }

      // 解析数据行
      final importedPoints = <PlotDataPoint>[];
      final dataLineCount = lines.length - headerLineIndex - 1;
      int index = 0;
      for (int i = headerLineIndex + 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final parts = line.split(',');
        if (parts.length < 2) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final xValue = double.tryParse(parts[0].trim());
        if (xValue == null) {
          if ((i - headerLineIndex) % _importProgressBatchSize == 0) {
            await _reportImportProgress(
              onProgress,
              '解析 CSV',
              i - headerLineIndex - 1,
              dataLineCount,
              detail: '${importedPoints.length} 点',
            );
          }
          continue;
        }

        final values = <double>[];
        for (int c = 1; c < parts.length && c <= channelCount; c++) {
          final v = double.tryParse(parts[c].trim());
          if (v != null) {
            values.add(v);
          } else {
            values.add(0);
          }
        }

        // 如果某行列数不足，补零
        while (values.length < channelCount) {
          values.add(0);
        }

        importedPoints.add(
          PlotDataPoint(index: index, timestamp: xValue, values: values),
        );
        index++;

        if (index % _importProgressBatchSize == 0) {
          await _reportImportProgress(
            onProgress,
            '解析 CSV',
            i - headerLineIndex,
            dataLineCount,
            detail: '$index 点',
          );
        }
      }

      if (importedPoints.isEmpty) {
        return '未找到有效数据行';
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: metadata,
        onProgress: onProgress,
      );

      AppLogger().info(
        'CSV 导入成功: $filePath, ${importedPoints.length} 点, $channelCount 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('CSV 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  Future<String?> importFromBin(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 BIN', 0, 0);
      final bytes = await file.readAsBytes();
      if (bytes.length < 24) {
        return 'BIN 文件头不完整';
      }
      await _reportImportProgress(
        onProgress,
        '读取 BIN',
        bytes.length,
        bytes.length,
        detail: '${bytes.length} 字节',
      );

      const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
      for (int i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) {
          return 'BIN 文件标识错误';
        }
      }

      final header = ByteData.sublistView(bytes, 0, 24);
      final version = header.getUint16(8, Endian.little);
      final channelCount = header.getUint16(10, Endian.little);
      final pointCount = header.getUint32(12, Endian.little);
      final payloadLength = header.getUint32(16, Endian.little);
      final expectedChecksum = header.getUint32(20, Endian.little);

      if (version != 1 && version != 2) return '不支持的 BIN 版本: $version';
      if (channelCount < 1 || channelCount > 16) return '通道数无效';
      final headerLength = version == 2 ? 28 : 24;
      if (bytes.length < headerLength) return 'BIN 文件头不完整';
      final metadataLength =
          version == 2
              ? ByteData.sublistView(bytes, 24, 28).getUint32(0, Endian.little)
              : 0;
      if (bytes.length != headerLength + metadataLength + payloadLength) {
        return 'BIN 文件长度不匹配';
      }

      final dataBlock = Uint8List.sublistView(bytes, headerLength);
      await _reportImportProgress(onProgress, '校验 BIN', 0, payloadLength);
      final actualChecksum = calculateCrc(dataBlock, crc32Polys['CRC-32']!);
      if (actualChecksum != expectedChecksum) {
        return 'BIN 校验失败';
      }
      await _reportImportProgress(
        onProgress,
        '校验 BIN',
        payloadLength,
        payloadLength,
      );

      final metadata = <String, dynamic>{};
      if (metadataLength > 0) {
        final decoded = jsonDecode(
          utf8.decode(Uint8List.sublistView(dataBlock, 0, metadataLength)),
        );
        if (decoded is Map<String, dynamic>) {
          metadata.addAll(decoded);
        }
      }

      final payload = Uint8List.sublistView(dataBlock, metadataLength);

      final rowLength = 8 + channelCount * 8;
      if (payloadLength != pointCount * rowLength) {
        return 'BIN 数据长度不匹配';
      }

      final data = ByteData.sublistView(payload);
      final importedPoints = <PlotDataPoint>[];
      var offset = 0;
      for (int i = 0; i < pointCount; i++) {
        final x = data.getFloat64(offset, Endian.little);
        offset += 8;
        final values = <double>[];
        for (int c = 0; c < channelCount; c++) {
          values.add(data.getFloat64(offset, Endian.little));
          offset += 8;
        }
        importedPoints.add(
          PlotDataPoint(index: i, timestamp: x, values: values),
        );
        if ((i + 1) % _importProgressBatchSize == 0) {
          await _reportImportProgress(
            onProgress,
            '解析 BIN',
            i + 1,
            pointCount,
            detail: '${i + 1} 点',
          );
        }
      }

      if (importedPoints.isEmpty) {
        return '未找到有效数据行';
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: metadata,
        onProgress: onProgress,
      );
      AppLogger().info(
        'BIN 导入成功: $filePath, ${importedPoints.length} 点, $channelCount 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('BIN 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  /// 导入旧版 VisualScope 应用导出的数据。
  ///
  /// 旧格式存储四个独立的小端 int16 通道块。
  /// 每个通道前 50,000 个样本是保留历史区，不属于用户可见采集数据。
  Future<String?> importFromLegacyDat(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      await _reportImportProgress(onProgress, '读取 DAT', 0, 0);
      final bytes = await file.readAsBytes();
      const channelCount = 4;
      const reservedPointCount = 50000;
      const minimumHeaderLength = 0x24;
      if (bytes.length < minimumHeaderLength) {
        return 'DAT 文件头不完整';
      }
      await _reportImportProgress(
        onProgress,
        '读取 DAT',
        bytes.length,
        bytes.length,
        detail: '${bytes.length} 字节',
      );

      final data = ByteData.sublistView(bytes);
      final declaredLength = data.getUint32(0, Endian.little);
      if (declaredLength != bytes.length) {
        return 'DAT 文件长度校验失败';
      }

      final storedPointCount = data.getUint32(0x20, Endian.little);
      if (storedPointCount <= reservedPointCount) {
        return 'DAT 文件没有有效数据';
      }
      final expectedLength = 4 + channelCount * (32 + storedPointCount * 2);
      if (expectedLength != bytes.length) {
        return 'DAT 数据布局不匹配';
      }

      final importedPointCount = storedPointCount - reservedPointCount;
      final addresses = <int>[];
      final channelDataOffsets = <int>[];
      for (int channel = 0; channel < channelCount; channel++) {
        final channelNumber = channel + 1;
        final blockOffset = channel * storedPointCount * 2;
        final dataOffset =
            0x04 + channelNumber * 32 + blockOffset + reservedPointCount * 2;
        // 每个通道块都有 32 字节头部。
        // 地址字段位于原始样本数据前 12 字节，类型为 uint32。
        final addressOffset = dataOffset - reservedPointCount * 2 - 12;
        final dataEnd =
            0x04 + channelNumber * 32 + blockOffset + storedPointCount * 2;
        if (addressOffset + 4 > bytes.length ||
            dataOffset > dataEnd ||
            dataEnd > bytes.length) {
          return 'DAT 通道数据不完整';
        }
        addresses.add(data.getUint32(addressOffset, Endian.little));
        channelDataOffsets.add(dataOffset);
      }

      final importedPoints = <PlotDataPoint>[];
      for (int pointIndex = 0; pointIndex < importedPointCount; pointIndex++) {
        final byteOffset = pointIndex * 2;
        importedPoints.add(
          PlotDataPoint(
            index: pointIndex,
            timestamp: pointIndex.toDouble(),
            values: [
              for (final offset in channelDataOffsets)
                data.getInt16(offset + byteOffset, Endian.little).toDouble(),
            ],
          ),
        );
        if ((pointIndex + 1) % _importProgressBatchSize == 0 ||
            pointIndex + 1 == importedPointCount) {
          await _reportImportProgress(
            onProgress,
            '解析 DAT',
            pointIndex + 1,
            importedPointCount,
            detail: '${pointIndex + 1} 点',
          );
        }
      }

      await _replaceImportedPoints(
        importedPoints,
        channelCount,
        metadata: {'channelAddresses': addresses},
        onProgress: onProgress,
      );
      AppLogger().info(
        '旧版 DAT 导入成功: $filePath, $importedPointCount 点, 地址=${addresses.map((address) => '0x${address.toRadixString(16).toUpperCase()}').join(',')}',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('旧版 DAT 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  Future<void> _replaceImportedPoints(
    List<PlotDataPoint> importedPoints,
    int channelCount, {
    Map<String, dynamic>? metadata,
    PlotImportProgressCallback? onProgress,
  }) async {
    _dataPoints.clear();
    _parsedHistory.clear();
    _lodIndex.clear();
    _zobowRawFrames.clear();
    _fixedFrameRawFrames.clear();
    _importedChannelAddresses = null;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (int i = 0; i < importedPoints.length; i++) {
      final point = importedPoints[i];
      _parsedHistory.add(point.values);
      _lodIndex.add(point.index, point.values);
      for (final value in point.values) {
        if (value < minY) minY = value;
        if (value > maxY) maxY = value;
      }
      if ((i + 1) % _importProgressBatchSize == 0 ||
          i + 1 == importedPoints.length) {
        await _reportImportProgress(
          onProgress,
          '建立绘图索引',
          i + 1,
          importedPoints.length,
          detail: '${i + 1} 点',
        );
      }
    }
    _nextIndex = importedPoints.length;
    _activeChannelCount = channelCount;
    _startTime = null;
    _applyImportedMetadata(metadata, channelCount);

    final visibleCount =
        importedPoints.length.clamp(0, _maxVisiblePoints).toInt();
    final visibleStart = importedPoints.length - visibleCount;
    viewport = PlotViewport(
      xMin: visibleStart.toDouble(),
      xMax: importedPoints.length.toDouble(),
      yMin: minY == double.infinity ? 0 : minY,
      yMax: maxY == double.negativeInfinity ? 1 : maxY,
    );
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      0,
      visibleCount,
      detail: '$visibleCount 点',
    );
    _rebuildParsedWindow(visibleStart, visibleCount);
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      visibleCount,
      visibleCount,
      detail: '$visibleCount 点',
    );
    _viewportHistory.clear();

    _resetCursorPositions();

    _notifyLater();
  }

  void _applyImportedMetadata(
    Map<String, dynamic>? metadata,
    int channelCount,
  ) {
    if (metadata == null || metadata.isEmpty) return;

    final names = metadata['channelNames'];
    if (names is List) {
      for (
        int i = 0;
        i < names.length && i < channelCount && i < channels.length;
        i++
      ) {
        final name = names[i];
        if (name is String && name.isNotEmpty) {
          channels[i].alias = name == 'Ch$i' ? '' : name;
        }
      }
    }

    final addresses = metadata['channelAddresses'];
    if (addresses is List) {
      _importedChannelAddresses = _applyChannelAddresses(
        addresses,
        channelCount,
      );
    }

    final ids = metadata['zobowChannelIds'];
    if (metadata['parserType'] == ParserType.zobow.name && ids is List) {
      _parserType = ParserType.zobow;
      _parserConfig.type = ParserType.zobow;
      _parserConfig.channelCount =
          channelCount >= ParserConfig.maxZobowChannelCount
              ? ParserConfig.maxZobowChannelCount
              : ParserConfig.minZobowChannelCount;
      _applyChannelAddresses(ids, _parserConfig.zobowChannelCount);
      AppSettings().parserType = ParserType.zobow.name;
      _saveSettings();
    }

    final importedMathChannels = metadata['mathChannels'];
    if (importedMathChannels is List) {
      _replaceMathChannels(
        MathChannelConfig.normalizeList(importedMathChannels),
      );
    }
  }

  List<int> _applyChannelAddresses(List<dynamic> values, int channelCount) {
    final addresses = <int>[];
    for (
      int i = 0;
      i < values.length &&
          i < channelCount &&
          i < _parserConfig.zobowChannelIds.length;
      i++
    ) {
      final value = values[i];
      final address = switch (value) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(
          value.replaceAll('0x', '').replaceAll('0X', ''),
          radix: 16,
        ),
        _ => null,
      };
      if (address != null) {
        final normalized = address & 0xFFFFFFFF;
        _parserConfig.zobowChannelIds[i] = normalized;
        addresses.add(normalized);
      }
    }
    return addresses;
  }
}
