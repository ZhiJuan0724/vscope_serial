import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/data_packet.dart';
import '../data/models/retention_usage.dart';
import '../data/models/serial_config.dart';
import 'app_notifications.dart';
import 'app_settings.dart';
import 'native_serial_reader.dart';
import 'raw_receive_session.dart';
import 'serial_connection_coordinator.dart';
import 'serial_port_catalog.dart';
import 'serial_transport.dart';
import 'ymodem_service.dart';
import 'windows_code_page_codec.dart';

enum SendDisplaySource { user, plot }

/// 当前独占串口接收链路的页面。
///
/// 同一时刻只能有一个页面消费串口数据，避免数据收发、Shell 与绘图
/// 在切换页面后继续并行运行或争抢同一批字节。
enum SerialActivityOwner { none, rawData, shell, plot }

typedef ExportProgressCallback = void Function(double progress);

class _ConnectionCancelled implements Exception {
  const _ConnectionCancelled();
}

String _decodeBytesWithEncoding(Uint8List data, String encoding) {
  String decodeOrFallback(String Function(Uint8List) decode) {
    try {
      return decode(data);
    } on FormatException {
      return String.fromCharCodes(data);
    }
  }

  return switch (encoding) {
    'UTF-8' => utf8.decode(data, allowMalformed: true),
    'GBK' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 936)),
    'BIG5' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 950)),
    'Shift_JIS' => decodeOrFallback(
      (bytes) => decodeWindowsCodePage(bytes, 932),
    ),
    'EUC-KR' => decodeOrFallback((bytes) => decodeWindowsCodePage(bytes, 949)),
    'Latin-1' => decodeOrFallback(latin1.decode),
    'ASCII' => decodeOrFallback(ascii.decode),
    _ => utf8.decode(data, allowMalformed: true),
  };
}

Uint8List _encodeTextWithEncoding(String text, String encoding) {
  final bytes = switch (encoding) {
    'UTF-8' => utf8.encode(text),
    'GBK' => encodeWindowsCodePage(text, 936),
    'BIG5' => encodeWindowsCodePage(text, 950),
    'Shift_JIS' => encodeWindowsCodePage(text, 932),
    'EUC-KR' => encodeWindowsCodePage(text, 949),
    'Latin-1' => latin1.encode(text),
    'ASCII' => ascii.encode(text),
    _ => utf8.encode(text),
  };
  return Uint8List.fromList(bytes);
}

enum RawShellInputMode {
  line('line', '命令行'),
  key('key', '逐键');

  final String value;
  final String label;
  const RawShellInputMode(this.value, this.label);

  static RawShellInputMode fromString(String value) {
    return value == key.value ? key : line;
  }
}

enum RawShellThemeMode {
  light('light', '浅色'),
  dark('dark', '深色');

  final String value;
  final String label;
  const RawShellThemeMode(this.value, this.label);

  static RawShellThemeMode fromString(String value) {
    return value == dark.value ? dark : light;
  }
}

enum RawShellCursorMode {
  verticalBar('verticalBar', '竖线'),
  underline('underline', '下划线'),
  block('block', '方块');

  final String value;
  final String label;
  const RawShellCursorMode(this.value, this.label);

  static RawShellCursorMode fromString(String value) {
    return switch (value) {
      'block' => block,
      'underline' => underline,
      _ => verticalBar,
    };
  }
}

/// 串口服务 - 全局单例
class SerialService extends ChangeNotifier {
  static final SerialService _instance = SerialService._internal();
  factory SerialService() => _instance;
  SerialService._internal() : this._withTransport(NativeSerialTransport.new);

  @visibleForTesting
  SerialService.forTesting({
    required SerialTransport Function() transportFactory,
  }) : this._withTransport(transportFactory);

  SerialService._withTransport(this._transportFactory) {
    _rawSession = RawReceiveSession(
      onChanged: () {
        Future.microtask(() {
          if (!_disposed) notifyListeners();
        });
      },
      onRetentionLimitReached: () {
        if (isRawReceiving) stopRawReceiving();
      },
    );
    _portCatalog = SerialPortCatalog(
      enumerator: () {
        final debugEnumerator = debugPortEnumerator;
        return debugEnumerator != null
            ? debugEnumerator()
            : NativeSerialReader.listPortsInBackground();
      },
      onChanged: () {
        Future.microtask(() {
          if (!_disposed) notifyListeners();
        });
      },
    );
  }

  // 串口相关
  SerialConfig config = SerialConfig();
  bool isConnected = false;
  bool isConnecting = false;
  final SerialConnectionCoordinator _connectionCoordinator =
      SerialConnectionCoordinator();
  late final SerialPortCatalog _portCatalog;
  NativeSerialPortMonitor? _portMonitor;
  StreamSubscription<void>? _portMonitorSubscription;
  Timer? _portChangeDebounce;
  bool _portDiscoveryStarted = false;
  bool _disposed = false;

  /// 将状态通知推迟到当前同步操作之后，并在服务销毁后静默取消。
  void _notifyListenersSoon() {
    unawaited(
      Future<void>.microtask(() {
        if (!_disposed) notifyListeners();
      }),
    );
  }

  Map<String, String> _portFriendlyNames = const {};
  Future<bool>? _pendingPortDetailsRefresh;
  bool _isRefreshingPortDetails = false;

  final SerialTransport Function() _transportFactory;
  SerialTransport? _transport;
  StreamSubscription? _nativeSubscription;

  /// 仅测试使用：模拟原生串口打开缓慢或失败。
  Future<bool> Function(String port, int baudRate)? debugPortOpener;

  /// 仅测试使用：替换原生串口枚举。
  Future<List<String>> Function()? debugPortEnumerator;

  /// 仅测试使用：替换原生串口详细信息枚举。
  Future<List<NativeSerialPortDetail>> Function()? debugPortDetailsEnumerator;

  /// 仅测试使用：替换原生连接健康检查。
  Future<bool> Function()? debugConnectionHealthChecker;

  /// 仅测试使用：替换原生句柄打开状态。
  bool? debugNativePortOpen;

  List<String> get availablePorts => _portCatalog.ports;
  bool get isRefreshingPorts =>
      _portCatalog.isRefreshing || _isRefreshingPortDetails;

  /// 最近至少成功枚举过一次，当前端口目录可以用于判断设备是否存在。
  bool get hasSuccessfulPortRefresh => _portCatalog.lastSuccessAt != null;

  /// 已选历史端口在最近一次成功枚举结果中不存在。
  ///
  /// 枚举失败时沿用最后一次成功结果，不把暂时无法查询误判为设备拔出。
  bool isPortUnavailable(String port) {
    return hasSuccessfulPortRefresh && !availablePorts.contains(port);
  }

  /// 连接弹窗中的当前选择是否具备明确可连接状态。
  bool get canConnectSelectedPort {
    final port = config.port;
    return port != null &&
        port.isNotEmpty &&
        !isRefreshingPorts &&
        !isPortUnavailable(port);
  }

  String portDisplayLabel(String port, {required bool showDetails}) {
    if (!showDetails) return port;
    final name = _portFriendlyNames[port];
    return name == null || name.isEmpty ? port : '$port: $name';
  }

  String? get portRefreshError => _portCatalog.lastError;
  Duration? get lastPortRefreshDuration => _portCatalog.lastDuration;

  Timer? _receiveLogFlushTimer;
  DateTime? _receiveLogWindowStart;
  bool _receiveLogHighFrequency = false;
  int _receiveLogPacketCount = 0;
  int _receiveLogBytes = 0;
  int _receiveLogFirstPacketBytes = 0;

  Timer? _sendLogFlushTimer;
  DateTime? _sendLogWindowStart;
  bool _sendLogHighFrequency = false;
  int _sendLogPacketCount = 0;
  int _sendLogBytes = 0;
  int _sendLogFirstPacketBytes = 0;

  static const int _ioLogDetectPacketCount = 10;
  static const int _ioLogBatchPacketCount = 50;
  static const Duration _ioLogDetectWindow = Duration(milliseconds: 200);
  static const Duration _ioLogMaxBatchWindow = Duration(seconds: 1);

  static const int minAutoLineBreakIntervalMs =
      RawReceiveSession.minAutoLineBreakIntervalMs;
  static const int defaultAutoLineBreakIntervalMs =
      RawReceiveSession.defaultAutoLineBreakIntervalMs;
  static const int maxAutoLineBreakIntervalMs =
      RawReceiveSession.maxAutoLineBreakIntervalMs;

  // 当前连接的串口标识（用于判断是否需要清空数据）
  String? _lastConnectedPort;

  // 数据流
  final _dataController = StreamController<DataPacket>.broadcast();
  Stream<DataPacket> get dataStream => _dataController.stream;

  final _shellDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get shellDataStream => _shellDataController.stream;

  late final RawReceiveSession _rawSession;
  static const int rawRetentionLimitBytes =
      RawReceiveSession.rawRetentionLimitBytes;
  static const int minDisplayLineLimit = RawReceiveSession.minDisplayLineLimit;
  static const int defaultDisplayLineLimit =
      RawReceiveSession.defaultDisplayLineLimit;
  static const int maxDisplayLineLimit = RawReceiveSession.maxDisplayLineLimit;

  List<String> get receivedLines => _rawSession.receivedLines;
  int get displayRevision => _rawSession.displayRevision;
  int get displayTrimRevision => _rawSession.displayTrimRevision;
  List<String> get lastTrimmedDisplayLines =>
      _rawSession.lastTrimmedDisplayLines;
  int get displayLineLimit => _rawSession.displayLineLimit;
  bool get receiveHex => _rawSession.receiveHex;
  bool get showTimestamp => _rawSession.showTimestamp;
  bool get autoLineBreak => _rawSession.autoLineBreak;
  int get autoLineBreakIntervalMs => _rawSession.autoLineBreakIntervalMs;
  String get textEncoding => _rawSession.textEncoding;
  RetentionUsage get rawRetentionUsage => _rawSession.retentionUsage;
  Uint8List get rawBytes => _rawSession.rawBytes;
  bool get hasRawData => _rawSession.hasRawData;
  Map<String, String> get dataStats => _rawSession.dataStats;

  int? get debugRawRetentionLimitBytes => _rawSession.debugRetentionLimitBytes;
  set debugRawRetentionLimitBytes(int? value) {
    _rawSession.debugRetentionLimitBytes = value;
  }

  // 显示选项
  bool autoScroll = true;
  bool rawDataShellEnabled = false;
  RawShellInputMode rawShellInputMode = RawShellInputMode.line;
  double rawDataTerminalFontSize = 13.0;
  String rawDataTerminalFontFamily = 'Consolas';
  RawShellThemeMode rawShellThemeMode = RawShellThemeMode.light;
  RawShellCursorMode rawShellCursorMode = RawShellCursorMode.verticalBar;
  String shellEncoding = 'UTF-8';
  String shellLineEnding = '\r\n';
  bool shellLocalEcho = true;
  int shellScrollbackLines = 10000;

  // 发送选项
  bool sendHex = false;
  bool keepSendText = false;
  bool appendLineEnding = false;
  String lineEnding = '\r\n';
  bool enableCrc = false;
  CrcByteOrder crcByteOrder = CrcByteOrder.big;
  CrcType crcType = CrcType.crc16;
  String crcPolyName = 'CRC-16/MODBUS';

  bool get crcReverseBytes => crcByteOrder == CrcByteOrder.little;
  set crcReverseBytes(bool value) {
    crcByteOrder = value ? CrcByteOrder.little : CrcByteOrder.big;
  }

  // 绘图选项
  bool useRandomSource = false;

  // 绘图状态标志
  bool isPlotting = false;

  // 原始数据接收开关（独立于串口连接和绘图状态）
  bool isRawReceiving = false;
  SerialActivityOwner _activityOwner = SerialActivityOwner.none;
  SerialActivityOwner get activityOwner => _activityOwner;
  bool get isShellReceiving => _activityOwner == SerialActivityOwner.shell;
  late final YmodemService ymodemService = YmodemService(
    sendBytes: sendRawBytes,
  );

  /// 从 AppSettings 加载配置
  void loadSettings() {
    final settings = AppSettings();
    config = settings.saveToSerialConfig();
    useRandomSource = settings.useRandomSource;
    _rawSession.setDisplayLineLimit(settings.rawDataDisplayLineLimit);
    _rawSession.setAutoLineBreakIntervalMs(
      settings.rawDataAutoLineBreakIntervalMs,
    );
    rawDataShellEnabled = settings.rawDataShellEnabled;
    rawShellInputMode = RawShellInputMode.fromString(
      settings.rawDataShellInputMode,
    );
    rawDataTerminalFontSize = settings.rawDataTerminalFontSize.clamp(
      10.0,
      24.0,
    );
    rawDataTerminalFontFamily = settings.rawDataTerminalFontFamily;
    rawShellThemeMode = RawShellThemeMode.fromString(
      settings.rawDataShellTheme,
    );
    rawShellCursorMode = RawShellCursorMode.fromString(
      settings.rawDataShellCursor,
    );
    shellEncoding = settings.shellEncoding;
    shellLineEnding = settings.shellLineEnding;
    shellLocalEcho = settings.shellLocalEcho;
    shellScrollbackLines = settings.shellScrollbackLines;
    ymodemService.attach(shellDataStream);
    _rawSession.setTextEncoding(settings.rawDataEncoding);
  }

  /// 保存配置到 AppSettings
  void _saveSettings() {
    final settings = AppSettings();
    settings.loadFromSerialConfig(config);
    settings.useRandomSource = useRandomSource;
    settings.save();
  }

  /// 初始化串口发现。启动过程不等待枚举完成。
  void initializePortDiscovery() {
    if (_portDiscoveryStarted || _disposed) return;
    _portDiscoveryStarted = true;

    final monitor = NativeSerialPortMonitor();
    if (monitor.start()) {
      _portMonitor = monitor;
      _portMonitorSubscription = monitor.changes.listen((_) {
        _portChangeDebounce?.cancel();
        _portChangeDebounce = Timer(const Duration(milliseconds: 150), () {
          AppLogger().info('检测到串口设备列表变化', category: 'SERIAL');
          unawaited(refreshPorts(reason: '设备插拔通知'));
          if (isConnected) {
            unawaited(refreshConnectionStatus(reconnectOnce: true));
          }
        });
      });
    } else {
      monitor.dispose();
      AppLogger().warning('无法启动串口设备变化监听', category: 'SERIAL');
    }

    unawaited(refreshPorts(reason: '应用启动'));
  }

  Future<bool> refreshPorts({
    String reason = '用户手动刷新',
    Duration waitTimeout = const Duration(seconds: 2),
  }) {
    return _portCatalog.refresh(reason: reason, waitTimeout: waitTimeout);
  }

  /// 用户主动开启详细信息后刷新端口及友好名称。
  ///
  /// 自动刷新始终只调用 [refreshPorts]，不会读取可能缓慢的设备名称。
  Future<bool> refreshPortsWithDetails({
    String reason = '用户手动刷新详细串口信息',
    Duration waitTimeout = const Duration(seconds: 2),
  }) async {
    final existing = _pendingPortDetailsRefresh;
    if (existing != null) {
      return existing.timeout(waitTimeout, onTimeout: () => false);
    }

    final portsRefreshed = await refreshPorts(
      reason: reason,
      waitTimeout: waitTimeout,
    );
    if (!portsRefreshed && _portCatalog.isRefreshing) {
      return false;
    }

    _isRefreshingPortDetails = true;
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    late final Future<bool> operation;
    operation = Future<List<NativeSerialPortDetail>>.sync(() {
          final debugEnumerator = debugPortDetailsEnumerator;
          return debugEnumerator != null
              ? debugEnumerator()
              : NativeSerialReader.listPortDetailsInBackground();
        })
        .then((details) {
          _portFriendlyNames = Map.unmodifiable({
            for (final detail in details)
              if (_normalizePortFriendlyName(detail).isNotEmpty)
                detail.port: _normalizePortFriendlyName(detail),
          });
          AppLogger().info(
            '串口详细信息刷新完成：耗时=${stopwatch.elapsedMilliseconds}ms，'
            '名称数量=${_portFriendlyNames.length}',
            category: 'SERIAL',
          );
          return true;
        })
        .catchError((Object error, StackTrace stack) {
          AppLogger().warning(
            '刷新串口详细信息失败：耗时=${stopwatch.elapsedMilliseconds}ms，错误=$error',
            category: 'SERIAL',
          );
          return false;
        })
        .whenComplete(() {
          stopwatch.stop();
          if (identical(_pendingPortDetailsRefresh, operation)) {
            _pendingPortDetailsRefresh = null;
            _isRefreshingPortDetails = false;
            if (!_disposed) notifyListeners();
          }
        });
    _pendingPortDetailsRefresh = operation;

    try {
      return await operation.timeout(waitTimeout);
    } on TimeoutException {
      _isRefreshingPortDetails = false;
      if (!_disposed) notifyListeners();
      AppLogger().warning(
        '等待串口详细信息超时：等待=${waitTimeout.inMilliseconds}ms；'
        '后台读取将继续，界面保持响应',
        category: 'SERIAL',
      );
      return false;
    }
  }

  String _normalizePortFriendlyName(NativeSerialPortDetail detail) {
    final trimmed = detail.name.trim();
    if (trimmed.isEmpty) return '';
    return trimmed
        .replaceFirst(
          RegExp(
            '\\s*\\(${RegExp.escape(detail.port)}\\)\\s*\$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  /// 校验已有原生连接是否仍然有效。
  ///
  /// 健康连接不触发端口枚举。只有句柄异常后才刷新一次目录并决定是否重连。
  Future<bool> refreshConnectionStatus({bool reconnectOnce = true}) async {
    return _connectionCoordinator.enqueue(
      () => _refreshConnectionStatusLocked(reconnectOnce: reconnectOnce),
    );
  }

  Future<bool> _refreshConnectionStatusLocked({
    required bool reconnectOnce,
  }) async {
    final selectedPort = config.port;
    if (!isConnected) {
      await refreshPorts(reason: '连接窗口刷新');
      return false;
    }

    final healthChecker = debugConnectionHealthChecker;
    final nativePortOpen = debugNativePortOpen ?? _transport?.isOpen == true;
    var healthy = false;
    if (nativePortOpen) {
      try {
        healthy = await (healthChecker != null
                ? healthChecker()
                : NativeSerialReader.checkConnectionHealthInBackground())
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                AppLogger().warning(
                  '串口健康检查超时: $selectedPort',
                  category: 'SERIAL',
                );
                return false;
              },
            );
      } catch (error) {
        AppLogger().warning(
          '串口健康检查失败: $selectedPort，错误=$error',
          category: 'SERIAL',
        );
      }
    }
    if (healthy) return true;

    AppLogger().warning('检测到串口连接异常: $selectedPort', category: 'SERIAL');
    _connectionCoordinator.invalidate();
    await _cleanupPortLocked();

    final reconnectPortsRefreshed = await refreshPorts(reason: '连接异常复查');
    if (!reconnectPortsRefreshed) return false;
    if (selectedPort == null || !availablePorts.contains(selectedPort)) {
      config = config.copyWith(port: null);
      _saveSettings();
      AppNotifications.show('串口已断开，请重新连接');
      _notifyListenersSoon();
      return false;
    }

    config = config.copyWith(port: selectedPort);
    _notifyListenersSoon();
    if (!reconnectOnce) return false;

    AppLogger().info('尝试自动重连串口: $selectedPort', category: 'SERIAL');
    final generation = _connectionCoordinator.nextGeneration();
    await _connectLocked(generation);
    return isConnected;
  }

  /// 更新串口配置并通知监听者（供外部调用）
  void updateConfig(SerialConfig newConfig) {
    config = newConfig;
    _saveSettings();
    notifyListeners();
  }

  Future<void> connect() {
    return _connectionCoordinator.connect(
      onStart: () {
        isConnecting = true;
        _notifyListenersSoon();
      },
      operation: _connectLocked,
    );
  }

  Future<void> _connectLocked(int generation) async {
    AppLogger().trace('connect() 被调用', category: 'SERIAL');
    if (config.port == null) {
      AppLogger().error('请先选择串口', category: 'SERIAL');
      return;
    }
    if (isConnected) {
      AppLogger().trace('connect() 被忽略，串口已连接', category: 'SERIAL');
      return;
    }

    isConnecting = true;
    _notifyListenersSoon();
    AppLogger().trace('isConnecting=true, 开始异步打开串口', category: 'SERIAL');
    // 先让 Flutter 绘制连接中状态，再开始原生耗时操作。
    await Future<void>.delayed(Duration.zero);

    // 如果切换了串口，清空之前的数据
    if (_lastConnectedPort != null && _lastConnectedPort != config.port) {
      _clearAllData();
      AppLogger().trace('已切换串口，数据已清空', category: 'SERIAL');
    }

    try {
      // 直接使用 NativeSerialReader 打开串口（跳过 Isolate 探测）
      AppLogger().trace('使用 NativeSerialReader 打开串口...', category: 'SERIAL');
      await _openPort(generation);
      if (!_connectionCoordinator.isCurrent(generation)) {
        throw const _ConnectionCancelled();
      }

      _lastConnectedPort = config.port;
      isConnected = true;
      _saveSettings(); // 保存连接成功的串口配置
      AppLogger().info(
        '串口已连接: ${config.port} @ ${config.baudRate}',
        category: 'SERIAL',
      );
    } on _ConnectionCancelled {
      AppLogger().info('串口打开结果已过期，正在清理', category: 'SERIAL');
      await _cleanupPortLocked();
    } catch (e) {
      AppLogger().error('连接失败: $e', category: 'SERIAL');
      await _cleanupPortLocked();
      AppNotifications.show('串口打开失败，请检查端口占用或设备状态');
    } finally {
      isConnecting = false;
      AppLogger().trace('connect() 结束, isConnecting=false', category: 'SERIAL');
      _notifyListenersSoon();
    }
  }

  /// 在后台 isolate 打开原生句柄，然后挂接 UI 侧 IO。
  Future<void> _openPort(int generation) async {
    final port = config.port!;
    if (debugPortOpener != null) {
      final opened = await debugPortOpener!(port, config.baudRate);
      if (!opened) {
        throw Exception('无法打开串口');
      }
    }

    final transport = _transportFactory();
    final opened = await transport.open(port, config.baudRate);
    if (!opened) {
      await transport.close();
      throw Exception('无法打开串口');
    }
    if (!_connectionCoordinator.isCurrent(generation)) {
      await transport.close();
      throw const _ConnectionCancelled();
    }

    // 设置串口参数
    transport.setConfig(config.dataBits, config.stopBits, config.parity);
    transport.setRts(config.rts);
    transport.setDtr(config.dtr);

    AppLogger().trace('NativeSerialReader 打开成功', category: 'SERIAL');

    // 监听数据流
    _transport = transport;
    _nativeSubscription = transport.dataStream.listen(
      (nativeData) {
        if (_connectionCoordinator.isCurrent(generation) &&
            identical(transport, _transport)) {
          _onNativeDataReceived(nativeData);
        }
      },
      onError:
          (error) => AppLogger().error('原生读取错误: $error', category: 'SERIAL'),
    );

    // 启动读取（timeoutMs=10 表示 10ms 超时，避免阻塞）
    if (!transport.startReading(timeoutMs: 10)) {
      await _nativeSubscription?.cancel();
      _nativeSubscription = null;
      await transport.close();
      _transport = null;
      throw Exception('failed to start native serial read thread');
    }

    if (!_connectionCoordinator.isCurrent(generation)) {
      await _cleanupPortLocked();
      throw const _ConnectionCancelled();
    }

    AppLogger().trace('NativeSerialReader 读取线程已启动', category: 'SERIAL');
  }

  Future<void> disconnect() {
    return _connectionCoordinator.disconnect(_disconnectLocked);
  }

  Future<void> _disconnectLocked() async {
    await _cleanupPortLocked();
    AppLogger().info('串口已断开', category: 'SERIAL');
    _notifyListenersSoon();
  }

  Future<void> _cleanupPortLocked() async {
    _flushReceiveLog();
    _flushSendLog();
    final subscription = _nativeSubscription;
    _nativeSubscription = null;
    final transport = _transport;
    _transport = null;
    isConnected = false;
    _releaseAllActivities();
    _notifyListenersSoon();
    await subscription?.cancel();
    await transport?.close();
  }

  /// 应用退出专用：立即取消当前连接意图，再等待所有串口操作有序收敛。
  Future<void> shutdown() {
    return _connectionCoordinator.shutdown(() async {
      await _cleanupPortLocked();
      await _portMonitorSubscription?.cancel();
      _portMonitorSubscription = null;
      _portMonitor?.dispose();
      _portMonitor = null;
    });
  }

  /// 原生串口数据接收回调
  void _onNativeDataReceived(NativeSerialData nativeData) {
    final data = nativeData.data;
    final owner = _activityOwner;
    final shouldReceiveYmodem =
        isConnected &&
        owner == SerialActivityOwner.shell &&
        ymodemService.isActive;
    final shouldReceiveRaw =
        isConnected && owner == SerialActivityOwner.rawData;
    final shouldReceiveShell =
        isConnected && owner == SerialActivityOwner.shell;
    if (owner == SerialActivityOwner.none) {
      return;
    }

    if (owner == SerialActivityOwner.plot) {
      _dataController.add(DataPacket(data: data));
      return;
    }

    if (shouldReceiveYmodem) {
      _recordReceiveLog(data.length);
      // YMODEM 文件本身由接收服务直接落盘；原始追踪达到上限后不再增长，
      // 但不能因此截断正在进行的文件传输。
      _rawSession.appendRawBytes(data, stopAtLimit: false);
      ymodemService.addIncomingBytes(data);
      return;
    }

    if (shouldReceiveRaw) {
      _recordReceiveLog(data.length);
      final accepted = _rawSession.appendRawBytes(data, stopAtLimit: true);
      if (accepted.isEmpty) return;

      // 单调时间用于分包，墙钟时间只负责用户可见的时间戳。
      final receiveTime = DateTime.fromMicrosecondsSinceEpoch(
        nativeData.wallClockUs,
      );

      _rawSession.feedReceivedData(
        accepted,
        receiveTime,
        monotonicUs: nativeData.monotonicUs,
      );
    }

    if (shouldReceiveShell) {
      _recordReceiveLog(data.length);
      _shellDataController.add(data);
    }
  }

  /// 测试独立 Shell 的接收调度，不绕过活动所有权约束。
  @visibleForTesting
  void debugAddShellData(Uint8List data) {
    if (_activityOwner == SerialActivityOwner.shell) {
      _shellDataController.add(data);
    }
  }

  void _recordReceiveLog(int bytes) {
    final now = DateTime.now();
    _receiveLogWindowStart ??= now;
    if (_receiveLogPacketCount == 0) {
      _receiveLogFirstPacketBytes = bytes;
    }

    _receiveLogPacketCount++;
    _receiveLogBytes += bytes;

    final elapsed = now.difference(_receiveLogWindowStart!);
    if (!_receiveLogHighFrequency &&
        _receiveLogPacketCount >= _ioLogDetectPacketCount &&
        elapsed <= _ioLogDetectWindow) {
      _receiveLogHighFrequency = true;
    }

    if (_receiveLogHighFrequency) {
      if (_receiveLogPacketCount >= _ioLogBatchPacketCount ||
          elapsed >= _ioLogMaxBatchWindow) {
        _flushReceiveLog(now);
      } else {
        _scheduleReceiveLogFlush(_ioLogMaxBatchWindow - elapsed);
      }
      return;
    }

    if (elapsed >= _ioLogDetectWindow) {
      _flushReceiveLog(now);
    } else {
      _scheduleReceiveLogFlush(_ioLogDetectWindow - elapsed);
    }
  }

  void _scheduleReceiveLogFlush(Duration delay) {
    _receiveLogFlushTimer?.cancel();
    _receiveLogFlushTimer = Timer(
      delay,
      () => _flushReceiveLog(DateTime.now()),
    );
  }

  void _flushReceiveLog([DateTime? now]) {
    _receiveLogFlushTimer?.cancel();
    _receiveLogFlushTimer = null;

    if (_receiveLogPacketCount == 0 || _receiveLogWindowStart == null) return;

    final elapsedMs = (now ?? DateTime.now())
        .difference(_receiveLogWindowStart!)
        .inMilliseconds
        .clamp(1, 1 << 31);
    if (!_receiveLogHighFrequency && _receiveLogPacketCount == 1) {
      AppLogger().debug(
        '接收 $_receiveLogFirstPacketBytes bytes',
        category: 'DATA',
      );
    } else {
      final packetRate = _receiveLogPacketCount * 1000.0 / elapsedMs;
      AppLogger().debug(
        '接收 $_receiveLogPacketCount 包，共 $_receiveLogBytes bytes，'
        '约 ${packetRate.toStringAsFixed(1)} 包/s',
        category: 'DATA',
      );
    }

    _receiveLogWindowStart = null;
    _receiveLogHighFrequency = false;
    _receiveLogPacketCount = 0;
    _receiveLogBytes = 0;
    _receiveLogFirstPacketBytes = 0;
  }

  void _recordSendLog(int bytes) {
    final now = DateTime.now();
    _sendLogWindowStart ??= now;
    if (_sendLogPacketCount == 0) {
      _sendLogFirstPacketBytes = bytes;
    }

    _sendLogPacketCount++;
    _sendLogBytes += bytes;

    final elapsed = now.difference(_sendLogWindowStart!);
    if (!_sendLogHighFrequency &&
        _sendLogPacketCount >= _ioLogDetectPacketCount &&
        elapsed <= _ioLogDetectWindow) {
      _sendLogHighFrequency = true;
    }

    if (_sendLogHighFrequency) {
      if (_sendLogPacketCount >= _ioLogBatchPacketCount ||
          elapsed >= _ioLogMaxBatchWindow) {
        _flushSendLog(now);
      } else {
        _scheduleSendLogFlush(_ioLogMaxBatchWindow - elapsed);
      }
      return;
    }

    if (elapsed >= _ioLogDetectWindow) {
      _flushSendLog(now);
    } else {
      _scheduleSendLogFlush(_ioLogDetectWindow - elapsed);
    }
  }

  void _scheduleSendLogFlush(Duration delay) {
    _sendLogFlushTimer?.cancel();
    _sendLogFlushTimer = Timer(delay, () => _flushSendLog(DateTime.now()));
  }

  void _flushSendLog([DateTime? now]) {
    _sendLogFlushTimer?.cancel();
    _sendLogFlushTimer = null;

    if (_sendLogPacketCount == 0 || _sendLogWindowStart == null) return;

    final elapsedMs = (now ?? DateTime.now())
        .difference(_sendLogWindowStart!)
        .inMilliseconds
        .clamp(1, 1 << 31);
    if (!_sendLogHighFrequency && _sendLogPacketCount == 1) {
      AppLogger().info('发送 $_sendLogFirstPacketBytes bytes', category: 'DATA');
    } else {
      final packetRate = _sendLogPacketCount * 1000.0 / elapsedMs;
      AppLogger().info(
        '发送 $_sendLogPacketCount 包，共 $_sendLogBytes bytes，'
        '约 ${packetRate.toStringAsFixed(1)} 包/s',
        category: 'DATA',
      );
    }

    _sendLogWindowStart = null;
    _sendLogHighFrequency = false;
    _sendLogPacketCount = 0;
    _sendLogBytes = 0;
    _sendLogFirstPacketBytes = 0;
  }

  @visibleForTesting
  ({int packetCount, int bytes, bool highFrequency}) get debugSendLogState => (
    packetCount: _sendLogPacketCount,
    bytes: _sendLogBytes,
    highFrequency: _sendLogHighFrequency,
  );

  @visibleForTesting
  void debugRecordSendLogForTest(int bytes) => _recordSendLog(bytes);

  @visibleForTesting
  void debugFlushSendLogForTest() => _flushSendLog();

  /// 使用当前选择的编码解码字节数据
  String _decodeBytes(Uint8List data) =>
      _decodeBytesWithEncoding(data, textEncoding);

  /// 使用当前文本编码解码数据，供 Shell 等原始文本显示复用。
  String decodeText(Uint8List data) => _decodeBytes(data);

  @visibleForTesting
  void debugAddRawReceiveData(Uint8List data, {DateTime? timestamp}) {
    final accepted = _rawSession.appendRawBytes(data, stopAtLimit: true);
    if (accepted.isNotEmpty) {
      _rawSession.addReceivedData(accepted, timestamp ?? DateTime.now());
    }
  }

  /// 按真实接收显示流程喂入数据，用于验证自动换行窗口。
  @visibleForTesting
  void debugFeedRawReceiveData(Uint8List data, {DateTime? timestamp}) {
    final accepted = _rawSession.appendRawBytes(data, stopAtLimit: true);
    if (accepted.isNotEmpty) {
      _rawSession.feedReceivedData(accepted, timestamp ?? DateTime.now());
    }
  }

  @visibleForTesting
  void debugFlushAutoLineBreakForTest() {
    _rawSession.flushAutoLineBreak();
  }

  @visibleForTesting
  void debugAddSendData(Uint8List data) {
    _addSendDataLine(data);
  }

  @visibleForTesting
  void debugAddPlotSendDataForTest(
    Uint8List data, {
    required bool displayAsHex,
  }) {
    _addSendDataLine(
      data,
      source: SendDisplaySource.plot,
      displayAsHex: displayAsHex,
    );
  }

  void _addSendDataLine(
    Uint8List data, {
    SendDisplaySource source = SendDisplaySource.user,
    bool? displayAsHex,
  }) {
    _rawSession.addSendData(
      data,
      decodedText: _decodeBytes(data),
      displayAsHex: displayAsHex ?? sendHex,
      isPlot: source == SendDisplaySource.plot,
    );
  }

  void setDisplayLineLimit(int value) {
    final changed = _rawSession.setDisplayLineLimit(value);
    if (!changed) return;

    final settings = AppSettings()..rawDataDisplayLineLimit = displayLineLimit;
    unawaited(settings.save());
    AppLogger().info('接收区最多显示 $displayLineLimit 行', category: 'DATA');
  }

  void setRawDataShellEnabled(bool value) {
    if (rawDataShellEnabled == value) return;
    rawDataShellEnabled = value;
    final settings = AppSettings();
    settings.rawDataShellEnabled = value;
    settings.rawDataShellMode = false;
    unawaited(settings.save());
    AppLogger().info('Shell页面${value ? '显示' : '隐藏'}', category: 'DATA');
    _notifyListenersSoon();
  }

  /// 设置独立 Shell 标签是否显示；保留旧字段名以兼容已有配置文件。
  void setShellEnabled(bool value) => setRawDataShellEnabled(value);

  void setRawShellInputMode(RawShellInputMode value) {
    if (rawShellInputMode == value) return;
    rawShellInputMode = value;
    final settings = AppSettings();
    settings.rawDataShellInputMode = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell输入模式切换为 ${value.label}', category: 'DATA');
    _notifyListenersSoon();
  }

  void setShellEncoding(String value) {
    if (shellEncoding == value) return;
    shellEncoding = value;
    final settings = AppSettings()..shellEncoding = value;
    unawaited(settings.save());
    _notifyListenersSoon();
  }

  void setShellLineEnding(String value) {
    if (shellLineEnding == value) return;
    shellLineEnding = value;
    final settings = AppSettings()..shellLineEnding = value;
    unawaited(settings.save());
    _notifyListenersSoon();
  }

  void setShellLocalEcho(bool value) {
    if (shellLocalEcho == value) return;
    shellLocalEcho = value;
    final settings = AppSettings()..shellLocalEcho = value;
    unawaited(settings.save());
    _notifyListenersSoon();
  }

  void setShellScrollbackLines(int value) {
    final next = value.clamp(1000, 100000);
    if (shellScrollbackLines == next) return;
    shellScrollbackLines = next;
    final settings = AppSettings()..shellScrollbackLines = next;
    unawaited(settings.save());
    _notifyListenersSoon();
  }

  void setRawDataTerminalFontSize(double value) {
    final next = value.clamp(10.0, 24.0);
    if (rawDataTerminalFontSize == next) return;
    rawDataTerminalFontSize = next;
    final settings = AppSettings();
    settings.rawDataTerminalFontSize = next;
    unawaited(settings.save());
    AppLogger().info('Shell字体大小设置为 $next', category: 'DATA');
    _notifyListenersSoon();
  }

  void setRawDataTerminalFontFamily(String value) {
    final next = value.trim().isEmpty ? 'Consolas' : value.trim();
    if (rawDataTerminalFontFamily == next) return;
    rawDataTerminalFontFamily = next;
    final settings = AppSettings();
    settings.rawDataTerminalFontFamily = next;
    unawaited(settings.save());
    AppLogger().info('Shell字体设置为 $next', category: 'DATA');
    _notifyListenersSoon();
  }

  void setRawShellThemeMode(RawShellThemeMode value) {
    if (rawShellThemeMode == value) return;
    rawShellThemeMode = value;
    final settings = AppSettings();
    settings.rawDataShellTheme = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell主题切换为 ${value.label}', category: 'DATA');
    _notifyListenersSoon();
  }

  void setRawShellCursorMode(RawShellCursorMode value) {
    if (rawShellCursorMode == value) return;
    rawShellCursorMode = value;
    final settings = AppSettings();
    settings.rawDataShellCursor = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell光标样式切换为 ${value.label}', category: 'DATA');
    _notifyListenersSoon();
  }

  void setReceiveHex(bool value) {
    if (!_rawSession.setReceiveHex(value)) return;
    AppLogger().info('接收显示格式切换为 ${value ? 'HEX' : '文本'}', category: 'DATA');
    _notifyListenersSoon();
  }

  /// 设置文本收发编码（仅非 HEX 模式生效）。
  void setTextEncoding(String encoding) {
    if (!_rawSession.setTextEncoding(encoding)) return;
    unawaited(_persistEncoding());
    AppLogger().info('文本收发编码切换为: $encoding', category: 'DATA');
    _notifyListenersSoon();
  }

  Future<void> _persistEncoding() async {
    final settings = AppSettings()..rawDataEncoding = textEncoding;
    await settings.save();
  }

  void setShowTimestamp(bool value) {
    if (!_rawSession.setShowTimestamp(value)) return;
    AppLogger().info('接收时间戳${value ? '启用' : '关闭'}', category: 'DATA');
    _notifyListenersSoon();
  }

  /// 清空所有数据（切换串口时调用）。
  void _clearAllData() {
    _rawSession.clear();
  }

  /// 手动清空数据。
  void clearReceivedData() {
    _clearAllData();
    AppLogger().info('接收区已清空', category: 'SERIAL');
  }

  Future<String?> exportAsText({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) {
    return _rawSession.exportAsText(
      outputDirectory: outputDirectory,
      onProgress: onProgress,
    );
  }

  Future<String?> exportAsRawBytes({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) {
    return _rawSession.exportAsRawBytes(
      outputDirectory: outputDirectory,
      onProgress: onProgress,
    );
  }

  Uint8List? prepareSendData(String text) {
    if (!isConnected) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }
    if (_transport == null) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }

    return _prepareSendPayload(text);
  }

  @visibleForTesting
  Uint8List? prepareSendDataForTest(String text) => _prepareSendPayload(text);

  /// 多条发送条目使用独立的有效载荷规则：不追加普通发送区的行尾或 CRC。
  Uint8List? prepareMultiSendData(String text, {required bool isHex}) {
    if (!isConnected || _transport == null || text.isEmpty) return null;
    try {
      if (!isHex) return _encodeTextWithEncoding(text, textEncoding);
      final hex = text.replaceAll(RegExp(r'\s+'), '');
      if (hex.isEmpty || hex.length.isOdd) return null;
      final bytes = <int>[];
      for (var index = 0; index < hex.length; index += 2) {
        final value = int.tryParse(hex.substring(index, index + 2), radix: 16);
        if (value == null) return null;
        bytes.add(value);
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  Uint8List? prepareMultiSendDataForTest(String text, {required bool isHex}) {
    if (text.isEmpty) return null;
    if (!isHex) return _encodeTextWithEncoding(text, textEncoding);
    final hex = text.replaceAll(RegExp(r'\s+'), '');
    if (hex.isEmpty || hex.length.isOdd) return null;
    final bytes = <int>[];
    for (var index = 0; index < hex.length; index += 2) {
      final value = int.tryParse(hex.substring(index, index + 2), radix: 16);
      if (value == null) return null;
      bytes.add(value);
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List? _prepareSendPayload(String text) {
    if (text.isEmpty) return null;

    try {
      Uint8List data;
      if (sendHex) {
        final hexString = text.replaceAll(' ', '');
        if (hexString.length % 2 != 0) {
          AppLogger().error('十六进制数据长度必须为偶数', category: 'SERIAL');
          return null;
        }
        final bytes = <int>[];
        for (var i = 0; i < hexString.length; i += 2) {
          final byte = int.tryParse(hexString.substring(i, i + 2), radix: 16);
          if (byte == null) {
            AppLogger().error('无效的十六进制数据', category: 'SERIAL');
            return null;
          }
          bytes.add(byte);
        }
        data = Uint8List.fromList(bytes);
      } else {
        data = prepareTextSendData(text);
      }

      // 追加 CRC
      if (enableCrc && sendHex) {
        final poly = getPolysByType(crcType)[crcPolyName];
        if (poly != null) {
          final crc = calculateCrc(data, poly);
          var crcBytes = crcToBytes(crc, poly.width);
          if (crcByteOrder == CrcByteOrder.little) {
            crcBytes = crcBytes.reversed.toList();
          }
          final newData = Uint8List(data.length + crcBytes.length);
          newData.setRange(0, data.length, data);
          newData.setRange(data.length, newData.length, crcBytes);
          data = newData;
        }
      }

      return data;
    } catch (e) {
      AppLogger().error('发送失败: $e', category: 'SERIAL');
      return null;
    }
  }

  @visibleForTesting
  Uint8List prepareTextSendData(String text) {
    final content = appendLineEnding ? '$text$lineEnding' : text;
    return _encodeTextWithEncoding(content, textEncoding);
  }

  Uint8List prepareShellTextData(String text) {
    final content = '$text$shellLineEnding';
    return _encodeTextWithEncoding(content, shellEncoding);
  }

  Uint8List encodeShellText(String text) =>
      _encodeTextWithEncoding(text, shellEncoding);

  String decodeShellText(Uint8List data) =>
      _decodeBytesWithEncoding(data, shellEncoding);

  Uint8List encodeText(String text) =>
      _encodeTextWithEncoding(text, textEncoding);

  Future<void> send(
    Uint8List data, {
    SendDisplaySource displaySource = SendDisplaySource.user,
    bool? displayAsHex,
  }) async {
    await _writeBytes(data);
    // 发送的数据也显示在数据窗口
    _addSendDataLine(data, source: displaySource, displayAsHex: displayAsHex);
  }

  Future<void> sendRawBytes(Uint8List data) => _writeBytes(data);

  Future<void> _writeBytes(Uint8List data) async {
    if (!isConnected) {
      AppLogger().warning('串口未连接，无法发送数据', category: 'SERIAL');
      throw StateError('串口未连接');
    }
    if (_transport != null) {
      final sent = await _transport!.write(data);
      if (sent != data.length) {
        _handleIoDisconnected(
          '发送失败，串口可能已断开: expected=${data.length}, sent=$sent',
        );
        throw StateError('串口已断开连接，发送失败');
      }
      _recordSendLog(sent);
    } else {
      _handleIoDisconnected('发送失败，串口读取器不可用');
      throw StateError('串口已断开连接，发送失败');
    }
  }

  Future<File?> receiveYmodemFile() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final dir = Directory('${exeDir.path}/exports/ymodem');
    return ymodemService.receiveFile(dir);
  }

  void _handleIoDisconnected(String message) {
    AppLogger().warning(message, category: 'SERIAL');
    final operation = _connectionCoordinator.disconnectFromIo(
      _cleanupPortLocked,
    );
    unawaited(operation);
    _notifyListenersSoon();
  }

  void updateRts(bool value) {
    config = config.copyWith(rts: value);
    _saveSettings();
    if (isConnected) {
      if (_transport != null) {
        _transport!.setRts(value);
      }
    }
    AppLogger().info('RTS: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    _notifyListenersSoon();
  }

  void updateDtr(bool value) {
    config = config.copyWith(dtr: value);
    _saveSettings();
    if (isConnected) {
      if (_transport != null) {
        _transport!.setDtr(value);
      }
    }
    AppLogger().info('DTR: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    _notifyListenersSoon();
  }

  void setAutoLineBreak(bool value) {
    if (!_rawSession.setAutoLineBreak(value)) return;
    AppLogger().info('接收自动换行${value ? '启用' : '关闭'}', category: 'DATA');
    _notifyListenersSoon();
  }

  /// 设置相邻接收包的自动换行超时，范围为 1~10000ms。
  void setAutoLineBreakIntervalMs(int milliseconds) {
    if (!_rawSession.setAutoLineBreakIntervalMs(milliseconds)) return;
    final next = autoLineBreakIntervalMs;
    final settings = AppSettings()..rawDataAutoLineBreakIntervalMs = next;
    unawaited(settings.save());
    AppLogger().info('接收自动换行时间: $next ms', category: 'SERIAL');
    _notifyListenersSoon();
  }

  // ========== 原始数据接收控制 ==========

  /// 开始接收原始数据
  bool startRawReceiving() {
    if (!isConnected) {
      AppLogger().warning('串口未连接，无法开始接收', category: 'SERIAL');
      return false;
    }
    if (rawRetentionUsage.state == RetentionState.limitReached) {
      const message = '原始数据已达到容量上限，请先导出并清空接收区';
      AppLogger().warning(message, category: 'DATA');
      AppNotifications.show(message);
      return false;
    }
    if (!_tryAcquireActivity(SerialActivityOwner.rawData)) {
      AppLogger().warning('其他页面正在接收，无法开始接收原始数据', category: 'SERIAL');
      return false;
    }
    isRawReceiving = true;
    AppLogger().info('开始接收原始数据', category: 'SERIAL');
    _notifyListenersSoon();
    return true;
  }

  /// 停止接收原始数据
  void stopRawReceiving() {
    _rawSession.flushAutoLineBreak();
    _rawSession.flushTextDecoder();
    isRawReceiving = false;
    _releaseActivity(SerialActivityOwner.rawData);
    AppLogger().info('停止接收原始数据', category: 'SERIAL');
    _notifyListenersSoon();
  }

  /// 开始独立 Shell 会话。未成功取得接收所有权时不会进入运行状态。
  bool startShellReceiving() {
    if (!isConnected) {
      AppLogger().warning('串口未连接，无法启动 Shell', category: 'SERIAL');
      return false;
    }
    if (!_tryAcquireActivity(SerialActivityOwner.shell)) {
      AppLogger().warning('其他页面正在接收，无法启动 Shell', category: 'SERIAL');
      return false;
    }
    AppLogger().info('Shell 会话已启动', category: 'SERIAL');
    _notifyListenersSoon();
    return true;
  }

  Future<void> stopShellReceiving() async {
    if (ymodemService.isActive) {
      await ymodemService.cancel();
    }
    _releaseActivity(SerialActivityOwner.shell);
    AppLogger().info('Shell 会话已停止', category: 'SERIAL');
    _notifyListenersSoon();
  }

  /// 尝试原子取得串口活动所有权；同一所有者重复调用视为成功。
  bool tryAcquireActivity(SerialActivityOwner owner) =>
      _tryAcquireActivity(owner);

  bool _tryAcquireActivity(SerialActivityOwner owner) {
    if (owner == SerialActivityOwner.none) return false;
    if (_activityOwner != SerialActivityOwner.none && _activityOwner != owner) {
      return false;
    }
    _activityOwner = owner;
    isRawReceiving = owner == SerialActivityOwner.rawData;
    isPlotting = owner == SerialActivityOwner.plot;
    return true;
  }

  void releaseActivity(SerialActivityOwner owner) {
    _releaseActivity(owner);
    _notifyListenersSoon();
  }

  void _releaseActivity(SerialActivityOwner owner) {
    if (_activityOwner != owner) return;
    if (owner == SerialActivityOwner.rawData) {
      _rawSession.flushAutoLineBreak();
      _rawSession.flushTextDecoder();
    }
    _activityOwner = SerialActivityOwner.none;
    isRawReceiving = false;
    isPlotting = false;
  }

  void _releaseAllActivities() {
    if (_activityOwner == SerialActivityOwner.rawData) {
      _rawSession.flushAutoLineBreak();
      _rawSession.flushTextDecoder();
    }
    _activityOwner = SerialActivityOwner.none;
    isRawReceiving = false;
    isPlotting = false;
    if (ymodemService.isActive) ymodemService.abort('串口已断开');
  }

  @override
  void dispose() {
    // 不要在这里调用 disconnect()，它会触发 notifyListeners()。
    // 如果发生在 super.dispose() 之后会抛异常，因此这里只直接清理资源。
    _disposed = true;
    _flushReceiveLog();
    _flushSendLog();
    _rawSession.dispose();
    _portChangeDebounce?.cancel();
    _portChangeDebounce = null;
    unawaited(
      _connectionCoordinator.shutdown(() async {
        await _cleanupPortLocked();
        await _portMonitorSubscription?.cancel();
        _portMonitorSubscription = null;
        _portMonitor?.dispose();
        _portMonitor = null;
      }),
    );
    isConnected = false;
    unawaited(ymodemService.dispose());
    _dataController.close();
    _shellDataController.close();
    super.dispose();
  }
}
