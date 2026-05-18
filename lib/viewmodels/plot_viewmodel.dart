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
  static const int _maxPoints = 600000;
  int _nextIndex = 0;
  DateTime? _startTime;

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

  // ========== 数据接收降频 ==========
  int _pendingNotifyCount = 0;
  static const int _notifyBatchSize = 5; // 每5个数据包刷新一次
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
    buffer.write('点数: $_nextIndex');
    if (_isPlotting) {
      buffer.write(' [运行中]');
    }
    return buffer.toString();
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

    // 更新实际通道数
    if (point.channelCount > _activeChannelCount) {
      _activeChannelCount = point.channelCount;
    }

    // 限制缓冲区大小
    while (_dataPoints.length > _maxPoints) {
      _dataPoints.removeAt(0);
    }

    // 自动跟随最新数据
    if (_isPlotting && _dataPoints.length > 1) {
      final lastIndex = _dataPoints.last.index;
      if (_followEnabled) {
        // 最新点在 3/4 宽度处
        final range = viewport.xRange;
        viewport = viewport.copyWith(
          xMin: (lastIndex - range * 0.75).toDouble(),
          xMax: (lastIndex + range * 0.25).toDouble(),
        );
      } else if (lastIndex > viewport.xMax - viewport.xRange * 0.1) {
        // 默认：最新点在右侧 10% 处
        final range = viewport.xRange;
        viewport = viewport.copyWith(
          xMin: (lastIndex - range + range * 0.1).toDouble(),
          xMax: (lastIndex + range * 0.1).toDouble(),
        );
      }
    }

    // 降频刷新：批量通知
    _pendingNotifyCount++;
    if (_pendingNotifyCount >= _notifyBatchSize) {
      _pendingNotifyCount = 0;
      notifyListeners();
    } else {
      // 启动延迟通知定时器，确保数据不会延迟太久
      _notifyTimer ??= Timer(const Duration(milliseconds: 50), () {
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
  Future<String?> exportToCsv() async {
    try {
      if (_dataPoints.isEmpty) {
        AppLogger().warning('无数据可导出', category: 'PLOT');
        return null;
      }

      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_plot_$timestamp.csv';
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
