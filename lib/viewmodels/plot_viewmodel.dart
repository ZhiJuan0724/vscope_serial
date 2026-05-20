import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/channel_config.dart';
import '../data/models/data_source_config.dart';
import '../data/models/parse_result.dart';
import '../data/models/parser_config.dart';
import '../data/models/plot_data.dart';
import '../data/parser/data_parser.dart';
import '../data/parser/firewater_parser.dart';
import '../data/parser/fixed_frame_parser.dart';
import '../data/parser/jack_four_channel_parser.dart';
import '../data/source/data_source_manager.dart';
import '../services/app_settings.dart';
import '../views/plot/plot_painter.dart';
import '../views/plot/plot_viewport.dart';
import 'base_viewmodel.dart';

/// 绘图页面核心 ViewModel，负责整个波形绘图页面的业务逻辑。
///
/// 主要职责：
/// - 管理数据源（串口/随机源）的启动与停止
/// - 管理数据解析器（FireWater / 固定帧）的配置与切换
/// - 维护数据缓冲区，控制最大点数限制（10万点）
/// - 管理绘图视口（viewport）的缩放、平移、自适应、历史记录
/// - 提供光标系统（垂直跟随光标、X-X/Y-Y 测量光标、统计范围）
/// - 管理通道配置（可见性、颜色、缩放、偏移）
/// - 控制 UI 刷新频率（10~60 fps），实现数据接收与 UI 刷新解耦
/// - 统计测量（Max/Min/Avg）与 CSV 导出
/// - 配置持久化（通过 AppSettings）
///
/// 数据流：DataSourceManager → IDataParser → _dataPoints → PlotPainter
/// UI 刷新：通过 notifyListeners() 驱动 Consumer[PlotViewModel] 重建
class PlotViewModel extends BaseViewModel {
  // ========== 数据源 ==========
  /// 数据源管理器，封装串口和随机数据源的统一接口
  late final DataSourceManager _sourceManager;

  // ========== 解析器 ==========
  /// 当前使用的数据解析器（FireWater 或固定帧）
  IDataParser? _parser;
  /// 数据源字节流的订阅，dispose 时需要取消
  StreamSubscription? _parseSubscription;

  // ========== 数据缓冲区 ==========
  /// 所有接收到的数据点（按 index 递增排序）
  final List<PlotDataPoint> _dataPoints = [];
  /// 数据缓冲区最大点数，超过后从头部批量移除
  static const int _maxPoints = 100000;
  /// 下一个数据点的索引序号（单调递增）
  int _nextIndex = 0;
  /// 绘图开始时间，用于计算时间戳
  DateTime? _startTime;

  // ========== 速率统计（基于计数器，避免遍历列表）==========
  /// 速率统计样本列表，用于计算实时接收速率
  final List<_RateSample> _rateSamples = [];
  /// 速率样本最大数量（最近1000个）
  static const int _maxRateSamples = 1000;


  // ========== 当前数据实际通道数 ==========
  /// 当前数据中实际出现的最大通道数（用于动态显示通道面板）
  int _activeChannelCount = 0;

  // ========== 视口 ==========
  /// 当前绘图视口，定义可见的 X/Y 数据范围
  PlotViewport viewport = PlotViewport(
    xMin: 0,
    xMax: 1000,
    yMin: 0,
    yMax: 32768,
  );

  // ========== 视口历史记录（用于撤回） ==========
  /// 视口历史记录栈，每次缩放/平移前保存当前状态
  final List<PlotViewport> _viewportHistory = [];
  /// 视口历史最大深度
  static const int _maxHistory = 50;

  // ========== 通道配置 ==========
  /// 通道配置列表（默认16通道），包含颜色、可见性、缩放、偏移等
  final List<ChannelConfig> channels = ChannelConfig.createDefaults();

  // ========== 状态 ==========
  /// 是否正在绘图（数据源运行中）
  bool _isPlotting = false;
  /// 是否显示网格
  bool _showGrid = true;
  /// 是否使用随机数据源（而非串口）
  bool _useRandomSource = false;

  // ========== 高级设置 ==========
  /// UI 刷新帧率 (fps)，范围 10~60，默认 30
  int _refreshFps = 30;
  /// 网格密度: 'sparse'(稀疏), 'normal'(普通), 'dense'(密集)
  String _gridDensity = 'normal';
  /// 抗锯齿开关，默认开启，通道>8时自动关闭但可手动修改
  bool _antiAliasEnabled = true;
  /// 最新点跟随模式：最新数据点保持在视口 3/4 宽度处
  bool _followEnabled = false;
  /// 单垂直光标开关（鼠标悬停显示垂直线+tooltip）
  bool _vCursorEnabled = false;
  /// X-X 测量开关（两条垂直测量线）
  bool _xMeasurementEnabled = false;
  /// Y-Y 测量开关（两条水平测量线）
  bool _yMeasurementEnabled = false;
  /// 统计测量开关（Max/Min/Avg）
  bool _statsEnabled = false;
  /// 统计范围开关（限定统计的 X 范围）
  bool _statsRangeEnabled = false;
  /// 统计范围左边界
  double? _statsX1;
  /// 统计范围右边界
  double? _statsX2;
  /// 当前光标模式
  // cursorMode 已废弃，保留 CursorMode.follow 用于垂直光标标识
  /// 当前光标状态（由各种光标模式共用）
  CursorState? _cursor;
  /// 当前解析器类型
  ParserType _parserType = ParserType.fireWater;
  /// 解析器配置（FireWater 和固定帧共用）
  final ParserConfig _parserConfig = ParserConfig.fireWaterDefault();

  // ========== 缩放按钮状态 ==========
  /// 框选放大模式开关
  bool _boxZoomEnabled = false;

  // ========== 数据源配置 ==========
  /// 数据源配置（串口/随机源切换、随机源频率等）
  final DataSourceConfig _sourceConfig = DataSourceConfig();

  // ========== x-x / y-y 光标 ==========
  /// X-X 测量第一条垂直线位置（数据坐标）
  double? _xCursor1;
  /// X-X 测量第二条垂直线位置（数据坐标）
  double? _xCursor2;
  /// Y-Y 测量第一条水平线位置（数据坐标）
  double? _yCursor1;
  /// Y-Y 测量第二条水平线位置（数据坐标）
  double? _yCursor2;

  // ========== 定时刷新 ==========
  /// 定时刷新器，用于光标跟随和停止后的交互响应
  Timer? _refreshTimer;
  /// 定时刷新间隔（ms），无数据时保持 UI 响应
  static const int _refreshIntervalMs = 100;

  // ========== UI 刷新降频（数据不丢失）==========
  /// 待刷新的数据包计数，达到批量大小后触发 UI 刷新
  int _pendingNotifyCount = 0;
  /// 动态批量大小：控制 UI 刷新频率，数据始终全部接收
  /// 根据 _refreshFps 计算：batchSize = targetRate / fps
  /// 串口数据源使用固定批量大小（1000Hz / 30fps ≈ 33），避免依赖 randomIntervalMs
  int get _notifyBatchSize {
    if (_useRandomSource) {
      // 随机数据源：根据配置的频率计算
      final intervalMs = _sourceConfig.randomIntervalMs;
      final targetRate = 1000.0 / intervalMs; // 每秒目标包数
      final batch = (targetRate / _refreshFps).round().clamp(1, 1000);
      return batch;
    } else {
      // 串口数据源：使用固定批量，假设典型速率 1000Hz
      // 1000Hz / 30fps = 33 帧/刷新
      const assumedRate = 1000.0;
      final batch = (assumedRate / _refreshFps).round().clamp(10, 200);
      return batch;
    }
  }
  /// Fallback 定时器：确保数据流中断时 UI 仍能刷新
  Timer? _notifyTimer;

  // ========== 接收速率调试统计 ==========
  /// 上次日志报告时间
  DateTime? _lastRateLogTime;
  /// 上次日志报告时的 _nextIndex
  int _lastRateLogIndex = 0;
  /// 接收字节数统计（用于排查串口读取性能）
  int _totalReceivedBytes = 0;
  /// 上次日志报告时的接收字节数
  int _lastRateLogBytes = 0;

  /// 创建 PlotViewModel 并初始化数据源管理器、加载设置、启动定时刷新
  PlotViewModel(super.serialService) {
    _sourceManager = DataSourceManager(serialService);
    _loadSettings();
    _startRefreshTimer();
  }

  /// 从 AppSettings 加载绘图配置
  void _loadSettings() {
    final settings = AppSettings();
    _refreshFps = settings.refreshFps;
    _showGrid = settings.showGrid;
    _gridDensity = settings.gridDensity;
    _useRandomSource = settings.useRandomSource;
    _followEnabled = settings.followEnabled;
    _sourceConfig.randomIntervalMs = (1000.0 / settings.randomFrequency).round().clamp(1, 1000);
    viewport = PlotViewport(
      xMin: settings.xMin,
      xMax: settings.xMax,
      yMin: settings.yMin,
      yMax: settings.yMax,
    );
    // 同步到 serialService
    serialService.useRandomSource = _useRandomSource;
  }

  /// 保存绘图配置到 AppSettings
  void _saveSettings() {
    final settings = AppSettings();
    settings.refreshFps = _refreshFps;
    settings.showGrid = _showGrid;
    settings.gridDensity = _gridDensity;
    settings.useRandomSource = _useRandomSource;
    settings.randomFrequency = randomFrequency;
    settings.followEnabled = _followEnabled;
    // vCursorEnabled 不持久化
    settings.xMin = viewport.xMin;
    settings.xMax = viewport.xMax;
    settings.yMin = viewport.yMin;
    settings.yMax = viewport.yMax;
    settings.save();
  }

  // ========== Getters ==========
  /// 不可修改的数据点列表（供 UI 读取）
  List<PlotDataPoint> get dataPoints => List.unmodifiable(_dataPoints);
  bool get isPlotting => _isPlotting;
  bool get showGrid => _showGrid;
  bool get useRandomSource => _useRandomSource;
  int get refreshFps => _refreshFps;
  String get gridDensity => _gridDensity;
  bool get boxZoomEnabled => _boxZoomEnabled;
  bool get followEnabled => _followEnabled;
  bool get vCursorEnabled => _vCursorEnabled;
  bool get xMeasurementEnabled => _xMeasurementEnabled;
  bool get yMeasurementEnabled => _yMeasurementEnabled;
  bool get statsEnabled => _statsEnabled;
  bool get statsRangeEnabled => _statsRangeEnabled;
  double? get statsX1 => _statsX1;
  double? get statsX2 => _statsX2;
  bool get antiAliasEnabled => _antiAliasEnabled;
  CursorState? get cursor => _cursor;
  ParserType get parserType => _parserType;
  ParserConfig get parserConfig => _parserConfig;
  /// 当前数据点总数
  int get pointCount => _dataPoints.length;
  /// 当前数据中实际出现的最大通道数
  int get activeChannelCount => _activeChannelCount;

  /// 随机源频率（Hz），由间隔毫秒数换算
  double get randomFrequency => 1000.0 / _sourceConfig.randomIntervalMs;

  /// X-X 测量第一条垂直线位置
  double? get xCursor1 => _xCursor1;
  /// X-X 测量第二条垂直线位置
  double? get xCursor2 => _xCursor2;
  /// Y-Y 测量第一条水平线位置
  double? get yCursor1 => _yCursor1;
  /// Y-Y 测量第二条水平线位置
  double? get yCursor2 => _yCursor2;

  /// 是否有可撤回的视口历史
  bool get canUndoZoom => _viewportHistory.isNotEmpty;

  /// 状态栏文本，显示当前视口范围、数据点数、接收速率、运行状态
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
          Future.microtask(() => notifyListeners());
        }
      },
    );
  }

  /// 停止定时刷新器
  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  // ========== 数据源控制 ==========
  /// 切换随机数据源开关
  ///
  /// 如果正在绘图，会自动重启数据源以应用变更。
  /// 同时同步更新 serialService 的随机源状态。
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
    _saveSettings();

    // 如果正在绘图，重启数据源
    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置随机源频率（Hz），范围 1~10000
  void setRandomFrequency(double hz) {
    final clampedHz = hz.clamp(1.0, 10000.0);
    final intervalMs = (1000.0 / clampedHz).round().clamp(1, 1000);
    _sourceConfig.randomIntervalMs = intervalMs;
    _sourceManager.updateConfig(_sourceConfig);
    _saveSettings();

    // 如果正在绘图，重启数据源以应用新频率
    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  // ========== 解析器控制 ==========
  /// 切换解析器类型（FireWater / 固定帧）
  ///
  /// 如果正在绘图，会自动重启以应用新解析器。
  void setParserType(ParserType type) {
    _parserType = type;
    _parserConfig.type = type;

    if (_isPlotting) {
      _restartPlotting();
    }
    Future.microtask(() => notifyListeners());
  }

  /// 更新解析器配置并同步到数据源
  ///
  /// 同时更新随机数据源的通道数以匹配 FireWater 配置。
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
    Future.microtask(() => notifyListeners());
  }

  // ========== 绘图控制 ==========
  /// 开始绘图
  ///
  /// 流程：
  /// 1. 检查数据源可用性（串口已连接或随机源已启用）
  /// 2. 清空旧数据、重置视口和光标
  /// 3. 创建解析器并启动数据源
  /// 4. 连接数据流：DataSourceManager → Parser → _dataPoints
  /// 5. 启动定时刷新
  void startPlotting() {
    if (_isPlotting) return;

    // 检查是否有数据源
    if (!serialService.isConnected && !_useRandomSource) {
      AppLogger().warning('无可用数据源，请先连接串口或启用随机数据源', category: 'PLOT');
      return;
    }

    // 清空旧数据
    _dataPoints.clear();
    _rateSamples.clear();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = DateTime.now();

    // 重置速率统计
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;

    // 重置视口
    viewport = viewport.reset();
    _viewportHistory.clear();

    // 重置光标（垂直光标为临时功能，每次开始绘图时关闭）
    _vCursorEnabled = false;
    _cursor = null;
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;

    // 创建解析器
    _parser = _createParser();

    // 发送协议初始化数据（如果有）
    _sendProtocolInitData();

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
    // 开始绘图时自动停止原始数据接收
    if (serialService.isRawReceiving) {
      serialService.stopRawReceiving();
    }
    Future.microtask(() => serialService.notifyListeners());
    _startRefreshTimer();
    AppLogger().info('开始绘图', category: 'PLOT');
    Future.microtask(() => notifyListeners());
  }

  /// 停止绘图
  ///
  /// 取消数据流订阅、停止数据源、释放解析器，但保持定时刷新运行
  /// 以确保交互响应及时。
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
    Future.microtask(() => notifyListeners());
  }

  /// 重启绘图（用于配置变更时）
  void _restartPlotting() {
    stopPlotting();
    startPlotting();
  }

  /// 清空所有数据、速率统计、视口和光标
  void clearData() {
    _dataPoints.clear();
    _rateSamples.clear();
    _nextIndex = 0;
    _activeChannelCount = 0;
    _startTime = null;
    _lastRateLogTime = null;
    _lastRateLogIndex = 0;
    _totalReceivedBytes = 0;
    _lastRateLogBytes = 0;
    viewport = viewport.reset();
    _viewportHistory.clear();
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    Future.microtask(() => notifyListeners());
  }

  // ========== 数据接收 ==========
  /// 处理解析器输出的数据包
  ///
  /// 每包数据都处理（不丢失），但 UI 刷新按 [_notifyBatchSize] 批量触发：
  /// - 添加数据点到缓冲区，超限时从头部批量移除
  /// - 更新速率统计样本
  /// - 更新实际通道数（>8时自动关闭抗锯齿）
  /// - 跟随模式下自动平移视口
  /// - 批量计数达到阈值或 fallback 定时器到期时触发 notifyListeners()
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

    // 统计接收字节数
    _totalReceivedBytes += result.bytesConsumed;

    // 记录速率统计样本
    _rateSamples.add(_RateSample(_nextIndex - 1, timestamp.toInt()));
    while (_rateSamples.length > _maxRateSamples) {
      _rateSamples.removeAt(0);
    }


    // 更新实际通道数
    if (point.channelCount > _activeChannelCount) {
      _activeChannelCount = point.channelCount;
      // 通道数>8时自动关闭抗锯齿（用户可手动重新开启）
      if (_activeChannelCount > 8 && _antiAliasEnabled) {
        _antiAliasEnabled = false;
      }
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

    // 每秒输出一次接收速率日志（调试用）
    if (_lastRateLogTime == null) {
      _lastRateLogTime = now;
      _lastRateLogIndex = _nextIndex;
      _lastRateLogBytes = _totalReceivedBytes;
    } else if (now.difference(_lastRateLogTime!).inMilliseconds >= 1000) {
      final elapsedMs = now.difference(_lastRateLogTime!).inMilliseconds;
      final receivedPoints = _nextIndex - _lastRateLogIndex;
      final receivedBytes = _totalReceivedBytes - _lastRateLogBytes;
      final rate = receivedPoints * 1000.0 / elapsedMs;
      AppLogger().info(
        '接收统计: ${rate.toStringAsFixed(1)} 点/s | '
        '$_pendingNotifyCount 待刷新 | batch=$batchSize | '
        '${receivedBytes}B/s | 缓冲区=${_dataPoints.length}点',
        category: 'PLOT',
      );
      _lastRateLogTime = now;
      _lastRateLogIndex = _nextIndex;
      _lastRateLogBytes = _totalReceivedBytes;
    }

    if (_pendingNotifyCount >= batchSize) {
      _pendingNotifyCount = 0;
      _notifyTimer?.cancel();
      _notifyTimer = null;
      Future.microtask(() => notifyListeners());
    } else if (_notifyTimer == null) {
      // fallback timer：确保即使数据流中断也能刷新UI
      final delayMs = (1000 / _refreshFps).round();
      _notifyTimer = Timer(Duration(milliseconds: delayMs), () {
        _pendingNotifyCount = 0;
        _notifyTimer = null;
        Future.microtask(() => notifyListeners());
      });
    }
  }

  /// 根据当前解析器类型创建对应的解析器实例
  IDataParser _createParser() {
    switch (_parserType) {
      case ParserType.fireWater:
        return FireWaterParser(_parserConfig);
      case ParserType.fixedFrame:
        return FixedFrameParser(_parserConfig);
      case ParserType.jackFourChannel:
        return JackFourChannelParser(_parserConfig);
    }
  }

  // ========== 协议启动初始化数据发送（预留接口，供后续协议扩展） ==========

  /// 协议启动时发送初始化数据
  ///
  /// 某些协议（如JACK四通道）需要在开始绘图前发送配置数据。
  /// 返回是否发送成功，发送失败不影响后续绘图流程。
  Future<bool> _sendProtocolInitData() async {
    switch (_parserType) {
      case ParserType.jackFourChannel:
        return _sendJackFourChannelInitData();
      default:
        return true; // 其他协议无需发送
    }
  }

  /// 发送 JACK四通道初始化数据
  ///
  /// 格式：10字节
  /// [Ch0_ID_Low][Ch0_ID_High][Ch1_ID_Low][Ch1_ID_High][Ch2_ID_Low][Ch2_ID_High][Ch3_ID_Low][Ch3_ID_High][CRC_Low][CRC_High]
  /// 前8字节为4个通道号（小端序uint16），后2字节为前8字节的CRC16/MODBUS（小端序）
  Future<bool> _sendJackFourChannelInitData() async {
    try {
      // 构造 10 字节数据
      final bytes = Uint8List(10);
      final buffer = ByteData.sublistView(bytes);

      for (int i = 0; i < 4; i++) {
        buffer.setUint16(i * 2, _parserConfig.jackFourChannelIds[i], Endian.little);
      }

      // 计算前8字节的CRC16/MODBUS
      final dataBytes = Uint8List.sublistView(bytes, 0, 8);
      final crc = calculateCrc(dataBytes, crc16Polys['CRC-16/MODBUS']!);

      // CRC 小端序写入
      bytes[8] = crc & 0xFF;
      bytes[9] = (crc >> 8) & 0xFF;

      // 通过 SerialService 发送
      serialService.send(bytes);

      AppLogger().info(
        'JACK四通道初始化数据已发送: ${_bytesToHex(bytes)}',
        category: 'PLOT',
      );
      return true;
    } catch (e) {
      AppLogger().error('JACK四通道初始化数据发送失败: $e', category: 'PLOT');
      return false;
    }
  }

  /// 字节转16进制字符串（用于日志）
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  // ========== 视口控制（带历史记录） ==========
  /// 保存当前视口到历史记录栈（用于撤回）
  void _saveViewport() {
    _viewportHistory.add(viewport.copy());
    if (_viewportHistory.length > _maxHistory) {
      _viewportHistory.removeAt(0);
    }
  }

  /// 更新视口并保存到历史记录
  ///
  /// [fromDrag] 为 true 时表示来自用户拖动交互，跳过配置保存和
  /// 历史记录，避免频繁文件写入导致的卡顿。拖动结束后再统一保存。
  void updateViewport(PlotViewport newViewport, {bool fromDrag = false}) {
    final oldXMin = viewport.xMin;
    // 保存当前的偏移通道数量，避免 copy() 丢失
    final offsetChannelCount = viewport.offsetChannelCount;
    if (!fromDrag) {
      _saveViewport();
    }
    viewport = newViewport.copy();
    viewport.setOffsetChannelCount(offsetChannelCount);
    if (!fromDrag) {
      _saveSettings();
    }
    AppLogger().trace('updateViewport: oldXMin=${oldXMin.toStringAsFixed(1)} → newXMin=${viewport.xMin.toStringAsFixed(1)} | delta=${(oldXMin - viewport.xMin).toStringAsFixed(1)} | fromDrag=$fromDrag', category: 'PLOT');
    if (fromDrag) {
      // 拖动时同步通知，避免微任务堆积
      notifyListeners();
    } else {
      Future.microtask(() => notifyListeners());
    }
  }

  /// 拖动结束后保存视口配置
  ///
  /// 在 PlotGestureHandler._handlePointerUp 中调用，将拖动期间的
  /// 最终视口保存到配置和历史记录。
  void saveDragViewport() {
    _saveViewport();
    _saveSettings();
    AppLogger().trace('saveDragViewport: xMin=${viewport.xMin.toStringAsFixed(1)}', category: 'PLOT');
  }

  /// 重置视口到默认值并保存历史记录
  void resetViewport() {
    _saveViewport();
    viewport = viewport.reset();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 撤回上次缩放
  void undoZoom() {
    if (_viewportHistory.isEmpty) return;
    final previous = _viewportHistory.removeLast();
    viewport = previous.copy();
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X 轴放大
  void zoomXIn() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = viewport.zoomX(0.8, centerX);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X 轴缩小
  void zoomXOut() {
    _saveViewport();
    final centerX = viewport.xMin + viewport.xRange / 2;
    viewport = viewport.zoomX(1.25, centerX);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴放大
  void zoomYIn() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(0.8, centerY);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// Y 轴缩小
  void zoomYOut() {
    _saveViewport();
    final centerY = viewport.yMin + viewport.yRange / 2;
    viewport = viewport.zoomY(1.25, centerY);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置框选放大开关
  void setBoxZoomEnabled(bool value) {
    _boxZoomEnabled = value;
    Future.microtask(() => notifyListeners());
  }

  /// Y轴自适应：保持X轴不变，调整Y轴使屏幕内所有数据可见
  void fitYAxis() {
    if (_dataPoints.isEmpty) return;
    final visiblePoints = _dataPoints.where((p) {
      return p.index >= viewport.xMin && p.index <= viewport.xMax;
    }).toList();
    if (visiblePoints.isEmpty) return;

    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final point in visiblePoints) {
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        final v = point.values[i] * channels[i].yScale + channels[i].yOffset;
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }
    if (minY == double.infinity || maxY == double.negativeInfinity) return;

    _saveViewport();
    final padding = (maxY - minY) * 0.1;
    viewport = viewport.copyWith(
      yMin: minY - padding,
      yMax: maxY + padding,
    );
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// X轴自适应：保持Y轴不变，调整X轴使所有数据可见
  void fitXAxis() {
    if (_dataPoints.isEmpty) return;
    final minX = _dataPoints.first.index.toDouble();
    final maxX = _dataPoints.last.index.toDouble();

    _saveViewport();
    viewport = viewport.copyWith(
      xMin: minX,
      xMax: maxX + 1,
    );
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 全自适应：调整X和Y使所有可见通道数据完全显示
  void fitAll() {
    if (_dataPoints.isEmpty) return;

    // X范围
    final minX = _dataPoints.first.index.toDouble();
    final maxX = _dataPoints.last.index.toDouble();

    // Y范围（只计算可见通道）
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final point in _dataPoints) {
      for (int i = 0; i < point.values.length && i < channels.length; i++) {
        if (!channels[i].visible) continue;
        final v = point.values[i] * channels[i].yScale + channels[i].yOffset;
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }

    _saveViewport();
    if (minY != double.infinity && maxY != double.negativeInfinity) {
      final padding = (maxY - minY) * 0.1;
      viewport = viewport.copyWith(
        xMin: minX,
        xMax: maxX + 1,
        yMin: minY - padding,
        yMax: maxY + padding,
      );
    } else {
      viewport = viewport.copyWith(
        xMin: minX,
        xMax: maxX + 1,
      );
    }
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置跟随开关
  void setFollowEnabled(bool value) {
    _followEnabled = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置单垂直光标开关
  ///
  /// 光标开关为临时功能，不保存到配置。
  void setVCursorEnabled(bool value) {
    _vCursorEnabled = value;
    _cursor = null;
    Future.microtask(() => notifyListeners());
  }

  // ========== 通道控制 ==========
  /// 设置通道可见性
  void setChannelVisible(int index, bool visible) {
    if (index < 0 || index >= channels.length) return;
    channels[index].visible = visible;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道颜色
  void setChannelColor(int index, Color color) {
    if (index < 0 || index >= channels.length) return;
    channels[index].color = color;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道是否显示连线
  void setChannelShowLine(int index, bool show) {
    if (index < 0 || index >= channels.length) return;
    channels[index].showLine = show;
    Future.microtask(() => notifyListeners());
  }

  /// 一键设置所有通道的显示状态
  void setAllChannelsVisible(bool visible) {
    for (final ch in channels) {
      ch.visible = visible;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道别名
  void setChannelAlias(int index, String alias) {
    if (index < 0 || index >= channels.length) return;
    channels[index].alias = alias;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴偏移
  void setChannelYOffset(int index, double offset) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yOffset = offset;
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道偏移功能开关
  void setChannelOffsetEnabled(int index, bool enabled) {
    if (index < 0 || index >= channels.length) return;
    channels[index].offsetEnabled = enabled;
    if (!enabled) {
      // 关闭偏置时，偏移和缩放都归位
      channels[index].yOffset = 0;
      channels[index].yScale = 1.0;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置通道 Y 轴缩放
  void setChannelYScale(int index, double scale) {
    if (index < 0 || index >= channels.length) return;
    channels[index].yScale = scale;
    Future.microtask(() => notifyListeners());
  }

  /// 缩放通道 Y 轴（滚轮缩放，按比例调整）
  void zoomChannelYScale(int index, double scaleDelta) {
    if (index < 0 || index >= channels.length) return;
    final newScale = (channels[index].yScale * scaleDelta).clamp(0.001, 1000.0);
    channels[index].yScale = newScale;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 JACK四通道的通道号
  void setJackFourChannelId(int index, int channelId) {
    if (index < 0 || index >= 4) return;
    _parserConfig.jackFourChannelIds[index] = channelId & 0xFFFF;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 JACK四通道的通道数据类型
  void setJackFourChannelType(int index, DataType type) {
    if (index < 0 || index >= 4) return;
    if (type != DataType.uint16 && type != DataType.int16) return;
    _parserConfig.jackFourChannelTypes[index] = type;
    // 同步更新通道配置的数据类型（影响绘图显示）
    if (index < channels.length) {
      channels[index].dataType = type;
    }
    Future.microtask(() => notifyListeners());
  }

  // ========== 显示控制 ==========
  /// 设置网格显示开关
  void setShowGrid(bool show) {
    _showGrid = show;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置 UI 刷新帧率（10~60 fps）
  void setRefreshFps(int fps) {
    _refreshFps = fps.clamp(10, 60);
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 设置网格密度（sparse/normal/dense）
  void setGridDensity(String density) {
    const valid = {'sparse', 'normal', 'dense'};
    if (valid.contains(density)) {
      _gridDensity = density;
      _saveSettings();
      Future.microtask(() => notifyListeners());
    }
  }

  /// 设置抗锯齿开关
  void setAntiAlias(bool value) {
    _antiAliasEnabled = value;
    _saveSettings();
    Future.microtask(() => notifyListeners());
  }

  /// 切换 X-X 测量开关
  ///
  /// 开启时自动在视口中心初始化两条测量线，间隔为 X 范围的 1/4。
  void toggleXMeasurement() {
    _xMeasurementEnabled = !_xMeasurementEnabled;
    if (_xMeasurementEnabled && _xCursor1 == null) {
      // 自动初始化两条线，间隔为X范围的1/4
      final range = viewport.xRange;
      final center = viewport.xMin + range / 2;
      _xCursor1 = center - range / 8;
      _xCursor2 = center + range / 8;
    }
    if (!_xMeasurementEnabled) {
      _xCursor1 = null;
      _xCursor2 = null;
      // 如果垂直光标也关闭，清除 cursor
      if (!_vCursorEnabled) _cursor = null;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换 Y-Y 测量开关
  ///
  /// 开启时自动在视口中心初始化两条测量线，Y2 在上（值更大）。
  void toggleYMeasurement() {
    _yMeasurementEnabled = !_yMeasurementEnabled;
    if (_yMeasurementEnabled && _yCursor1 == null) {
      // 自动初始化两条线，Y2在上（值更大），间隔为Y范围的1/4
      final range = viewport.yRange;
      final center = viewport.yMin + range / 2;
      _yCursor1 = center - range / 8;  // 下方（值小）
      _yCursor2 = center + range / 8;  // 上方（值大）
    }
    if (!_yMeasurementEnabled) {
      _yCursor1 = null;
      _yCursor2 = null;
      // 如果垂直光标也关闭，清除 cursor
      if (!_vCursorEnabled) _cursor = null;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换统计测量开关
  ///
  /// 开启时默认统计整个波形（当前视口范围）。
  void toggleStats() {
    _statsEnabled = !_statsEnabled;
    if (_statsEnabled && _statsX1 == null) {
      // 默认统计整个波形，范围设为当前视口
      _statsX1 = viewport.xMin;
      _statsX2 = viewport.xMax;
    }
    if (!_statsEnabled) {
      _statsX1 = null;
      _statsX2 = null;
      _statsRangeEnabled = false;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 切换统计范围开关
  ///
  /// 开启时 S1/S2 初始位置在视口 1/4 和 3/4 处；
  /// 关闭时恢复为整个视口范围。
  void toggleStatsRange() {
    if (!_statsEnabled) return;
    _statsRangeEnabled = !_statsRangeEnabled;
    if (_statsRangeEnabled) {
      // S1/S2 初始位置在 1/4 和 3/4 处
      final range = viewport.xRange;
      _statsX1 = viewport.xMin + range * 0.25;
      _statsX2 = viewport.xMin + range * 0.75;
    } else {
      // 关闭范围时恢复为整个视口
      _statsX1 = viewport.xMin;
      _statsX2 = viewport.xMax;
    }
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围左边界
  void setStatsX1(double x) {
    _statsX1 = x;
    Future.microtask(() => notifyListeners());
  }

  /// 设置统计范围右边界
  void setStatsX2(double x) {
    _statsX2 = x;
    Future.microtask(() => notifyListeners());
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
      screenPosition: screenPosition,
      channelValues: channelValues,
      hasData: hasData,
    );
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  /// 更新光标状态（由外部直接设置）
  void updateCursor(CursorState? cursor) {
    _cursor = cursor;
    // 使用微任务延迟通知，避免在指针事件回调中直接触发 rebuild
    scheduleMicrotask(notifyListeners);
  }

  // ========== x-x / y-y 光标控制 ==========
  /// 设置 X1 光标位置（拖动时使用）
  ///
  /// 同时保留 xCursor2 和 yCursor2，避免拖动时覆盖另一组测量线。
  void setXCursor1(double x) {
    _xCursor1 = x;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 X2 光标位置（拖动时使用）
  void setXCursor2(double x) {
    _xCursor2 = x;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y1 光标位置（拖动时使用）
  void setYCursor1(double y) {
    _yCursor1 = y;
    Future.microtask(() => notifyListeners());
  }

  /// 设置 Y2 光标位置（拖动时使用）
  void setYCursor2(double y) {
    _yCursor2 = y;
    Future.microtask(() => notifyListeners());
  }

  /// 清除所有光标和测量线
  void clearCursors() {
    _xCursor1 = null;
    _xCursor2 = null;
    _yCursor1 = null;
    _yCursor2 = null;
    _cursor = null;
    Future.microtask(() => notifyListeners());
  }

  /// 测量信息文本，显示 X1/X2/Y1/Y2 值和 delta
  String? get measurementText {
    final buffer = StringBuffer();
    bool hasData = false;
    
    if (_xMeasurementEnabled && _xCursor1 != null && _xCursor2 != null) {
      final dx = _xCursor2! - _xCursor1!;
      buffer.writeln('X1 = ${_xCursor1!.toStringAsFixed(1)}');
      buffer.writeln('X2 = ${_xCursor2!.toStringAsFixed(1)}');
      buffer.writeln('ΔX = ${dx.toStringAsFixed(1)}');
      hasData = true;
    }
    
    if (_yMeasurementEnabled && _yCursor1 != null && _yCursor2 != null) {
      final dy = _yCursor2! - _yCursor1!;
      if (hasData) buffer.writeln('---');
      buffer.writeln('Y1 = ${_yCursor1!.toStringAsFixed(1)}');
      buffer.writeln('Y2 = ${_yCursor2!.toStringAsFixed(1)}');
      buffer.writeln('ΔY = ${dy.toStringAsFixed(1)}');
      hasData = true;
    }
    
    return hasData ? buffer.toString().trim() : null;
  }

  /// 统计测量信息文本，显示各通道最大值、最小值、平均值
  String? get statsText {
    if (!_statsEnabled || _dataPoints.isEmpty) return null;

    final xMin = _statsRangeEnabled && _statsX1 != null && _statsX2 != null
        ? (_statsX1! < _statsX2! ? _statsX1! : _statsX2!)
        : null;
    final xMax = _statsRangeEnabled && _statsX1 != null && _statsX2 != null
        ? (_statsX1! > _statsX2! ? _statsX1! : _statsX2!)
        : null;

    final buffer = StringBuffer();
    bool hasVisibleChannel = false;
    int commonCount = 0;

    // 先计算统一的样本数（所有可见通道在范围内的点数应该相同）
    for (final point in _dataPoints) {
      if (xMin != null && point.index < xMin) continue;
      if (xMax != null && point.index > xMax) continue;
      commonCount++;
    }

    if (commonCount == 0) return null;

    for (int i = 0; i < channels.length; i++) {
      if (!channels[i].visible) continue;

      double? maxVal, minVal, sum;
      int count = 0;

      for (final point in _dataPoints) {
        if (i >= point.channelCount) continue;
        if (xMin != null && point.index < xMin) continue;
        if (xMax != null && point.index > xMax) continue;

        final val = point.values[i];
        maxVal = maxVal == null || val > maxVal ? val : maxVal;
        minVal = minVal == null || val < minVal ? val : minVal;
        sum = (sum ?? 0) + val;
        count++;
      }

      if (count == 0) continue;
      if (hasVisibleChannel) buffer.writeln('---');
      hasVisibleChannel = true;

      buffer.writeln('Ch$i:');
      buffer.writeln('  Max: ${maxVal!.toStringAsFixed(2)}');
      buffer.writeln('  Min: ${minVal!.toStringAsFixed(2)}');
      buffer.writeln('  Avg: ${(sum! / count).toStringAsFixed(2)}');
    }

    if (!hasVisibleChannel) return null;

    // 统一显示 N 和 Range
    buffer.writeln('---');
    buffer.writeln('N: $commonCount');
    if (_statsRangeEnabled && _statsX1 != null && _statsX2 != null) {
      buffer.writeln('Range: ${xMin!.toStringAsFixed(1)} ~ ${xMax!.toStringAsFixed(1)}');
    }

    return buffer.toString().trim();
  }

  // ========== 导出 ==========
  /// 导出数据到 CSV 文件
  ///
  /// [selectedPath] 为 null 时，自动保存到可执行文件目录下的 exports 文件夹。
  /// 返回实际保存的文件路径，失败返回 null。
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

  // ========== 导入 ==========
  /// 从 CSV 文件导入数据
  ///
  /// 支持格式：表头 x,y1,y2,...，最大16通道。
  /// 导入成功后会清空现有数据并替换，返回 null；失败返回错误信息。
  Future<String?> importFromCsv(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return '文件不存在';
      }

      final lines = await file.readAsLines();
      if (lines.isEmpty) {
        return '文件为空';
      }

      // 解析表头
      final header = lines.first.trim();
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
      int index = 0;
      for (int i = 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;

        final parts = line.split(',');
        if (parts.length < 2) continue;

        final xValue = double.tryParse(parts[0].trim());
        if (xValue == null) continue;

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

        importedPoints.add(PlotDataPoint(
          index: index,
          timestamp: xValue,
          values: values,
        ));
        index++;
      }

      if (importedPoints.isEmpty) {
        return '未找到有效数据行';
      }

      // 清空现有数据并替换
      _dataPoints.clear();
      _dataPoints.addAll(importedPoints);
      _nextIndex = importedPoints.length;
      _activeChannelCount = channelCount;
      _startTime = null;

      // 重置视口以显示全部数据
      viewport = PlotViewport(
        xMin: 0,
        xMax: importedPoints.length.toDouble(),
        yMin: _calculateMinY(importedPoints),
        yMax: _calculateMaxY(importedPoints),
      );
      _viewportHistory.clear();

      // 重置光标
      _cursor = null;
      _xCursor1 = null;
      _xCursor2 = null;
      _yCursor1 = null;
      _yCursor2 = null;

      AppLogger().info(
        'CSV 导入成功: $filePath, ${importedPoints.length} 点, $channelCount 通道',
        category: 'PLOT',
      );
      Future.microtask(() => notifyListeners());
      return null;
    } catch (e) {
      AppLogger().error('CSV 导入失败: $e', category: 'PLOT');
      return '解析错误: $e';
    }
  }

  /// 计算数据点列表的最小 Y 值
  double _calculateMinY(List<PlotDataPoint> points) {
    double min = double.infinity;
    for (final p in points) {
      for (final v in p.values) {
        if (v < min) min = v;
      }
    }
    return min == double.infinity ? 0 : min;
  }

  /// 计算数据点列表的最大 Y 值
  double _calculateMaxY(List<PlotDataPoint> points) {
    double max = double.negativeInfinity;
    for (final p in points) {
      for (final v in p.values) {
        if (v > max) max = v;
      }
    }
    return max == double.negativeInfinity ? 1 : max;
  }

  /// 释放所有资源：取消订阅、停止数据源、释放解析器、停止定时器
  /// 
  /// 注意：全局单例模式下不修改 serialService.isPlotting，
  /// 避免页面切换时误停绘图状态。
  @override
  void dispose() {
    _parseSubscription?.cancel();
    _parseSubscription = null;
    _sourceManager.stop();
    _parser?.dispose();
    _parser = null;
    _isPlotting = false;
    // 全局单例模式下不重置 serialService.isPlotting
    // serialService.isPlotting = false;
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
