part of '../plot_viewmodel.dart';

class _PlotExportCancelled implements Exception {}

class _PlotExportColumn {
  final int channelIndex;
  final String name;

  const _PlotExportColumn({required this.channelIndex, required this.name});

  bool get isMath => channelIndex >= PlotConfiguration.rawChannelCount;
}

/// PlotViewModel 的数据导入导出能力，包含 CSV、BIN 和旧版 DAT 格式。
extension PlotViewModelImportExport on PlotViewModel {
  static const int _binMaxUint32 = 0xFFFFFFFF;
  static const int _binExportBatchSize = 65536;
  static const int _csvExportBatchSize = 8192;
  static const int _maxExportChannelCount = PlotConfiguration.totalChannelCount;

  List<ChannelConfig> get exportCandidateChannels {
    final rawCount = _exportChannelCount.clamp(0, channels.length).toInt();
    return [
      ...channels.take(rawCount),
      for (final channel in mathChannels)
        if (channel.enabled) channel.display,
    ];
  }

  static String _ensureExportExtension(String path, String extension) {
    final suffix = '.${extension.toLowerCase()}';
    return path.toLowerCase().endsWith(suffix) ? path : '$path$suffix';
  }

  // ========== 导出 ==========
  /// 导出数据到 CSV 文件
  ///
  /// [selectedPath] 为 null 时，自动保存到可执行文件目录下的 exports 文件夹。
  /// 返回实际保存的文件路径，失败返回 null。
  Future<String?> exportToCsv(
    String? selectedPath, {
    int? startIndex,
    int? endIndex,
    List<int>? channelIndices,
    PlotExportProgressCallback? onProgress,
    PlotExportCancelToken? cancelToken,
  }) async {
    IOSink? sink;
    String? path;
    try {
      final exportRange = _normalizeExportRange(startIndex, endIndex);
      if (exportRange == null) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }
      final exportColumns = _normalizeExportColumns(channelIndices);
      if (exportColumns == null) return null;

      if (selectedPath != null) {
        path = _ensureExportExtension(selectedPath, 'csv');
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.csv';
      }
      final sourceStart = exportRange.$1;
      final pointCount = exportRange.$2;
      final file = File(path);
      sink = file.openWrite();
      final startedAt = DateTime.now();
      var writtenBytes = 0;
      final header = StringBuffer('x');
      for (final column in exportColumns) {
        header.write(
          column.isMath
              ? ',${mathChannels[column.channelIndex - PlotConfiguration.rawChannelCount].expression}'
              : ',Ch${column.channelIndex}',
        );
      }
      sink.writeln(header);
      writtenBytes += header.length + 1;

      for (
        var batchStart = 0;
        batchStart < pointCount;
        batchStart += _csvExportBatchSize
      ) {
        if (cancelToken?.isCancelled ?? false) throw _PlotExportCancelled();
        final batchEnd = math.min(batchStart + _csvExportBatchSize, pointCount);
        final buffer = StringBuffer();
        final decodedCache = <int, List<double>>{};
        for (
          var exportIndex = batchStart;
          exportIndex < batchEnd;
          exportIndex++
        ) {
          final pointIndex = sourceStart + exportIndex;
          buffer.write(exportIndex);
          for (final column in exportColumns) {
            buffer.write(',');
            final value = _exportValueAt(pointIndex, column, decodedCache);
            buffer.write(value.toStringAsFixed(6));
          }
          buffer.writeln();
        }
        final text = buffer.toString();
        writtenBytes += text.length;
        sink.write(text);
        await _reportExportProgress(
          onProgress,
          '写入 CSV',
          batchEnd,
          pointCount,
          bytesWritten: writtenBytes,
          startedAt: startedAt,
          cancelToken: cancelToken,
        );
      }

      await sink.flush();
      await sink.close();
      sink = null;
      AppLogger().info('已导出 CSV: $path', category: 'PLOT');
      return path;
    } on _PlotExportCancelled {
      await sink?.close();
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      AppLogger().info('CSV 导出已取消', category: 'PLOT');
      return null;
    } catch (e) {
      await sink?.close();
      AppLogger().error('CSV 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  Future<String?> exportToBin(
    String? selectedPath, {
    int? startIndex,
    int? endIndex,
    List<int>? channelIndices,
    PlotExportProgressCallback? onProgress,
    PlotExportCancelToken? cancelToken,
  }) async {
    RandomAccessFile? output;
    String? path;
    try {
      final exportRange = _normalizeExportRange(startIndex, endIndex);
      if (exportRange == null) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }
      final sourceStart = exportRange.$1;
      final pointCount = exportRange.$2;
      final exportColumns = _normalizeExportColumns(channelIndices);
      if (exportColumns == null) return null;

      if (selectedPath != null) {
        path = _ensureExportExtension(selectedPath, 'bin');
      } else {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final dir = Directory('${exeDir.path}/exports');
        await dir.create(recursive: true);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        path = '${dir.path}/vscope_plot_$timestamp.bin';
      }

      final channelCount = exportColumns.length;
      final rowLength = 8 + channelCount * 8;
      final payloadLength = pointCount * rowLength;
      if (pointCount > _binMaxUint32 || payloadLength > _binMaxUint32) {
        final payloadGb = payloadLength / 1024 / 1024 / 1024;
        final message =
            'BIN 导出失败：当前 BIN 格式单文件最多支持 4GB 数据，'
            '本次预计 ${payloadGb.toStringAsFixed(2)} GB。请先缩小数据范围或改用分段导出。';
        showStatusMessage(message, duration: const Duration(seconds: 6));
        AppLogger().warning(message, category: 'PLOT');
        return null;
      }
      final metadataBytes = utf8.encode(
        jsonEncode(
          _buildExportMetadata(
            exportColumns,
            sourceStart: sourceStart,
            pointCount: pointCount,
            includeObservations: true,
          ),
        ),
      );
      final crc = CrcCalculator(crc32Polys['CRC-32']!)..add(metadataBytes);
      output = await File(path).open(mode: FileMode.write);
      final startedAt = DateTime.now();
      var writtenBytes = 0;
      await output.writeFrom(Uint8List(28));
      await output.writeFrom(metadataBytes);
      writtenBytes += 28 + metadataBytes.length;

      for (
        var batchStart = 0;
        batchStart < pointCount;
        batchStart += _binExportBatchSize
      ) {
        if (cancelToken?.isCancelled ?? false) throw _PlotExportCancelled();
        final batchEnd = math.min(batchStart + _binExportBatchSize, pointCount);
        final bytes = ByteData((batchEnd - batchStart) * rowLength);
        final decodedCache = <int, List<double>>{};
        var offset = 0;
        for (
          var exportIndex = batchStart;
          exportIndex < batchEnd;
          exportIndex++
        ) {
          final pointIndex = sourceStart + exportIndex;
          bytes.setFloat64(offset, exportIndex.toDouble(), Endian.little);
          offset += 8;
          for (final column in exportColumns) {
            final value = _exportValueAt(pointIndex, column, decodedCache);
            bytes.setFloat64(offset, value, Endian.little);
            offset += 8;
          }
        }
        final chunk = bytes.buffer.asUint8List();
        crc.add(chunk);
        await output.writeFrom(chunk);
        writtenBytes += chunk.length;
        await _reportExportProgress(
          onProgress,
          '写入 BIN',
          batchEnd,
          pointCount,
          bytesWritten: writtenBytes,
          startedAt: startedAt,
          cancelToken: cancelToken,
        );
      }

      final header = ByteData(28);
      const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
      for (int i = 0; i < magic.length; i++) {
        header.setUint8(i, magic[i]);
      }
      header.setUint16(8, 2, Endian.little);
      header.setUint16(10, channelCount, Endian.little);
      header.setUint32(12, pointCount, Endian.little);
      header.setUint32(16, payloadLength, Endian.little);
      header.setUint32(20, crc.digest, Endian.little);
      header.setUint32(24, metadataBytes.length, Endian.little);
      await output.setPosition(0);
      await output.writeFrom(header.buffer.asUint8List());
      await output.flush();
      await output.close();
      output = null;
      AppLogger().info('已导出 BIN: $path', category: 'PLOT');
      return path;
    } on _PlotExportCancelled {
      await output?.close();
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      AppLogger().info('BIN 导出已取消', category: 'PLOT');
      return null;
    } catch (e) {
      await output?.close();
      AppLogger().error('BIN 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  List<_PlotExportColumn>? _normalizeExportColumns(List<int>? channelIndices) {
    final candidates = exportCandidateChannels;
    final byIndex = <int, ChannelConfig>{
      for (final channel in candidates) channel.index: channel,
    };
    final requested =
        channelIndices ?? [for (final channel in candidates) channel.index];
    final unique = <int>[];
    final seen = <int>{};
    for (final index in requested) {
      if (seen.add(index)) unique.add(index);
    }
    if (unique.isEmpty) {
      const message = '导出失败：请至少选择 1 个通道';
      showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    if (unique.length > _maxExportChannelCount) {
      const message =
          '导出失败：当前格式最多支持同时导出 '
          '${PlotConfiguration.totalChannelCount} 个通道';
      showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    for (final index in unique) {
      if (!byIndex.containsKey(index)) {
        final message = '导出失败：通道 $index 不可用';
        showStatusMessage(message, duration: const Duration(seconds: 4));
        AppLogger().warning(message, category: 'PLOT');
        return null;
      }
    }
    return [
      for (final index in unique)
        _PlotExportColumn(channelIndex: index, name: displayChannelName(index)),
    ];
  }

  double _exportValueAt(
    int pointIndex,
    _PlotExportColumn column,
    Map<int, List<double>> decodedCache,
  ) {
    if (!column.isMath) {
      return _exportRawValueAt(pointIndex, column.channelIndex, decodedCache);
    }
    final mathIndex = column.channelIndex - PlotConfiguration.rawChannelCount;
    if (mathIndex < 0 || mathIndex >= mathChannels.length) return double.nan;
    final expression = _compiledMathExpressions[mathIndex];
    if (expression == null) return double.nan;
    return expression.evaluateWithContext(
      MathEvalContext(
        currentIndex: pointIndex,
        pointCount: _exportPointCount,
        valueAt:
            (sourcePointIndex, sourceChannelIndex) => _exportRawValueAt(
              sourcePointIndex,
              sourceChannelIndex,
              decodedCache,
            ),
      ),
    );
  }

  double _exportRawValueAt(
    int pointIndex,
    int channelIndex,
    Map<int, List<double>> decodedCache,
  ) {
    if (pointIndex < 0 || pointIndex >= _exportPointCount || channelIndex < 0) {
      return double.nan;
    }
    if (_exportsParsedHistory) {
      final valueCount = _parsedHistory.valueCountAt(pointIndex);
      return channelIndex < valueCount
          ? _parsedHistory.valueAt(pointIndex, channelIndex)
          : double.nan;
    }
    final values = decodedCache.putIfAbsent(
      pointIndex,
      () => _decodeExportValuesAt(pointIndex),
    );
    return channelIndex < values.length ? values[channelIndex] : double.nan;
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

  int get _exportPointCount {
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      return _zobowRawFrames.packetCount;
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return _fixedFrameRawFrames.packetCount;
    }
    return _parsedHistory.length;
  }

  (int, int)? _normalizeExportRange(int? startIndex, int? endIndex) {
    final total = _exportPointCount;
    if (total <= 0) return null;
    final start = startIndex ?? 0;
    final end = endIndex ?? total - 1;
    if (start < 0 || end < start || end >= total) {
      final message = '导出范围无效：起始点和结束点必须在 0-${total - 1} 内';
      showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    return (start, end - start + 1);
  }

  bool get _exportsParsedHistory =>
      !(_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) &&
      !(_parserType == ParserType.fixedFrame &&
          _fixedFrameRawFrames.isNotEmpty);

  List<double> _decodeExportValuesAt(int pointIndex) {
    if (_parserType == ParserType.zobow && _zobowRawFrames.isNotEmpty) {
      return ZobowParser.decodeFrameValues(
        _zobowRawFrames.readPacket(pointIndex),
        _parserConfig,
      );
    }
    if (_parserType == ParserType.fixedFrame &&
        _fixedFrameRawFrames.isNotEmpty) {
      return FixedFrameParser.decodeFrameValues(
        _fixedFrameRawFrames.readPacket(pointIndex),
        _parserConfig,
      );
    }
    throw StateError('文本历史无需解码');
  }

  Map<String, dynamic> _buildExportMetadata(
    List<_PlotExportColumn> columns, {
    required int sourceStart,
    required int pointCount,
    bool includeObservations = false,
  }) {
    final metadata = <String, dynamic>{
      'channelNames': [for (final column in columns) column.name],
      'exportChannels': [
        for (final column in columns)
          <String, dynamic>{
            'type': column.isMath ? 'math' : 'raw',
            'sourceIndex': column.channelIndex,
            'name': column.name,
            if (column.isMath)
              'expression':
                  mathChannels[column.channelIndex -
                          PlotConfiguration.rawChannelCount]
                      .expression,
          },
      ],
    };
    final rawColumns = columns.takeWhile((column) => !column.isMath).toList();
    final hasOnlyTrailingMath = columns
        .skip(rawColumns.length)
        .every((column) => column.isMath);
    final preservesRawPrefix =
        hasOnlyTrailingMath &&
        rawColumns.indexed.every((entry) => entry.$2.channelIndex == entry.$1);
    final restoresProtocolMetadata =
        preservesRawPrefix &&
        (rawColumns.length == columns.length ||
            rawColumns.length == PlotConfiguration.rawChannelCount);
    if (restoresProtocolMetadata && _importedChannelAddresses != null) {
      metadata['channelAddresses'] = _importedChannelAddresses!
          .take(rawColumns.length)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (restoresProtocolMetadata && _parserType == ParserType.zobow) {
      metadata['parserType'] = ParserType.zobow.name;
      metadata['zobowChannelIds'] = _parserConfig.zobowChannelIds
          .take(rawColumns.length)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (restoresProtocolMetadata &&
        _sendProtocolType == SendProtocolType.rProtocol) {
      metadata['sendProtocolType'] = SendProtocolType.rProtocol.name;
      metadata['rChannelAddresses'] = List<String>.from(
        _sendProtocolConfig.rChannelAddresses,
      );
    }
    if (includeObservations && _observations.isNotEmpty) {
      metadata['observations'] = _observations
          .where(
            (observation) =>
                observation.x >= sourceStart &&
                observation.x < sourceStart + pointCount,
          )
          .map(
            (observation) => <String, dynamic>{
              'x': observation.x - sourceStart,
              if (observation.note.isNotEmpty) 'note': observation.note,
              if (observation.locked) 'locked': true,
            },
          )
          .toList(growable: false);
    }
    return metadata;
  }

  Future<void> _reportExportProgress(
    PlotExportProgressCallback? onProgress,
    String stage,
    int current,
    int total, {
    int? bytesWritten,
    DateTime? startedAt,
    PlotExportCancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw _PlotExportCancelled();
    double? bytesPerSecond;
    if (bytesWritten != null && startedAt != null) {
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (elapsedMs > 0) {
        bytesPerSecond = bytesWritten * 1000.0 / elapsedMs;
      }
    }
    onProgress?.call(
      PlotImportProgress(
        stage: stage,
        current: current,
        total: total,
        bytesPerSecond: bytesPerSecond,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    if (cancelToken?.isCancelled ?? false) throw _PlotExportCancelled();
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
      if (channelCount > PlotConfiguration.totalChannelCount) {
        return '通道数超过限制（最大${PlotConfiguration.totalChannelCount}通道）';
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

      var normalizedPoints = importedPoints;
      var normalizedChannelCount = channelCount;
      if (channelCount > PlotConfiguration.rawChannelCount) {
        final expressions = _csvTrailingMathExpressions(headerParts);
        if (expressions == null) {
          return '超过16列的 CSV 必须按 Ch0..Ch15 加数学表达式列排列';
        }
        normalizedPoints = _takeRawImportColumns(importedPoints);
        normalizedChannelCount = PlotConfiguration.rawChannelCount;
        metadata['mathChannels'] = _mathChannelMetadata(expressions);
      }

      await _replaceImportedPoints(
        normalizedPoints,
        normalizedChannelCount,
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
      if (channelCount < 1 ||
          channelCount > PlotConfiguration.totalChannelCount) {
        return '通道数无效';
      }
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

      var normalizedPoints = importedPoints;
      var normalizedChannelCount = channelCount;
      if (channelCount > PlotConfiguration.rawChannelCount) {
        final expressions = _binTrailingMathExpressions(metadata, channelCount);
        if (expressions == null) {
          return '超过16列的 BIN 缺少完整的普通/数学通道描述';
        }
        normalizedPoints = _takeRawImportColumns(importedPoints);
        normalizedChannelCount = PlotConfiguration.rawChannelCount;
        metadata['mathChannels'] = _mathChannelMetadata(expressions);
      }

      await _replaceImportedPoints(
        normalizedPoints,
        normalizedChannelCount,
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

  List<String>? _csvTrailingMathExpressions(List<String> headerParts) {
    final channelCount = headerParts.length - 1;
    if (channelCount <= PlotConfiguration.rawChannelCount ||
        channelCount > PlotConfiguration.totalChannelCount) {
      return null;
    }
    for (var i = 0; i < PlotConfiguration.rawChannelCount; i++) {
      if (headerParts[i + 1].trim().toLowerCase() != 'ch$i') return null;
    }
    final expressions = <String>[];
    for (final value in headerParts.skip(17)) {
      final expression = value.trim();
      try {
        MathExpression.parse(expression);
      } catch (_) {
        return null;
      }
      expressions.add(expression);
    }
    return expressions;
  }

  List<String>? _binTrailingMathExpressions(
    Map<String, dynamic> metadata,
    int channelCount,
  ) {
    final descriptors = metadata['exportChannels'];
    if (descriptors is! List || descriptors.length != channelCount) return null;
    for (var i = 0; i < PlotConfiguration.rawChannelCount; i++) {
      final descriptor = descriptors[i];
      if (descriptor is! Map ||
          descriptor['type'] != 'raw' ||
          (descriptor['sourceIndex'] as num?)?.toInt() != i) {
        return null;
      }
    }
    final expressions = <String>[];
    for (final descriptor in descriptors.skip(
      PlotConfiguration.rawChannelCount,
    )) {
      if (descriptor is! Map || descriptor['type'] != 'math') return null;
      final expression = descriptor['expression'];
      if (expression is! String) return null;
      try {
        MathExpression.parse(expression);
      } catch (_) {
        return null;
      }
      expressions.add(expression);
    }
    return expressions;
  }

  List<Map<String, dynamic>> _mathChannelMetadata(List<String> expressions) {
    return [
      for (var i = 0; i < expressions.length; i++)
        <String, dynamic>{
          'index': i,
          'enabled': true,
          'expression': expressions[i],
        },
    ];
  }

  List<PlotDataPoint> _takeRawImportColumns(List<PlotDataPoint> points) {
    return [
      for (final point in points)
        PlotDataPoint(
          index: point.index,
          timestamp: point.timestamp,
          values: point.values
              .take(PlotConfiguration.rawChannelCount)
              .toList(growable: false),
        ),
    ];
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
        if (!value.isFinite) continue;
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
    _applyImportedObservations(metadata);

    _notifyLater();
  }

  void _applyImportedMetadata(
    Map<String, dynamic>? metadata,
    int channelCount,
  ) {
    final importedMathChannels = metadata?['mathChannels'];
    _replaceMathChannels(
      importedMathChannels is List
          ? MathChannelConfig.normalizeList(importedMathChannels)
          : MathChannelConfig.createDefaults(),
    );
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

    final rAddresses = metadata['rChannelAddresses'];
    if (metadata['sendProtocolType'] == SendProtocolType.rProtocol.name &&
        rAddresses is List) {
      final restoredAddresses = List<String>.filled(
        SendProtocolConfig.maxChannelCount,
        '',
      );
      for (
        var i = 0;
        i < rAddresses.length && i < restoredAddresses.length;
        i++
      ) {
        final address = rAddresses[i];
        if (address is String) restoredAddresses[i] = address.trim();
      }
      _sendProtocolType = SendProtocolType.rProtocol;
      _sendProtocolConfig
        ..type = SendProtocolType.rProtocol
        ..source = ProtocolSource.builtIn
        ..customProtocolId = null
        ..rChannelAddresses = restoredAddresses;
      _saveSettings();
    }
  }

  void _applyImportedObservations(Map<String, dynamic>? metadata) {
    final values = metadata?['observations'];
    if (values is! List) return;
    for (final item in values) {
      if (_observations.length >= PlotViewModel.maxObservationCount) break;
      if (item is! Map) continue;
      final xValue = item['x'];
      final x = xValue is num ? xValue.toDouble() : null;
      if (x == null || !x.isFinite || !canJumpToXIndex(x.round())) continue;
      final noteValue = item['note'];
      _observations.add(
        PlotObservation(
          cursor: _buildImportedObservationCursorAtX(x),
          note: noteValue is String ? noteValue : '',
          locked: item['locked'] == true,
        ),
      );
    }
  }

  CursorState _buildImportedObservationCursorAtX(double x) {
    final index = x.round();
    if ((x - index).abs() > 0.000001 || !canJumpToXIndex(index)) {
      return CursorState(x: x, hasData: false);
    }
    final valueCount = _parsedHistory.valueCountAt(index);
    if (valueCount <= 0) return CursorState(x: x, hasData: false);
    return CursorState(
      x: x,
      channelValues: [
        for (var channel = 0; channel < valueCount; channel++)
          _parsedHistory.valueAt(index, channel),
      ],
      hasData: true,
    );
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
