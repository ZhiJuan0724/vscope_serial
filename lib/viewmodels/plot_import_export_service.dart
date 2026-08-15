import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/constants/plot_configuration.dart';
import '../core/utils/app_logger.dart';
import '../core/utils/atomic_file.dart';
import '../core/utils/crc.dart';
import '../data/models/channel_config.dart';
import '../data/models/math_channel_config.dart';
import '../data/models/parser_config.dart';
import '../views/plot/plot_viewport.dart';
import 'plot_history_store.dart';
import 'plot_math_engine.dart';

typedef PlotImportProgressCallback = void Function(PlotImportProgress progress);
typedef PlotExportProgressCallback = void Function(PlotImportProgress progress);

class PlotImportProgress {
  final String stage;
  final int current;
  final int total;
  final String? detail;
  final double? bytesPerSecond;

  const PlotImportProgress({
    required this.stage,
    required this.current,
    required this.total,
    this.detail,
    this.bytesPerSecond,
  });

  double? get fraction {
    if (total <= 0) return null;
    return (current / total).clamp(0.0, 1.0);
  }
}

class PlotExportCancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

/// 导入导出服务需要宿主（PlotViewModel）提供的窄接口。
///
/// 导入导出的核心业务只依赖 [PlotHistoryStore]、[PlotMathEngine] 和本接口，
/// 不依赖任何 Flutter UI 类型；宿主负责把少量与自身私有状态强耦合的
/// 读写操作暴露出来，从而避免把整个 PlotViewModel 传入服务。
abstract interface class PlotImportExportHost {
  ParserType get parserType;
  ParserConfig get parserConfig;
  SendProtocolType get sendProtocolType;
  List<String> get rChannelAddresses;
  List<ChannelConfig> get channels;
  List<MathChannelConfig> get mathChannels;
  List<int>? get importedChannelAddresses;
  int get retentionLimitBytes;
  PlotViewport get viewport;
  set viewport(PlotViewport value);

  String displayChannelName(int index);
  void showStatusMessage(String message, {Duration duration});
  String formatRetentionBytes(int bytes);

  /// 序列化 [sourceStart, sourceStart + pointCount) 范围内的观察点，
  /// 供导出元数据复用。无观察点时返回空列表。
  List<Map<String, dynamic>> exportObservationsMetadata({
    required int sourceStart,
    required int pointCount,
  });

  void beginImportedReplacement();
  void setNextIndex(int value);
  void setActiveChannelCount(int value);
  void clearStartTime();
  void applyImportedMetadata(Map<String, dynamic>? metadata, int channelCount);
  Future<void> rebuildParsedWindow(int start, int count);
  void clearViewportHistory();
  void resetCursorPositions();
  void applyImportedObservations(Map<String, dynamic>? metadata);
  void notifyLater();
}

/// 用户主动取消导出时使用的内部控制流异常；调用方不将其当作错误提示。
class _PlotExportCancelled implements Exception {}

class _PlotExportColumn {
  final int channelIndex;
  final String name;

  const _PlotExportColumn({required this.channelIndex, required this.name});

  bool get isMath => channelIndex >= PlotConfiguration.rawChannelCount;
}

/// CSV 预检完成后可安全提交的导入计划。
///
/// 预检不清空当前历史；只有计划完整通过容量和格式校验后才进入替换阶段。
class _CsvImportPlan {
  final int pointCount;
  final int sourceChannelCount;
  final int rawChannelCount;
  final Map<String, dynamic> metadata;

  const _CsvImportPlan({
    required this.pointCount,
    required this.sourceChannelCount,
    required this.rawChannelCount,
    required this.metadata,
  });
}

/// BIN 预检结果，保留构建正式紧凑历史所需的元数据和偏移量。
class _BinImportPlan {
  final int version;
  final int pointCount;
  final int sourceChannelCount;
  final int rawChannelCount;
  final int payloadOffset;
  final int rowLength;
  final Map<String, dynamic> metadata;

  const _BinImportPlan({
    required this.version,
    required this.pointCount,
    required this.sourceChannelCount,
    required this.rawChannelCount,
    required this.payloadOffset,
    required this.rowLength,
    required this.metadata,
  });
}

class _DatImportPlan {
  final int pointCount;
  final List<int> channelDataOffsets;
  final List<int> addresses;

  const _DatImportPlan({
    required this.pointCount,
    required this.channelDataOffsets,
    required this.addresses,
  });
}

class _ImportValueRange {
  double min = double.infinity;
  double max = double.negativeInfinity;

  void include(List<double> values) {
    for (final value in values) {
      if (!value.isFinite) continue;
      if (value < min) min = value;
      if (value > max) max = value;
    }
  }
}

/// 绘图数据导入导出服务，包含 CSV、BIN 和旧版 DAT 格式。
/// 绘图历史的事务导入导出实现。
///
/// 导出始终写同目录 .part；导入先流式预检并暂存，预检失败保留当前绘图，提交后
/// 只维护新历史，避免旧新双份完整数据同时占用内存。
///
/// 服务通过构造注入 [PlotHistoryStore]、[PlotMathEngine] 与宿主窄接口
/// [PlotImportExportHost]，可脱离完整 PlotViewModel 单独测试。
class PlotImportExportService {
  PlotImportExportService({
    required PlotHistoryStore historyStore,
    required PlotMathEngine mathEngine,
    required PlotImportExportHost host,
  }) : _historyStore = historyStore,
       _mathEngine = mathEngine,
       _host = host;

  static const int _binMaxUint32 = 0xFFFFFFFF;
  static const int _binExportBatchSize = 65536;
  static const int _csvExportBatchSize = 8192;
  static const int _maxExportChannelCount = PlotConfiguration.totalChannelCount;
  static const AtomicFileCommitter _atomicFiles = AtomicFileCommitter();

  final PlotHistoryStore _historyStore;
  final PlotMathEngine _mathEngine;
  final PlotImportExportHost _host;

  List<ChannelConfig> get exportCandidateChannels {
    final rawCount =
        _exportChannelCount.clamp(0, _host.channels.length).toInt();
    return [
      ..._host.channels.take(rawCount),
      for (final channel in _host.mathChannels)
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
    String? partPath;
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
      // 正式目标保留到全部批次写入并关闭后才由原子提交替换。
      partPath = _atomicFiles.partPath(path);
      final file = File(partPath);
      if (await file.exists()) await file.delete();
      sink = file.openWrite();
      final startedAt = DateTime.now();
      var writtenBytes = 0;
      final header = StringBuffer('x');
      for (final column in exportColumns) {
        header.write(
          column.isMath
              ? ',${_host.mathChannels[column.channelIndex - PlotConfiguration.rawChannelCount].expression}'
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
      await _atomicFiles.commitPart(path);
      partPath = null;
      AppLogger().info('已导出 CSV: $path', category: 'PLOT');
      return path;
    } on _PlotExportCancelled {
      await sink?.close();
      if (partPath != null) {
        try {
          await File(partPath).delete();
        } catch (_) {}
      }
      AppLogger().info('CSV 导出已取消', category: 'PLOT');
      return null;
    } catch (e) {
      await sink?.close();
      if (partPath != null) {
        try {
          await File(partPath).delete();
        } catch (_) {}
      }
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
    String? partPath;
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
        _host.showStatusMessage(message, duration: const Duration(seconds: 6));
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
      partPath = _atomicFiles.partPath(path);
      final partFile = File(partPath);
      if (await partFile.exists()) await partFile.delete();
      output = await partFile.open(mode: FileMode.write);
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
      await _atomicFiles.commitPart(path);
      partPath = null;
      AppLogger().info('已导出 BIN: $path', category: 'PLOT');
      return path;
    } on _PlotExportCancelled {
      await output?.close();
      if (partPath != null) {
        try {
          await File(partPath).delete();
        } catch (_) {}
      }
      AppLogger().info('BIN 导出已取消', category: 'PLOT');
      return null;
    } catch (e) {
      await output?.close();
      if (partPath != null) {
        try {
          await File(partPath).delete();
        } catch (_) {}
      }
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
      _host.showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    if (unique.length > _maxExportChannelCount) {
      const message =
          '导出失败：当前格式最多支持同时导出 '
          '${PlotConfiguration.totalChannelCount} 个通道';
      _host.showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    for (final index in unique) {
      if (!byIndex.containsKey(index)) {
        final message = '导出失败：通道 $index 不可用';
        _host.showStatusMessage(message, duration: const Duration(seconds: 4));
        AppLogger().warning(message, category: 'PLOT');
        return null;
      }
    }
    return [
      for (final index in unique)
        _PlotExportColumn(
          channelIndex: index,
          name: _host.displayChannelName(index),
        ),
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
    if (mathIndex < 0 || mathIndex >= _host.mathChannels.length) {
      return double.nan;
    }
    return _mathEngine.evaluateAt(
      channelIndex: mathIndex,
      currentIndex: pointIndex,
      pointCount: _exportPointCount,
      valueAt:
          (sourcePointIndex, sourceChannelIndex) => _exportRawValueAt(
            sourcePointIndex,
            sourceChannelIndex,
            decodedCache,
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
      final valueCount = _historyStore.parsedValueCountAt(pointIndex);
      return channelIndex < valueCount
          ? _historyStore.parsedValueAt(pointIndex, channelIndex)
          : double.nan;
    }
    final values = decodedCache.putIfAbsent(
      pointIndex,
      () => _decodeExportValuesAt(pointIndex),
    );
    return channelIndex < values.length ? values[channelIndex] : double.nan;
  }

  int get _exportChannelCount {
    if (_host.parserType == ParserType.zobow && _historyStore.hasZobowFrames) {
      return _host.parserConfig.zobowChannelCount;
    }
    if (_host.parserType == ParserType.fixedFrame &&
        _historyStore.hasFixedFrames) {
      return _host.parserConfig.channelCount;
    }
    return _historyStore.parsedMaxChannelCount;
  }

  int get _exportPointCount => _historyStore.pointCount(_host.parserType);

  (int, int)? _normalizeExportRange(int? startIndex, int? endIndex) {
    final total = _exportPointCount;
    if (total <= 0) return null;
    final start = startIndex ?? 0;
    final end = endIndex ?? total - 1;
    if (start < 0 || end < start || end >= total) {
      final message = '导出范围无效：起始点和结束点必须在 0-${total - 1} 内';
      _host.showStatusMessage(message, duration: const Duration(seconds: 4));
      AppLogger().warning(message, category: 'PLOT');
      return null;
    }
    return (start, end - start + 1);
  }

  bool get _exportsParsedHistory =>
      !(_host.parserType == ParserType.zobow && _historyStore.hasZobowFrames) &&
      !(_host.parserType == ParserType.fixedFrame &&
          _historyStore.hasFixedFrames);

  List<double> _decodeExportValuesAt(int pointIndex) {
    if (!_exportsParsedHistory) {
      return _historyStore.valuesAt(
        pointIndex,
        _host.parserType,
        _host.parserConfig,
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
                  _host
                      .mathChannels[column.channelIndex -
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
    if (restoresProtocolMetadata && _host.importedChannelAddresses != null) {
      metadata['channelAddresses'] = _host.importedChannelAddresses!
          .take(rawColumns.length)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (restoresProtocolMetadata && _host.parserType == ParserType.zobow) {
      metadata['parserType'] = ParserType.zobow.name;
      metadata['zobowChannelIds'] = _host.parserConfig.zobowChannelIds
          .take(rawColumns.length)
          .map((id) => id & 0xFFFFFFFF)
          .toList(growable: false);
    }
    if (restoresProtocolMetadata &&
        _host.sendProtocolType == SendProtocolType.rProtocol) {
      metadata['sendProtocolType'] = SendProtocolType.rProtocol.name;
      metadata['rChannelAddresses'] = List<String>.from(
        _host.rChannelAddresses,
      );
    }
    if (includeObservations) {
      final observations = _host.exportObservationsMetadata(
        sourceStart: sourceStart,
        pointCount: pointCount,
      );
      if (observations.isNotEmpty) {
        metadata['observations'] = observations;
      }
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
    File? staged;
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }
      staged = await _stageImportFile(file, '读取 CSV', onProgress);
      final plan = await _preflightCsv(staged, onProgress);
      await _buildCsvImport(staged, plan, onProgress);

      AppLogger().info(
        'CSV 导入成功: $filePath, ${plan.pointCount} 点, '
        '${plan.sourceChannelCount} 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('CSV 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    } finally {
      if (staged != null && await staged.exists()) await staged.delete();
    }
  }

  Future<String?> importFromBin(
    String filePath, {
    PlotImportProgressCallback? onProgress,
  }) async {
    File? staged;
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      staged = await _stageImportFile(file, '读取 BIN', onProgress);
      final plan = await _preflightBin(staged, onProgress);
      await _buildBinImport(staged, plan, onProgress);
      AppLogger().info(
        'BIN 导入成功: $filePath, ${plan.pointCount} 点, '
        '${plan.sourceChannelCount} 通道',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('BIN 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    } finally {
      if (staged != null && await staged.exists()) await staged.delete();
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
    File? staged;
    try {
      final file = File(filePath);
      await _reportImportProgress(onProgress, '检查文件', 0, 0);
      if (!await file.exists()) {
        return '文件不存在';
      }

      staged = await _stageImportFile(file, '读取 DAT', onProgress);
      final plan = await _preflightDat(staged);
      await _buildDatImport(staged, plan, onProgress);
      AppLogger().info(
        '旧版 DAT 导入成功: $filePath, ${plan.pointCount} 点, '
        '地址=${plan.addresses.map((address) => '0x${address.toRadixString(16).toUpperCase()}').join(',')}',
        category: 'PLOT',
      );
      return null;
    } catch (e) {
      AppLogger().error('旧版 DAT 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    } finally {
      if (staged != null && await staged.exists()) await staged.delete();
    }
  }

  Future<File> _stageImportFile(
    File source,
    String stage,
    PlotImportProgressCallback? onProgress,
  ) async {
    // 暂存为稳定副本，后续预检和构建两遍读取不会受原文件移动或覆盖影响。
    final length = await source.length();
    final separator = Platform.pathSeparator;
    final staged = File(
      '${Directory.systemTemp.path}${separator}vscope_import_'
      '${pid}_${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final input = await source.open();
    final output = await staged.open(mode: FileMode.write);
    var copied = 0;
    try {
      try {
        while (copied < length) {
          final chunk = await input.read(math.min(64 * 1024, length - copied));
          if (chunk.isEmpty) {
            throw const FileSystemException('导入源文件读取中断');
          }
          await output.writeFrom(chunk);
          copied += chunk.length;
          if (copied % (4 * 1024 * 1024) < chunk.length || copied == length) {
            await _reportImportProgress(
              onProgress,
              stage,
              copied,
              length,
              detail: '$copied 字节',
            );
          }
        }
        await output.flush();
      } finally {
        await output.close();
        await input.close();
      }
      return staged;
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
  }

  Stream<String> _readBoundedCsvLines(File file) async* {
    const maxLineBytes = 64 * 1024;
    final line = <int>[];
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (byte == 0x0A) {
          yield utf8.decode(line);
          line.clear();
          continue;
        }
        line.add(byte);
        if (line.length > maxLineBytes) {
          throw const FormatException('CSV 单行超过 64 KiB');
        }
      }
    }
    if (line.isNotEmpty) yield utf8.decode(line);
  }

  Future<_CsvImportPlan> _preflightCsv(
    File file,
    PlotImportProgressCallback? onProgress,
  ) async {
    final metadata = <String, dynamic>{};
    List<String>? headerParts;
    var pointCount = 0;
    var scannedLines = 0;
    await for (final rawLine in _readBoundedCsvLines(file)) {
      scannedLines++;
      final line = rawLine.trim();
      if (headerParts == null) {
        if (line.startsWith('#')) {
          const prefix = '# vscope_plot_meta=';
          if (line.startsWith(prefix)) {
            final decoded = jsonDecode(line.substring(prefix.length));
            if (decoded is Map) {
              metadata.addAll(Map<String, dynamic>.from(decoded));
            }
          }
          continue;
        }
        if (line.isEmpty) continue;
        if (!line.toLowerCase().startsWith('x')) {
          throw const FormatException('表头格式错误，第一列应为 x');
        }
        headerParts = line.split(',');
        continue;
      }
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length >= 2 && double.tryParse(parts[0].trim()) != null) {
        pointCount++;
      }
      if (scannedLines % _importProgressBatchSize == 0) {
        await _reportImportProgress(
          onProgress,
          '校验 CSV',
          scannedLines,
          0,
          detail: '$pointCount 点',
        );
      }
    }
    if (headerParts == null) throw const FormatException('缺少 CSV 表头');
    final channelCount = headerParts.length - 1;
    if (channelCount < 1) throw const FormatException('至少需要 1 个数据列');
    if (channelCount > PlotConfiguration.totalChannelCount) {
      throw const FormatException(
        '通道数超过限制（最大${PlotConfiguration.totalChannelCount}通道）',
      );
    }
    if (pointCount == 0) throw const FormatException('未找到有效数据行');
    final rawChannelCount = math.min(
      channelCount,
      PlotConfiguration.rawChannelCount,
    );
    if (channelCount > PlotConfiguration.rawChannelCount) {
      final expressions = _csvTrailingMathExpressions(headerParts);
      if (expressions == null) {
        throw const FormatException('超过16列的 CSV 必须按 Ch0..Ch15 加数学表达式列排列');
      }
      metadata['mathChannels'] = _mathChannelMetadata(expressions);
    }
    _validateImportCapacity(pointCount, rawChannelCount);
    return _CsvImportPlan(
      pointCount: pointCount,
      sourceChannelCount: channelCount,
      rawChannelCount: rawChannelCount,
      metadata: metadata,
    );
  }

  Future<void> _buildCsvImport(
    File file,
    _CsvImportPlan plan,
    PlotImportProgressCallback? onProgress,
  ) async {
    _host.beginImportedReplacement();
    final range = _ImportValueRange();
    var headerSeen = false;
    var pointIndex = 0;
    await for (final rawLine in _readBoundedCsvLines(file)) {
      final line = rawLine.trim();
      if (!headerSeen) {
        if (line.isEmpty || line.startsWith('#')) continue;
        headerSeen = true;
        continue;
      }
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < 2 || double.tryParse(parts[0].trim()) == null) {
        continue;
      }
      final values = List<double>.filled(plan.rawChannelCount, 0);
      for (
        var channel = 0;
        channel < plan.rawChannelCount && channel + 1 < parts.length;
        channel++
      ) {
        values[channel] = double.tryParse(parts[channel + 1].trim()) ?? 0;
      }
      _appendImportedValues(pointIndex++, values, range);
      if (pointIndex % _importProgressBatchSize == 0 ||
          pointIndex == plan.pointCount) {
        await _reportImportProgress(
          onProgress,
          '建立绘图索引',
          pointIndex,
          plan.pointCount,
          detail: '$pointIndex 点',
        );
      }
    }
    await _finishImportedReplacement(
      plan.pointCount,
      plan.rawChannelCount,
      range,
      metadata: plan.metadata,
      onProgress: onProgress,
    );
  }

  Future<_BinImportPlan> _preflightBin(
    File file,
    PlotImportProgressCallback? onProgress,
  ) async {
    const magic = [0x56, 0x53, 0x50, 0x4C, 0x4F, 0x54, 0x42, 0x31];
    const maxMetadataBytes = 16 * 1024 * 1024;
    final input = await file.open();
    try {
      final fileLength = await input.length();
      if (fileLength < 24) throw const FormatException('BIN 文件头不完整');
      final firstHeader = await _readExact(input, 24);
      for (var i = 0; i < magic.length; i++) {
        if (firstHeader[i] != magic[i]) {
          throw const FormatException('BIN 文件标识错误');
        }
      }
      final header = ByteData.sublistView(firstHeader);
      final version = header.getUint16(8, Endian.little);
      final channelCount = header.getUint16(10, Endian.little);
      final pointCount = header.getUint32(12, Endian.little);
      final payloadLength = header.getUint32(16, Endian.little);
      final expectedChecksum = header.getUint32(20, Endian.little);
      if (version != 1 && version != 2) {
        throw FormatException('不支持的 BIN 版本: $version');
      }
      if (channelCount < 1 ||
          channelCount > PlotConfiguration.totalChannelCount) {
        throw const FormatException('通道数无效');
      }
      final headerLength = version == 2 ? 28 : 24;
      var metadataLength = 0;
      if (version == 2) {
        metadataLength = ByteData.sublistView(
          await _readExact(input, 4),
        ).getUint32(0, Endian.little);
      }
      if (metadataLength > maxMetadataBytes) {
        throw const FormatException('BIN 元数据超过 16 MiB 限制');
      }
      if (fileLength != headerLength + metadataLength + payloadLength) {
        throw const FormatException('BIN 文件长度不匹配');
      }
      final rowLength = 8 + channelCount * 8;
      if (pointCount == 0 || payloadLength != pointCount * rowLength) {
        throw const FormatException('BIN 数据长度不匹配');
      }

      final metadata = <String, dynamic>{};
      if (metadataLength > 0) {
        final decoded = jsonDecode(
          utf8.decode(await _readExact(input, metadataLength)),
        );
        if (decoded is! Map) throw const FormatException('BIN 元数据格式错误');
        metadata.addAll(Map<String, dynamic>.from(decoded));
      }

      await input.setPosition(headerLength);
      final crc = CrcCalculator(crc32Polys['CRC-32']!);
      var checked = 0;
      final checkedLength = metadataLength + payloadLength;
      while (checked < checkedLength) {
        final chunk = await input.read(
          math.min(64 * 1024, checkedLength - checked),
        );
        if (chunk.isEmpty) throw const FormatException('BIN 数据读取中断');
        crc.add(chunk);
        checked += chunk.length;
        if (checked % (4 * 1024 * 1024) < chunk.length ||
            checked == checkedLength) {
          await _reportImportProgress(
            onProgress,
            '校验 BIN',
            checked,
            checkedLength,
          );
        }
      }
      if (crc.digest != expectedChecksum) {
        throw const FormatException('BIN 校验失败');
      }

      final rawChannelCount = math.min(
        channelCount,
        PlotConfiguration.rawChannelCount,
      );
      if (channelCount > PlotConfiguration.rawChannelCount) {
        final expressions = _binTrailingMathExpressions(metadata, channelCount);
        if (expressions == null) {
          throw const FormatException('超过16列的 BIN 缺少完整的普通/数学通道描述');
        }
        metadata['mathChannels'] = _mathChannelMetadata(expressions);
      }
      _validateImportCapacity(pointCount, rawChannelCount);
      return _BinImportPlan(
        version: version,
        pointCount: pointCount,
        sourceChannelCount: channelCount,
        rawChannelCount: rawChannelCount,
        payloadOffset: headerLength + metadataLength,
        rowLength: rowLength,
        metadata: metadata,
      );
    } finally {
      await input.close();
    }
  }

  Future<void> _buildBinImport(
    File file,
    _BinImportPlan plan,
    PlotImportProgressCallback? onProgress,
  ) async {
    _host.beginImportedReplacement();
    final range = _ImportValueRange();
    final input = await file.open();
    var pointIndex = 0;
    try {
      await input.setPosition(plan.payloadOffset);
      while (pointIndex < plan.pointCount) {
        final rows = math.min(
          _importProgressBatchSize,
          plan.pointCount - pointIndex,
        );
        final chunk = await _readExact(input, rows * plan.rowLength);
        final data = ByteData.sublistView(chunk);
        var offset = 0;
        for (var row = 0; row < rows; row++) {
          offset += 8;
          final values = List<double>.generate(
            plan.rawChannelCount,
            (channel) => data.getFloat64(offset + channel * 8, Endian.little),
            growable: false,
          );
          offset += (plan.sourceChannelCount * 8);
          _appendImportedValues(pointIndex++, values, range);
        }
        await _reportImportProgress(
          onProgress,
          '建立绘图索引',
          pointIndex,
          plan.pointCount,
          detail: '$pointIndex 点',
        );
      }
    } finally {
      await input.close();
    }
    await _finishImportedReplacement(
      plan.pointCount,
      plan.rawChannelCount,
      range,
      metadata: plan.metadata,
      onProgress: onProgress,
    );
  }

  Future<_DatImportPlan> _preflightDat(File file) async {
    const channelCount = 4;
    const reservedPointCount = 50000;
    const minimumHeaderLength = 0x24;
    final input = await file.open();
    try {
      final fileLength = await input.length();
      if (fileLength < minimumHeaderLength) {
        throw const FormatException('DAT 文件头不完整');
      }
      final header = ByteData.sublistView(
        await _readExact(input, minimumHeaderLength),
      );
      if (header.getUint32(0, Endian.little) != fileLength) {
        throw const FormatException('DAT 文件长度校验失败');
      }
      final storedPointCount = header.getUint32(0x20, Endian.little);
      if (storedPointCount <= reservedPointCount) {
        throw const FormatException('DAT 文件没有有效数据');
      }
      final expectedLength = 4 + channelCount * (32 + storedPointCount * 2);
      if (expectedLength != fileLength) {
        throw const FormatException('DAT 数据布局不匹配');
      }
      final addresses = <int>[];
      final offsets = <int>[];
      for (var channel = 0; channel < channelCount; channel++) {
        final channelNumber = channel + 1;
        final blockOffset = channel * storedPointCount * 2;
        final dataOffset =
            0x04 + channelNumber * 32 + blockOffset + reservedPointCount * 2;
        final addressOffset = dataOffset - reservedPointCount * 2 - 12;
        final dataEnd =
            0x04 + channelNumber * 32 + blockOffset + storedPointCount * 2;
        if (addressOffset + 4 > fileLength ||
            dataOffset > dataEnd ||
            dataEnd > fileLength) {
          throw const FormatException('DAT 通道数据不完整');
        }
        await input.setPosition(addressOffset);
        addresses.add(
          ByteData.sublistView(
            await _readExact(input, 4),
          ).getUint32(0, Endian.little),
        );
        offsets.add(dataOffset);
      }
      final pointCount = storedPointCount - reservedPointCount;
      _validateImportCapacity(pointCount, channelCount);
      return _DatImportPlan(
        pointCount: pointCount,
        channelDataOffsets: offsets,
        addresses: addresses,
      );
    } finally {
      await input.close();
    }
  }

  Future<void> _buildDatImport(
    File file,
    _DatImportPlan plan,
    PlotImportProgressCallback? onProgress,
  ) async {
    _host.beginImportedReplacement();
    final range = _ImportValueRange();
    final input = await file.open();
    var pointIndex = 0;
    try {
      while (pointIndex < plan.pointCount) {
        final rows = math.min(
          _importProgressBatchSize,
          plan.pointCount - pointIndex,
        );
        final channelBlocks = <ByteData>[];
        for (final offset in plan.channelDataOffsets) {
          await input.setPosition(offset + pointIndex * 2);
          channelBlocks.add(
            ByteData.sublistView(await _readExact(input, rows * 2)),
          );
        }
        for (var row = 0; row < rows; row++) {
          final values = <double>[
            for (final channel in channelBlocks)
              channel.getInt16(row * 2, Endian.little).toDouble(),
          ];
          _appendImportedValues(pointIndex++, values, range);
        }
        await _reportImportProgress(
          onProgress,
          '解析 DAT',
          pointIndex,
          plan.pointCount,
          detail: '$pointIndex 点',
        );
      }
    } finally {
      await input.close();
    }
    await _reportImportProgress(
      onProgress,
      '建立绘图索引',
      plan.pointCount,
      plan.pointCount,
      detail: '${plan.pointCount} 点',
    );
    await _finishImportedReplacement(
      plan.pointCount,
      plan.channelDataOffsets.length,
      range,
      metadata: {'channelAddresses': plan.addresses},
      onProgress: onProgress,
    );
  }

  Future<Uint8List> _readExact(RandomAccessFile input, int length) async {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final chunk = await input.read(length - offset);
      if (chunk.isEmpty) throw const FormatException('文件数据提前结束');
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
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
      if (_mathEngine.validate(expression) != null) return null;
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
      if (_mathEngine.validate(expression) != null) return null;
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

  void _validateImportCapacity(int pointCount, int channelCount) {
    // 用与精确窗口相同的保守投影在替换旧历史前拒绝超预算文件。
    final normalizedChannelCount = channelCount.clamp(
      1,
      PlotConfiguration.rawChannelCount,
    );
    final projectedBytes =
        pointCount * (normalizedChannelCount * 8 + 64) +
        math.min(pointCount, PlotConfiguration.maxMaterializedPointCount) * 192;
    if (projectedBytes > _host.retentionLimitBytes) {
      throw StateError(
        '导入预计占用 ${_host.formatRetentionBytes(projectedBytes)}，超过绘图历史 '
        '${_host.formatRetentionBytes(_host.retentionLimitBytes)} 上限',
      );
    }
  }

  void _appendImportedValues(
    int pointIndex,
    List<double> values,
    _ImportValueRange range,
  ) {
    _historyStore.appendImportedParsedPoint(
      pointIndex,
      values,
      _host.parserType,
    );
    range.include(values);
  }

  Future<void> _finishImportedReplacement(
    int pointCount,
    int channelCount,
    _ImportValueRange range, {
    Map<String, dynamic>? metadata,
    PlotImportProgressCallback? onProgress,
  }) async {
    _host.setNextIndex(pointCount);
    _host.setActiveChannelCount(channelCount);
    _host.clearStartTime();
    _host.applyImportedMetadata(metadata, channelCount);

    final visibleCount =
        pointCount
            .clamp(0, PlotConfiguration.maxMaterializedPointCount)
            .toInt();
    final visibleStart = pointCount - visibleCount;
    _host.viewport = PlotViewport(
      xMin: visibleStart.toDouble(),
      xMax: pointCount.toDouble(),
      yMin: range.min == double.infinity ? 0 : range.min,
      yMax: range.max == double.negativeInfinity ? 1 : range.max,
    );
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      0,
      visibleCount,
      detail: '$visibleCount 点',
    );
    await _host.rebuildParsedWindow(visibleStart, visibleCount);
    await _reportImportProgress(
      onProgress,
      '加载可见窗口',
      visibleCount,
      visibleCount,
      detail: '$visibleCount 点',
    );
    _host.clearViewportHistory();

    _host.resetCursorPositions();
    _host.applyImportedObservations(metadata);

    _host.notifyLater();
  }
}
