import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../core/utils/app_logger.dart';
import '../data/models/channel_config.dart';
import '../data/models/data_source_config.dart';
import '../data/models/parse_result.dart';
import '../data/models/parser_config.dart';
import '../data/models/plot_data.dart';
import '../data/parser/data_parser.dart';
import '../data/parser/firewater_parser.dart';
import '../data/parser/fixed_frame_parser.dart';
import '../data/source/data_source_manager.dart';
import '../views/plot/plot_painter.dart';
import '../views/plot/plot_viewport.dart';
import 'base_viewmodel.dart';

/// 绘图页面 ViewModel
class PlotViewModel extends BaseViewModel {
  // ========== 数据源 ==========
  late final DataSourceManager _sourceManager;

  // ========== 解析器 ==========
  IDataParser? _parser;
  StreamSubscription? _parseSubscription;

  // ========== 数据缓冲区 ==========
  final List<PlotDataPoint> _dataPoints = [];
  static const int _maxPoints = 100000; // 降低上限减少内存压力
  int _nextIndex = 0;
  DateTime? _startTime;

  // ========== 速率统计（基于计数器，避免遍历列表）==========
  final List<_RateSample> _rateSamples = [];
  static const int _maxRateSamples = 1000; // 最近1000个样本
  int _totalReceived = 0;

  // ========== 当前数据实际通道数 ==========
  int _activeChannelCount = 0;

  // ========== 视口 ==========
  PlotViewport viewport = PlotViewport(
    xMin: 0,
    xMax: 1000,
    yMin: 0,
    yMax: 32768,
  );

  // ========== 视口历史记录（用于撤回） ==========
  final List<PlotViewport> _viewportHistory = [];
  static const int _maxHistory = 50;

  // ========== 通道配置 ==========
  final List<ChannelConfig> channels = ChannelConfig.createDefaults();

  // ========== 状态 ==========
  bool _isPlotting = false;
  bool _showGrid = true;
  bool _useRandomSource = false;
  bool _followEnabled = false; // 最新点跟随在3/4宽度处
  bool _vCursorEnabled = false; // 单垂直光标开关
  CursorMode _cursorMode = CursorMode.none;
  CursorState? _cursor;
  ParserType _parserType = ParserType.fireWater;
  final ParserConfig _parserConfig = ParserConfig.fireWaterDefault();

  // ========== 缩放按钮状态 ==========
  bool _boxZoomEnabled = false;

  // ========== 数据源配置 ==========
  final DataSourceConfig _sourceConfig = DataSourceConfig();

  // ========== x-x / y-y 光标 ==========
  double? _xCursor1;
  double? _xCursor2;
  double? _yCursor1;
  double? _yCursor2;

  // ========== 定时刷新 ==========
  Timer? _refreshTimer;
  static const int _refreshIntervalMs = 100; // 无数据时100ms刷新一次

  // ========== UI 刷新降频（数据不丢失）==========
  int _pendingNotifyCount = 0;
  // 动态批量大小：控制 UI 刷新频率，数据始终全部接收
  // 目标：UI 刷新频率控制在约 15fps，平衡流畅度和性能
  int get _notifyBatchSize {
    final intervalMs = _sourceConfig.randomIntervalMs;
    if (intervalMs <= 1) return 66;      // >= 1000Hz: 每66包刷新UI (~15fps)
    if (intervalMs <= 2) return 66;      // 500-1000Hz: 每66包刷新UI (~15fps)
    if (intervalMs <= 5) return 66;      // 200-500Hz: 每66包刷新UI (~15fps)
    if (intervalMs <= 10) return 50;     // 100-200Hz: 每50包刷新UI (~10fps)
    if (intervalMs <= 50) return 10;     // 20-100Hz: 每10包刷新UI
    return 1;                            // < 20Hz: 每包刷新UI
  }
  Timer? _notifyTimer;

  PlotViewModel(super.serialService) {
    _sourceManager = DataSourceManager(serialService);
    _startRefreshTimer();
  }

  // ========== Getters ==========
  List<PlotDataPoint> get dataPoints => List.unmodifiable(_dataPoints);
  bool get isPlotting => _isPlotting;
  bool get showGrid => _showGrid;
  bool get useRandomSource => _useRandomSource;
  bool get boxZoomEnabled => _boxZoomEnabled;
  bool get followEnabled => _followEnabled;
  bool get vCursorEnabled => _vCursorEnabled;
  CursorMode get cursorMode => _cursorMode;
  CursorState? get cursor => _cursor;
  ParserType get parserType => _parserType;
  ParserConfig get parserConfig => _parserConfig;
  int get pointCount => _dataPoints.length;
  int get activeChannelCount => _activeChannelCount;
  
  /// 随机源频率（Hz）
  double get randomFrequency => 1000.0 / _sourceConfig.randomIntervalMs;

  // 光标位置
  double? get xCursor1 => _xCursor1;
  double? get xCursor2 => _xCursor2;
  double? get yCursor1 => _yCursor1;
  double? get yCursor2 => _yCursor2;

  /// 是否有可撤回的视口历史
  bool get canUndoZoom => _viewportHistory.isNotEmpty;

  String get statusText {
    final buffer = StringBuffer();
    buffer.write('X: ${viewport.xMin.toInt()}-${viewport.xMax.toInt()} ');
    buffer.write('Y: ${viewport.yMin.toInt()}-${viewport.yMax.toInt()} ');
    // 计算每秒点数
    final pointsPerSecond = _calculatePointsPerSecond();
    if (pointsPerSecond != null) {
      buffer.write('点数: $_nextIndex (${pointsPerSecond.toStringAsFixed(1)}/s)');
    } else {
      buffer.write('点数: $_nextIndex');
    }
    if (_isPlotting) {
      buffer.write(' [运行中]');
    }
    return buffer.toString();
  }

  /// 计算每秒点数，基于最近500ms的数据（响应更快）
  /// 使用计数器方式，避免遍历整个数据列表
  double? _calculatePointsPerSecond() {
    if (_rateSamples.length < 2 || _startTime == null) return null;
    final now = DateTime.now();
    final nowMs = now.difference(_startTime!).inMilliseconds;
    final cutoffMs = nowMs - 500; // 最近500ms

    // 二分查找找到500ms前的样本位置
    int left = 0, right = _rateSamples.length - 1;
    int startIdx = 0;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (_rateSamples[mid].timestampMs < cutoffMs) {
        startIdx = mid + 1;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    final recentCount = _rateSamples.length - startIdx;
    if (recentCount < 2) return null;
    return recentCount * 2.0; // 500ms * 2 = 1s
  }

  // ========== 定时刷新 ==========
  /// 启动定时刷新器。
  /// 
  /// 绘图运行时：定时刷新确保垂直光标跟随鼠标、数据更新及时显示。
  /// 停止绘图后：定时器继续运行（即使无光标），确保拖动/缩放等交互
  /// 的视觉反馈及时，避免因纯手势回调驱动导致的卡顿感。
  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: _refreshIntervalMs),
      (_) {
        // 光标模式下定时刷新（让垂直光标跟随鼠标）
        if (_vCursorEnabled && _cursor != null) {
          notifyListeners();
        }
      },
    );
  }

  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  // ========== 数据源控制 ==========
  void setUseRandomSource(bool value) {
    _useRandomSource = value;
    _sourceConfig.useRandom = value;
    _sourceConfig.useSerial = serialService.isConnected || !value;
    // 根据 FireWater 配置的通道数设置随机数据源通道数
    // 如果 fireWaterChannelCount 为 0，则默认输出 4 通道
    _sourceConfig.randomChannelCount = _parserConfig.fireWaterChannelCount > 0
        ? _parserConfig.fireWaterChannelCount
        : 4;
    _sourceManager.updateConfig(_sourceConfig);

    // 如果正在绘图，重启数据源
    if (_isPlotting) {
      _restartPlotting();
    }
    notifyListeners();
  }

  /// 设置随机源频率（Hz），范围 1~10000
  void setRandomFrequency(double hz) {
    final clampedHz = hz.clamp(1.0, 10000.0);
    final intervalMs = (1000.0 / clampedHz).round().clamp(1, 1000);
    _sourceConfig.randomIntervalMs = intervalMs;
    _sourceManager.updateConfig(_sourceConfig);

    // 如果正在绘图，重启数据源以应用新频率
    if (_isPlotting) {
      _restartPlotting();
    }
    notifyListeners();
  }

  // ========== 解析器控制 ==========
  void setParserType(ParserType type) {
    _parserType = type;
    _parserConfig.type = type;

    if (_isPlotting) {
      _restartPlotting();
    }
    notifyListeners();
  }

  void updateParserConfig(ParserConfig config) {
    _parserConfig.type = config.type;
    _parserConfig.frameHeaderLength = config.frameHeaderLength;
    _parserConfig.frameHeader = List.from(config.frameHeader);
    _parserConfig.dataType = config.dataType;
    _parserConfig.channelCount = config.channelCount;
    _parserConfig.fireWaterChannelCount = config.fireWaterChannelCount;
    _parserConfig.hasChecksum = config.hasChecksum;
    _parserConfig.checksumType = config.checksumType;
    _parserConfig.checksumBytes = config.checksumBytes;
    _parserConfig.hasFrameTail = config.hasFrameTail;
    _parserConfig.frameTail = config.frameTail != null ? List.from(config.frameTail!) : null;

    // 更新随机数据源通道数以匹配 FireWater 配置
    _sourceConfig.randomChannelCount = config.fireWaterChannelCount > 0
        ? config.fireWaterChannelCount
        : 4;
    _sourceManager.updateConfig(_sourceConfig);

    if (_isPlotting) {
      _restartPlotting();
    }
    notifyListeners();
  }

  // ========== 绘图控制 ==========
  void startPlotting() {
    if (_isPlotting) return;

    // 检查是否有数据源
    if (!serialService.isConnected && !_useRandomSource) {
      AppLogger().warning('无可用数据源，请先连接串口或启用随机数据源', category: 'PLOT');
      return;
    }

    // 清空旧数据
    _dataPoints.clear();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = DateTime.now();

    // 重置视口
    viewport = viewport.reset();
    _viewportHistory.clear();

    // 重置光标
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;

    // 创建解析器
    _parser = _createParser();

    // 配置并启动数据源
    _sourceConfig.useSerial = serialService.isConnected;
    _sourceConfig.useRandom = _useRandomSource;
    // 根据 FireWater 配置设置随机数据源通道数
    _sourceConfig.randomChannelCount = _parserConfig.fireWaterChannelCount > 0
        ? _parserConfig.fireWaterChannelCount
        : 4;
    _sourceManager.updateConfig(_sourceConfig);
    _sourceManager.start();

    // 连接数据源 → 解析器
    _parseSubscription = _sourceManager.byteStream.listen(
      (data) => _parser?.feed(data),
      onError: (error) {
        AppLogger().error('数据源错误: $error', category: 'PLOT');
      },
    );

    // 连接解析器 → 数据缓冲区
    _parser?.outputStream.listen(
      (result) => _onParseResult(result),
      onError: (error) {
        AppLogger().error('解析器错误: $error', category: 'PLOT');
      },
    );

    _isPlotting = true;
    serialService.isPlotting = true;
    serialService.notifyListeners();
    _startRefreshTimer();
    AppLogger().info('开始绘图', category: 'PLOT');
    notifyListeners();
  }

  void stopPlotting() {
    if (!_isPlotting) return;

    _parseSubscription?.cancel();
    _parseSubscription = null;
    _sourceManager.stop();
    _parser?.dispose();
    _parser = null;

    _isPlotting = false;
    serialService.isPlotting = false;
    serialService.notifyListeners();
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _pendingNotifyCount = 0;
    // 停止绘图后保持定时刷新，确保交互响应及时
    _startRefreshTimer();
    notifyListeners();
  }

  void _restartPlotting() {
    stopPlotting();
    startPlotting();
  }

  void clearData() {
    _dataPoints.clear();
    _rateSamples.clear();
    _totalReceived = 0;
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = null;
    viewport = viewport.reset();
    _viewportHistory.clear();
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    notifyListeners();
  }

  // ========== 数据接收 ==========
  void _onParseResult(ParseResult result) {
    if (!result.success || result.values == null || result.values!.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final timestamp = _startTime != null
        ? now.difference(_startTime!).inMilliseconds.toDouble()
        : 0.0;

    final point = PlotDataPoint(
      index: _nextIndex++,
      timestamp: timestamp,
      values: List.from(result.values!),
    );

    _dataPoints.add(point);

    // 记录速率统计样本
    _rateSamples.add(_RateSample(_nextIndex - 1, timestamp.toInt()));
    while (_rateSamples.length > _maxRateSamples) {
      _rateSamples.removeAt(0);
    }
    _totalReceived++;

    // 更新实际通道数
    if (point.channelCount > _activeChannelCount) {
      _activeChannelCount = point.channelCount;
    }

    // 限制缓冲区大小（使用removeRange批量移除，比removeAt高效）
    if (_dataPoints.length > _maxPoints) {
      final removeCount = _dataPoints.length - _maxPoints;
      _dataPoints.removeRange(0, removeCount);
    }

    // 自动跟随最新数据（仅跟随模式开启时）
    if (_isPlotting && _followEnabled && _dataPoints.length > 1) {
      final lastIndex = _dataPoints.last.index;
      // 最新点在 3/4 宽度处
      final range = viewport.xRange;
      viewport = viewport.copyWith(
        xMin: (lastIndex - range * 0.75).toDouble(),
        xMax: (lastIndex + range * 0.25).toDouble(),
      );
    }

    // 数据接收：每包数据都处理，不丢失
    // UI 刷新降频：只控制重绘频率，不影响数据接收和统计
    _pendingNotifyCount++;
    final batchSize = _notifyBatchSize;
    if (_pendingNotifyCount >= batchSize) {
      _pendingNotifyCount = 0;
      _notifyTimer?.cancel();
      _notifyTimer = null;
      notifyListeners();
    } else if (_notifyTimer == null) {
      // fallback timer：确保即使数据流中断也能刷新UI
      final delayMs = _sourceConfig.randomIntervalMs <= 10 ? 66 : 100;
      _notifyTimer = Timer(Duration(milliseconds: delayMs), () {
        _pendingNotifyCount = 0;
        _notifyTimer = null;
        notifyListeners();
      });
    }
  }

  IDataParser _createParser() {
    switch (_parserType) {
      case ParserType.fireWater:
        return FireWaterParser(_parserConfig);
      case ParserType.fixedFrame:
        return FixedFrameParser(_parserConfig);
    }
  }

  // ========== 视口控制（带历史记录） ==========
  void _saveViewport() {
    _viewportHistory.add(viewport.copy());
    if (_viewportHistory.length > _maxHistory) {
      _viewportHistory.removeAt(0);
    }
  }

  void updateViewport(PlotViewport newViewport) {
    viewport = newViewport.copy();
    notifyListeners();
  }

  void resetViewport() {
    _saveViewport();
    viewport = viewport.reset();
    notifyListeners();
  }

  /// 撤回上次缩放
  void undoZoom() {
    if (_viewportHistory.isEmpty) return;
    final previous = _viewportHistory.removeLast();
    viewport = previous.copy();
    notifyListeners();
  }

  /// X 轴放大
  void zoomXIn() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = viewport.zoomX(0.8, centerX);
    notifyListeners();
  }

  /// X 轴缩小
  void zoomXOut() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = viewport.zoomX(1.25, centerX);
    notifyListeners();
  }

  /// Y 轴放大
  void zoomYIn() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(0.8, centerY);
    notifyListeners();
  }

  /// Y 轴缩小
  void zoomYOut() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(1.25, centerY);
    notifyListeners();
  }

  /// 设置框选放大开关
  void setBoxZoomEnabled(bool value) {
    _boxZoomEnabled = value;
    notifyListeners();
  }

  /// 设置跟随开关
  void setFollowEnabled(bool value) {
    _followEnabled = value;
    notifyListeners();
  }

  /// 设置单垂直光标开关
  void setVCursorEnabled(bool value) {
    _vCursorEnabled = value;
    if (!value) {
      _cursor = null;
    }
    notifyListeners();
  }

  // ========== 通道控制 ==========
  void setChannelVisible(int index, bool visible) {
    if (index < 0 || index >= channels.length) return;
    channels[index].visible = visible;
    notifyListeners();
  }

  void setChannelColor(int index, Color color) {
    if (index < 0 || index >= channels.length) return;
    channels[index].color = color;
    notifyListeners();
  }

  void setChannelShowLine(int index, bool show) {
    if (index < 0 || index >= channels.length) return;
    channels[index].showLine = show;
    notifyListeners();
  }

  void setChannelYOffset(int index, double offset) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yOffset = offset;
    notifyListeners();
  }

  void setChannelYScale(int index, double scale) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yScale = scale;
    notifyListeners();
  }

  // ========== 显示控制 ==========
  void setShowGrid(bool show) {
    _showGrid = show;
    notifyListeners();
  }

  void setCursorMode(CursorMode mode) {
    _cursorMode = mode;
    if (mode == CursorMode.none) {
      _cursor = null;
      _xCursor1 = null;
      _xCursor2 = null;
      _yCursor1 = null;
      _yCursor2 = null;
    }
    notifyListeners();
  }

  /// 更新垂直光标（跟随鼠标模式）
  /// 
  /// - X 值吸附到最近的整数（数据点索引都是整数）
  /// - 使用二分查找精确匹配数据点，避免线性扫描
  /// - 未绘制到数据点的区域设置 hasData=false，tooltip 不显示
  void updateFollowCursor(double x, double y, Offset screenPosition) {
    // X值吸附到最近的整数（数据点索引都是整数）
    final snappedX = x.round().toDouble();

    // 查找精确匹配的数据点
    List<double>? channelValues;
    bool hasData = false;
    if (_dataPoints.isNotEmpty) {
      // 二分查找精确匹配的数据点
      int left = 0, right = _dataPoints.length - 1;
      while (left <= right) {
        final mid = (left + right) ~/ 2;
        final midIndex = _dataPoints[mid].index;
        if (midIndex == snappedX) {
          channelValues = List.from(_dataPoints[mid].values);
          hasData = true;
          break;
        } else if (midIndex < snappedX) {
          left = mid + 1;
        } else {
          right = mid - 1;
        }
      }
    }

    _cursor = CursorState(
      x: snappedX,
      y: y,
      mode: CursorMode.follow,
      screenPosition: screenPosition,
      channelValues: channelValues,
      hasData: hasData,
    );
    notifyListeners();
  }

  void updateCursor(CursorState? cursor) {
    _cursor = cursor;
    notifyListeners();
  }

  // ========== x-x / y-y 光标控制 ==========
  void setXCursor(double x) {
    if (_xCursor1 == null) {
      _xCursor1 = x;
    } else if (_xCursor2 == null) {
      _xCursor2 = x;
    } else {
      // 重置并设置第一条
      _xCursor1 = x;
      _xCursor2 = null;
    }
    _cursor = CursorState(
      x: _xCursor1 ?? x,
      mode: CursorMode.xCursor,
      xCursor2: _xCursor2,
    );
    notifyListeners();
  }

  void setYCursor(double y) {
    if (_yCursor1 == null) {
      _yCursor1 = y;
    } else if (_yCursor2 == null) {
      _yCursor2 = y;
    } else {
      _yCursor1 = y;
      _yCursor2 = null;
    }
    _cursor = CursorState(
      x: 0,
      y: _yCursor1 ?? y,
      mode: CursorMode.yCursor,
      yCursor2: _yCursor2,
    );
    notifyListeners();
  }

  void clearCursors() {
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _cursor = null;
    notifyListeners();
  }

  String? get cursorDeltaText {
    if (_cursorMode == CursorMode.xCursor && _xCursor1 != null && _xCursor2 != null) {
      final delta = (_xCursor2! - _xCursor1!).abs();
      return 'ΔX = ${delta.toStringAsFixed(2)}';
    }
    if (_cursorMode == CursorMode.yCursor && _yCursor1 != null && _yCursor2 != null) {
      final delta = (_yCursor2! - _yCursor1!).abs();
      return 'ΔY = ${delta.toStringAsFixed(2)}';
    }
    return null;
  }

  // ========== 导出 ==========
  Future<String?> exportToCsv(String? selectedPath) async {
    try {
      if (_dataPoints.isEmpty) {
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
      final maxChannels = _dataPoints.map((p) => p.channelCount).reduce((a, b) => a > b ? a : b);
      buffer.write('x');
      for (int i = 0; i < maxChannels; i++) {
        buffer.write(',y${i + 1}');
      }
      buffer.writeln();

      // 数据行
      for (final point in _dataPoints) {
        buffer.write(point.index);
        for (int i = 0; i < maxChannels; i++) {
          buffer.write(',');
          if (i < point.values.length) {
            buffer.write(point.values[i].toStringAsFixed(6));
          }
        }
        buffer.writeln();
      }

      await file.writeAsString(buffer.toString());
      AppLogger().info('已导出 CSV: $path', category: 'PLOT');
      return path;
    } catch (e) {
      AppLogger().error('CSV 导出失败: $e', category: 'PLOT');
      return null;
    }
  }

  @override
  void dispose() {
    _parseSubscription?.cancel();
    _parseSubscription = null;
    _sourceManager.stop();
    _parser?.dispose();
    _parser = null;
    _isPlotting = false;
    serialService.isPlotting = false;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _pendingNotifyCount = 0;
    _stopRefreshTimer();
    _sourceManager.dispose();
    super.dispose();
  }
}

/// 速率统计样本
class _RateSample {
  final int index;
  final int timestampMs;
  _RateSample(this.index, this.timestampMs);
}
