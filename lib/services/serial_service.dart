import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter/material.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/data_packet.dart';
import '../data/models/serial_config.dart';
import 'app_notifications.dart';
import 'app_settings.dart';
import 'native_serial_reader.dart';
import 'serial_port_catalog.dart';
import 'time_window_aggregator.dart';
import 'ymodem_service.dart';

/// 支持 O(1) 头部淘汰的字符串列表。
///
/// 原始收发达到显示上限后会持续删除最旧行。普通 List 的 removeAt(0)
/// 每次都要移动所有元素，环形存储可以避免高行数下的重复整体搬移。
class _CircularStringList extends ListBase<String> {
  List<String?> _items = List<String?>.filled(16, null);
  int _head = 0;
  int _length = 0;

  @override
  int get length => _length;

  @override
  set length(int value) {
    if (value < 0) {
      throw RangeError.range(value, 0, null, 'length');
    }
    if (value > _length) {
      throw UnsupportedError('不能通过 length 扩展环形列表');
    }
    while (_length > value) {
      removeLast();
    }
  }

  @override
  String operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _items[_physicalIndex(index)]!;
  }

  @override
  void operator []=(int index, String value) {
    RangeError.checkValidIndex(index, this);
    _items[_physicalIndex(index)] = value;
  }

  @override
  void add(String value) {
    _ensureCapacity(_length + 1);
    _items[_physicalIndex(_length)] = value;
    _length++;
  }

  String removeFirst() {
    if (_length == 0) throw StateError('列表为空');
    final value = _items[_head]!;
    _items[_head] = null;
    _head = (_head + 1) % _items.length;
    _length--;
    if (_length == 0) _head = 0;
    return value;
  }

  @override
  String removeLast() {
    if (_length == 0) throw StateError('列表为空');
    final index = _physicalIndex(_length - 1);
    final value = _items[index]!;
    _items[index] = null;
    _length--;
    if (_length == 0) _head = 0;
    return value;
  }

  @override
  String removeAt(int index) {
    RangeError.checkValidIndex(index, this);
    if (index == 0) return removeFirst();
    if (index == _length - 1) return removeLast();

    final value = this[index];
    for (var i = index; i < _length - 1; i++) {
      this[i] = this[i + 1];
    }
    removeLast();
    return value;
  }

  @override
  void clear() {
    _items = List<String?>.filled(16, null);
    _head = 0;
    _length = 0;
  }

  int _physicalIndex(int logicalIndex) =>
      (_head + logicalIndex) % _items.length;

  void _ensureCapacity(int required) {
    if (required <= _items.length) return;
    final next = List<String?>.filled(_items.length * 2, null);
    for (var i = 0; i < _length; i++) {
      next[i] = this[i];
    }
    _items = next;
    _head = 0;
  }
}

enum SendDisplaySource { user, plot }

typedef ExportProgressCallback = void Function(double progress);

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
    'GBK' => gbk.decode(data, allowMalformed: true),
    'BIG5' => decodeOrFallback(CodePage('cp950', 'BIG5').decode),
    'Shift_JIS' => decodeOrFallback(shiftJis.decode),
    'EUC-KR' => decodeOrFallback(eucKr.decode),
    'Latin-1' => decodeOrFallback(latin1.decode),
    'ASCII' => decodeOrFallback(ascii.decode),
    _ => utf8.decode(data, allowMalformed: true),
  };
}

Uint8List _buildRawExportBytes(Uint8List bytes) {
  final crcPoly = crc32Polys['CRC-32']!;
  final crcValue = calculateCrc(bytes, crcPoly);
  final crcBytes = crcToBytes(crcValue, 32);
  final output =
      BytesBuilder(copy: false)
        ..add(bytes)
        ..add(Uint8List.fromList(crcBytes));
  return output.takeBytes();
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
  SerialService._internal() {
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
  late final SerialPortCatalog _portCatalog;
  NativeSerialPortMonitor? _portMonitor;
  StreamSubscription<void>? _portMonitorSubscription;
  Timer? _portChangeDebounce;
  bool _portDiscoveryStarted = false;
  bool _disposed = false;

  // Windows 原生串口读取器
  NativeSerialReader? _nativeReader;
  StreamSubscription? _nativeSubscription;

  /// 仅测试使用：模拟原生串口打开缓慢或失败。
  Future<bool> Function(String port, int baudRate)? debugPortOpener;

  /// 仅测试使用：替换原生串口枚举。
  Future<List<String>> Function()? debugPortEnumerator;

  /// 仅测试使用：替换原生连接健康检查。
  Future<bool> Function()? debugConnectionHealthChecker;

  /// 仅测试使用：替换原生句柄打开状态。
  bool? debugNativePortOpen;

  List<String> get availablePorts => _portCatalog.ports;
  bool get isRefreshingPorts => _portCatalog.isRefreshing;
  String? get portRefreshError => _portCatalog.lastError;
  Duration? get lastPortRefreshDuration => _portCatalog.lastDuration;

  // 时间窗口聚合器
  TimeWindowAggregator? _aggregator;

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

  // 时间窗口粒度（微秒），默认 1000us = 1ms
  int timeWindowUs = 1000;

  // 当前连接的串口标识（用于判断是否需要清空数据）
  String? _lastConnectedPort;

  // 数据流
  final _dataController = StreamController<DataPacket>.broadcast();
  Stream<DataPacket> get dataStream => _dataController.stream;

  final _shellDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get shellDataStream => _shellDataController.stream;

  // 原始字节数据（内部保留）
  final ChunkedByteBuffer _rawBytes = ChunkedByteBuffer();
  int get _rawBytesSize => _rawBytes.length;

  // 原始文本数据（用于原始数据页面显示）
  final _CircularStringList _receivedLines = _CircularStringList();
  List<String> get receivedLines => _receivedLines;
  int _receivedTextBytes = 0;
  Timer? _displayNotifyTimer;
  bool _displayBatchHasTrim = false;
  int _displayTrimRevision = 0;
  List<String> _lastTrimmedDisplayLines = <String>[];
  int get displayTrimRevision => _displayTrimRevision;
  List<String> get lastTrimmedDisplayLines => _lastTrimmedDisplayLines;
  String _pendingReceiveText = '';
  int? _pendingReceiveLineIndex;
  String _pendingReceiveLinePrefix = '';
  String _pendingSendText = '';
  int? _pendingSendLineIndex;
  String _pendingSendLinePrefix = '';
  static const int _maxReceivedTextBytes = 128 * 1024 * 1024; // 128MB 文本缓存
  static const int minDisplayLineLimit = 100;
  static const int defaultDisplayLineLimit = 10000;
  static const int maxDisplayLineLimit = 100000;
  int _displayLineLimit = defaultDisplayLineLimit;
  int get displayLineLimit => _displayLineLimit;

  // 显示选项
  bool receiveHex = false;
  bool showTimestamp = false;
  bool autoScroll = true;
  bool rawDataShellMode = false;
  bool rawDataShellEnabled = false;
  RawShellInputMode rawShellInputMode = RawShellInputMode.line;
  double rawDataTerminalFontSize = 13.0;
  String rawDataTerminalFontFamily = 'Consolas';
  RawShellThemeMode rawShellThemeMode = RawShellThemeMode.light;
  RawShellCursorMode rawShellCursorMode = RawShellCursorMode.verticalBar;

  // 文本解码选项（非 HEX 模式下生效）
  String _receiveEncoding = 'UTF-8';

  /// 当前接收文本解码方式
  String get receiveEncoding => _receiveEncoding;

  /// 文本模式单行最大长度（超过此长度即使没有换行符也强制换行）
  static const int _maxTextLineLength = 4096;

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
  late final YmodemService ymodemService = YmodemService(
    sendBytes: sendRawBytes,
  );

  /// 从 AppSettings 加载配置
  void loadSettings() {
    final settings = AppSettings();
    config = settings.saveToSerialConfig();
    useRandomSource = settings.useRandomSource;
    _displayLineLimit = settings.rawDataDisplayLineLimit.clamp(
      minDisplayLineLimit,
      maxDisplayLineLimit,
    );
    rawDataShellEnabled = settings.rawDataShellEnabled;
    rawDataShellMode = rawDataShellEnabled && settings.rawDataShellMode;
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
    ymodemService.attach(shellDataStream);
    _receiveEncoding = settings.rawDataEncoding;
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

  /// 校验已有原生连接是否仍然有效。
  ///
  /// 健康连接不触发端口枚举。只有句柄异常后才刷新一次目录并决定是否重连。
  Future<bool> refreshConnectionStatus({bool reconnectOnce = true}) async {
    final selectedPort = config.port;
    if (!isConnected) {
      await refreshPorts(reason: '连接窗口刷新');
      return false;
    }

    final healthChecker = debugConnectionHealthChecker;
    final nativePortOpen = debugNativePortOpen ?? _nativeReader?.isOpen == true;
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
    _cleanupPort();

    final reconnectPortsRefreshed = await refreshPorts(reason: '连接异常复查');
    if (!reconnectPortsRefreshed) return false;
    if (selectedPort == null || !availablePorts.contains(selectedPort)) {
      config = config.copyWith(port: null);
      _saveSettings();
      AppNotifications.show('串口已断开，请重新连接');
      Future.microtask(() => notifyListeners());
      return false;
    }

    config = config.copyWith(port: selectedPort);
    Future.microtask(() => notifyListeners());
    if (!reconnectOnce) return false;

    AppLogger().info('尝试自动重连串口: $selectedPort', category: 'SERIAL');
    await connect();
    return isConnected;
  }

  /// 更新串口配置并通知监听者（供外部调用）
  void updateConfig(SerialConfig newConfig) {
    config = newConfig;
    _saveSettings();
    notifyListeners();
  }

  Future<void> connect() async {
    AppLogger().trace('connect() 被调用', category: 'SERIAL');
    if (config.port == null) {
      AppLogger().error('请先选择串口', category: 'SERIAL');
      return;
    }
    if (isConnecting || isConnected) {
      AppLogger().trace(
        'connect() 被忽略，isConnecting=$isConnecting, isConnected=$isConnected',
        category: 'SERIAL',
      );
      return;
    }

    isConnecting = true;
    Future.microtask(() => notifyListeners());
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
      await _openPort();

      _lastConnectedPort = config.port;
      isConnected = true;
      _saveSettings(); // 保存连接成功的串口配置
      AppLogger().info(
        '串口已连接: ${config.port} @ ${config.baudRate}',
        category: 'SERIAL',
      );
    } catch (e) {
      AppLogger().error('连接失败: $e', category: 'SERIAL');
      _cleanupPort();
      AppNotifications.show('串口打开失败，请检查端口占用或设备状态');
    } finally {
      isConnecting = false;
      AppLogger().trace('connect() 结束, isConnecting=false', category: 'SERIAL');
      Future.microtask(() => notifyListeners());
    }
  }

  /// 在后台 isolate 打开原生句柄，然后挂接 UI 侧 IO。
  Future<void> _openPort() async {
    final port = config.port!;
    if (debugPortOpener != null) {
      final opened = await debugPortOpener!(port, config.baudRate);
      if (!opened) {
        throw Exception('无法打开串口');
      }
    }

    // 使用 Windows 原生串口读取器
    _nativeReader = NativeSerialReader();
    // 打开前使用 NativeApi.initializeApiDLData 初始化 Dart API。
    final initData = NativeApi.initializeApiDLData;
    _nativeReader!.initDartApi(initData);
    final opened = await NativeSerialReader.openInBackground(
      port,
      config.baudRate,
    );
    if (!opened) {
      throw Exception('无法打开串口');
    }
    if (!_nativeReader!.attachToOpenPort()) {
      throw Exception('无法获取已打开的串口句柄');
    }

    // 设置串口参数
    _nativeReader!.setConfig(config.dataBits, config.stopBits, config.parity);
    _nativeReader!.setRts(config.rts);
    _nativeReader!.setDtr(config.dtr);

    AppLogger().trace('NativeSerialReader 打开成功', category: 'SERIAL');

    // 监听数据流
    _nativeSubscription = _nativeReader!.dataStream.listen(
      (nativeData) => _onNativeDataReceived(nativeData),
      onError:
          (error) => AppLogger().error('原生读取错误: $error', category: 'SERIAL'),
    );

    // 启动读取（timeoutMs=10 表示 10ms 超时，避免阻塞）
    if (!_nativeReader!.startReading(timeoutMs: 10)) {
      await _nativeSubscription?.cancel();
      _nativeSubscription = null;
      _nativeReader!.close();
      _nativeReader = null;
      throw Exception('failed to start native serial read thread');
    }

    AppLogger().trace('NativeSerialReader 读取线程已启动', category: 'SERIAL');
  }

  void disconnect() {
    if (isConnecting) {
      AppLogger().warning('正在连接中，无法断开', category: 'SERIAL');
      return;
    }
    _cleanupPort();
    AppLogger().info('串口已断开', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  void _cleanupPort() {
    _flushReceiveLog();
    _flushSendLog();
    _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _nativeReader?.close();
    _nativeReader = null;
    isConnected = false;
    // 断开串口时自动关闭原始数据接收
    if (isRawReceiving) {
      isRawReceiving = false;
    }
  }

  /// 原生串口数据接收回调
  void _onNativeDataReceived(NativeSerialData nativeData) {
    final data = nativeData.data;
    final shouldReceiveYmodem =
        isConnected &&
        rawDataShellMode &&
        ymodemService.isActive &&
        !isPlotting;
    final shouldReceiveRaw = isConnected && isRawReceiving && !isPlotting;
    if (!isPlotting && !shouldReceiveRaw && !shouldReceiveYmodem) {
      return;
    }

    if (isPlotting) {
      _dataController.add(DataPacket(data: data));
    }

    if (shouldReceiveYmodem) {
      _recordReceiveLog(data.length);
      _rawBytes.append(data);
      ymodemService.addIncomingBytes(data);
      return;
    }

    if (shouldReceiveRaw) {
      _recordReceiveLog(data.length);
      _rawBytes.append(data);

      if (rawDataShellMode) {
        _shellDataController.add(data);
        return;
      }

      // 使用 C++ 提供的微秒级时间戳
      final receiveTime = DateTime.fromMicrosecondsSinceEpoch(
        nativeData.timestampUs,
      );

      if (showTimestamp && receiveHex) {
        // HEX + 时间戳显示时使用时间窗口聚合器分包
        _aggregator ??= TimeWindowAggregator(
          windowUs: timeWindowUs,
          onWindowComplete: (timestamp, aggregatedData) {
            _addRawDataLine(timestamp, aggregatedData);
          },
        );
        _aggregator!.feed(data, receiveTime);
      } else {
        // 文本模式不按底层回调分包，只按换行符更新显示行
        _addRawDataLine(receiveTime, data);
      }
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
      _decodeBytesWithEncoding(data, _receiveEncoding);

  /// 添加一行接收数据显示
  void _addRawDataLine(DateTime timestamp, Uint8List data) {
    if (receiveHex) {
      final text = data
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final prefix = showTimestamp ? '← [${_formatTimestamp(timestamp)}] ' : '';
      _addDisplayLine('$prefix$text (${data.length} bytes)');
    } else {
      _addTextDataLines(
        _decodeBytes(data),
        timestamp: timestamp,
        isReceive: true,
      );
    }
  }

  @visibleForTesting
  void debugAddRawReceiveData(Uint8List data, {DateTime? timestamp}) {
    _rawBytes.append(data);
    _addRawDataLine(timestamp ?? DateTime.now(), data);
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

  /// 添加一行发送数据显示
  void _addSendDataLine(
    Uint8List data, {
    SendDisplaySource source = SendDisplaySource.user,
    bool? displayAsHex,
  }) {
    final shouldDisplayAsHex = displayAsHex ?? sendHex;
    if (shouldDisplayAsHex) {
      final text = data
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      final prefix = _sendLinePrefix(DateTime.now(), source: source);
      final hexMark = !receiveHex ? '[HEX] ' : '';
      _addDisplayLine('$prefix$hexMark$text (${data.length} bytes)');
    } else {
      _addTextDataLines(
        _decodeBytes(data),
        timestamp: DateTime.now(),
        isReceive: false,
        sendSource: source,
      );
    }
  }

  void _addTextDataLines(
    String text, {
    required DateTime timestamp,
    required bool isReceive,
    SendDisplaySource sendSource = SendDisplaySource.user,
  }) {
    if (text.isEmpty) return;

    final prefix =
        isReceive
            ? (showTimestamp ? '← [${_formatTimestamp(timestamp)}] ' : '')
            : _sendLinePrefix(timestamp, source: sendSource);
    var pendingText = isReceive ? _pendingReceiveText : _pendingSendText;
    var pendingIndex =
        isReceive ? _pendingReceiveLineIndex : _pendingSendLineIndex;
    var pendingPrefix =
        isReceive ? _pendingReceiveLinePrefix : _pendingSendLinePrefix;
    if (!isReceive && pendingPrefix != prefix) {
      pendingText = '';
      pendingIndex = null;
      pendingPrefix = '';
    }

    void savePending() {
      if (isReceive) {
        _pendingReceiveText = pendingText;
        _pendingReceiveLineIndex = pendingIndex;
        _pendingReceiveLinePrefix = pendingPrefix;
      } else {
        _pendingSendText = pendingText;
        _pendingSendLineIndex = pendingIndex;
        _pendingSendLinePrefix = pendingPrefix;
      }
    }

    void ensureLine() {
      if (pendingIndex != null &&
          pendingIndex! >= 0 &&
          pendingIndex! < receivedLines.length &&
          pendingPrefix == prefix) {
        return;
      }
      pendingPrefix = prefix;
      pendingIndex = _addDisplayLine(pendingPrefix);
    }

    void updateLine() {
      ensureLine();
      _updateDisplayLine(pendingIndex!, '$pendingPrefix$pendingText');
    }

    for (var i = 0; i < text.length; i++) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 13 || codeUnit == 10) {
        updateLine();
        pendingText = '';
        pendingIndex = null;
        pendingPrefix = '';
        if (codeUnit == 13 &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == 10) {
          i++;
        }
      } else {
        pendingText += text[i];
        // 单行超过上限时强制换行，避免长时间等不到换行符导致卡死
        if (pendingText.length >= _maxTextLineLength) {
          updateLine();
          pendingText = '';
          pendingIndex = null;
          pendingPrefix = '';
        }
      }
    }

    if (pendingText.isNotEmpty) {
      updateLine();
    }
    savePending();
  }

  String _sendLinePrefix(
    DateTime timestamp, {
    required SendDisplaySource source,
  }) {
    final buffer = StringBuffer();
    if (showTimestamp) {
      buffer.write('→ [${_formatTimestamp(timestamp)}] ');
    }
    if (source == SendDisplaySource.plot) {
      buffer.write('[绘图发送] ');
    }
    return buffer.toString();
  }

  /// 添加一行到显示列表（通用）
  int _addDisplayLine(String line) {
    _beginDisplayMutation();
    _receivedLines.add(line);
    _receivedTextBytes += line.length * 2; // UTF-16 编码估算

    _trimDisplayLines();
    _scheduleDisplayNotify();
    return _receivedLines.length - 1;
  }

  void _updateDisplayLine(int index, String line) {
    if (index < 0 || index >= _receivedLines.length) return;
    _beginDisplayMutation();
    final oldLine = _receivedLines[index];
    _receivedLines[index] = line;
    _receivedTextBytes += (line.length - oldLine.length) * 2;
    _trimDisplayLines();
    _scheduleDisplayNotify();
  }

  void _trimDisplayLines() {
    // 文本缓存限制（按字节）
    while (_receivedTextBytes > _maxReceivedTextBytes &&
        _receivedLines.isNotEmpty) {
      final removed = _receivedLines.removeFirst();
      _receivedTextBytes -= removed.length * 2;
      _recordTrimmedDisplayLine(removed);
      _shiftPendingLineIndexesAfterRemove();
    }
    // 显示行数限制，超出时按 FIFO 丢弃最早内容。
    while (_receivedLines.length > _displayLineLimit) {
      final removed = _receivedLines.removeFirst();
      _receivedTextBytes -= removed.length * 2;
      _recordTrimmedDisplayLine(removed);
      _shiftPendingLineIndexesAfterRemove();
    }
  }

  void _beginDisplayMutation() {
    if (_displayNotifyTimer == null) {
      _displayBatchHasTrim = false;
    }
  }

  void _recordTrimmedDisplayLine(String line) {
    if (!_displayBatchHasTrim) {
      _displayBatchHasTrim = true;
      _displayTrimRevision++;
      _lastTrimmedDisplayLines = <String>[];
    }
    _lastTrimmedDisplayLines.add(line);
  }

  /// 合并同一帧内的接收更新，避免一个串口数据块中的多行触发多次重建。
  void _scheduleDisplayNotify() {
    if (_displayNotifyTimer != null) return;
    _displayNotifyTimer = Timer(const Duration(milliseconds: 16), () {
      _displayNotifyTimer = null;
      notifyListeners();
    });
  }

  void setDisplayLineLimit(int value) {
    final next = value.clamp(minDisplayLineLimit, maxDisplayLineLimit).toInt();
    if (next == _displayLineLimit) return;

    _displayLineLimit = next;
    _beginDisplayMutation();
    _trimDisplayLines();
    final settings = AppSettings();
    settings.rawDataDisplayLineLimit = next;
    unawaited(settings.save());
    AppLogger().info('接收区最多显示 $next 行', category: 'DATA');
    _scheduleDisplayNotify();
  }

  void setRawDataShellMode(bool value) {
    if (value && !rawDataShellEnabled) return;
    if (rawDataShellMode == value) return;
    rawDataShellMode = value;
    _resetTextLineBuffers();
    final settings = AppSettings();
    settings.rawDataShellMode = value;
    unawaited(settings.save());
    AppLogger().info('Shell模式${value ? '启用' : '关闭'}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void setRawDataShellEnabled(bool value) {
    if (rawDataShellEnabled == value) return;
    rawDataShellEnabled = value;
    if (!value) {
      rawDataShellMode = false;
      _resetTextLineBuffers();
    }
    final settings = AppSettings();
    settings.rawDataShellEnabled = value;
    settings.rawDataShellMode = rawDataShellMode;
    unawaited(settings.save());
    AppLogger().info(
      'Shell入口${value ? '显示' : '隐藏'}，当前Shell模式=$rawDataShellMode',
      category: 'DATA',
    );
    Future.microtask(() => notifyListeners());
  }

  void setRawShellInputMode(RawShellInputMode value) {
    if (rawShellInputMode == value) return;
    rawShellInputMode = value;
    final settings = AppSettings();
    settings.rawDataShellInputMode = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell输入模式切换为 ${value.label}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void setRawDataTerminalFontSize(double value) {
    final next = value.clamp(10.0, 24.0);
    if (rawDataTerminalFontSize == next) return;
    rawDataTerminalFontSize = next;
    final settings = AppSettings();
    settings.rawDataTerminalFontSize = next;
    unawaited(settings.save());
    AppLogger().info('Shell字体大小设置为 $next', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void setRawDataTerminalFontFamily(String value) {
    final next = value.trim().isEmpty ? 'Consolas' : value.trim();
    if (rawDataTerminalFontFamily == next) return;
    rawDataTerminalFontFamily = next;
    final settings = AppSettings();
    settings.rawDataTerminalFontFamily = next;
    unawaited(settings.save());
    AppLogger().info('Shell字体设置为 $next', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void setRawShellThemeMode(RawShellThemeMode value) {
    if (rawShellThemeMode == value) return;
    rawShellThemeMode = value;
    final settings = AppSettings();
    settings.rawDataShellTheme = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell主题切换为 ${value.label}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void setRawShellCursorMode(RawShellCursorMode value) {
    if (rawShellCursorMode == value) return;
    rawShellCursorMode = value;
    final settings = AppSettings();
    settings.rawDataShellCursor = value.value;
    unawaited(settings.save());
    AppLogger().info('Shell光标样式切换为 ${value.label}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void _shiftPendingLineIndexesAfterRemove() {
    _pendingReceiveLineIndex = _shiftPendingLineIndex(_pendingReceiveLineIndex);
    _pendingSendLineIndex = _shiftPendingLineIndex(_pendingSendLineIndex);
  }

  int? _shiftPendingLineIndex(int? index) {
    if (index == null) return null;
    if (index <= 0) return null;
    return index - 1;
  }

  void setReceiveHex(bool value) {
    if (receiveHex == value) return;
    receiveHex = value;
    _aggregator = null;
    _resetTextLineBuffers();
    AppLogger().info('接收显示格式切换为 ${value ? 'HEX' : '文本'}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  /// 设置接收文本解码方式（仅非 HEX 模式生效）
  void setReceiveEncoding(String encoding) {
    if (_receiveEncoding == encoding) return;
    _receiveEncoding = encoding;
    unawaited(_persistEncoding());
    _resetTextLineBuffers();
    AppLogger().info('接收文本解码切换为: $encoding', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  Future<void> _persistEncoding() async {
    final settings = AppSettings();
    settings.rawDataEncoding = _receiveEncoding;
    await settings.save();
  }

  void setShowTimestamp(bool value) {
    if (showTimestamp == value) return;
    showTimestamp = value;
    _aggregator = null;
    _resetTextLineBuffers();
    AppLogger().info('接收时间戳${value ? '启用' : '关闭'}', category: 'DATA');
    Future.microtask(() => notifyListeners());
  }

  void _resetTextLineBuffers() {
    _pendingReceiveText = '';
    _pendingReceiveLineIndex = null;
    _pendingReceiveLinePrefix = '';
    _pendingSendText = '';
    _pendingSendLineIndex = null;
    _pendingSendLinePrefix = '';
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    // 当时间窗口 < 1000us 时显示微秒，否则只显示毫秒
    if (timeWindowUs < 1000) {
      final us = dt.microsecond.toString().padLeft(6, '0');
      return '$h:$m:$s.$ms$us';
    } else {
      return '$h:$m:$s.$ms';
    }
  }

  /// 清空所有数据（切换串口时调用）
  void _clearAllData() {
    _rawBytes.clear();
    _receivedLines.clear();
    _receivedTextBytes = 0;
    _resetTextLineBuffers();
    Future.microtask(() => notifyListeners());
  }

  /// 手动清空数据
  void clearReceivedData() {
    _clearAllData();
    AppLogger().info('接收区已清空', category: 'SERIAL');
  }

  /// 将完整原始接收字节按当前编码重新解码并导出为文本。
  ///
  /// 显示行数上限只影响界面缓存，不影响这里的导出内容。界面生成的时间戳、
  /// 收发方向标记以及手动发送记录不属于原始接收字节，因此不会写入文本文件。
  Future<String?> exportAsText({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call(0.05);
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = outputDirectory ?? Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.txt';
      final file = File(path);
      final bytes = _rawBytes.toBytes();
      onProgress?.call(0.25);
      final encoding = _receiveEncoding;
      final content = await Isolate.run(
        () => _decodeBytesWithEncoding(bytes, encoding),
      );
      onProgress?.call(0.75);
      await file.writeAsString(content);
      onProgress?.call(1);
      AppLogger().info(
        '已导出完整接收文本: $path，编码=$encoding，原始字节=${bytes.length}',
        category: 'DATA',
      );
      return path;
    } catch (e) {
      AppLogger().error('导出失败: $e', category: 'DATA');
      return null;
    }
  }

  /// 导出数据为原始字节文件（末尾附加 CRC-32 校验）
  Future<String?> exportAsRawBytes({
    Directory? outputDirectory,
    ExportProgressCallback? onProgress,
  }) async {
    try {
      onProgress?.call(0.05);
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = outputDirectory ?? Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.bin';
      final file = File(path);

      final bytes = _rawBytes.toBytes();
      onProgress?.call(0.25);
      final output = await Isolate.run(() => _buildRawExportBytes(bytes));
      onProgress?.call(0.75);
      await file.writeAsBytes(output);
      onProgress?.call(1);

      AppLogger().info('已导出原始字节: $path', category: 'DATA');
      return path;
    } catch (e) {
      AppLogger().error('导出失败: $e', category: 'DATA');
      return null;
    }
  }

  /// 获取原始字节数据（不含校验）
  Uint8List get rawBytes => _rawBytes.toBytes();

  /// 获取数据大小信息
  Map<String, String> get dataStats {
    return <String, String>{
      '显示行数': '${receivedLines.length} / $_displayLineLimit',
      '显示文本缓存': '${(_receivedTextBytes / 1024 / 1024).toStringAsFixed(2)} MB',
      '完整原始数据':
          '$_rawBytesSize B (${(_rawBytesSize / 1024 / 1024).toStringAsFixed(2)} MB)',
      '文本导出编码': _receiveEncoding,
    };
  }

  Uint8List? prepareSendData(String text) {
    if (!isConnected) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }
    if (_nativeReader == null) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }

    return _prepareSendPayload(text);
  }

  @visibleForTesting
  Uint8List? prepareSendDataForTest(String text) => _prepareSendPayload(text);

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
    return Uint8List.fromList(utf8.encode(content));
  }

  Uint8List prepareShellTextData(String text) {
    final content = '$text$lineEnding';
    return Uint8List.fromList(utf8.encode(content));
  }

  void send(
    Uint8List data, {
    SendDisplaySource displaySource = SendDisplaySource.user,
    bool? displayAsHex,
  }) {
    _writeBytes(data);
    // 发送的数据也显示在数据窗口
    _addSendDataLine(data, source: displaySource, displayAsHex: displayAsHex);
  }

  Future<void> sendRawBytes(Uint8List data) async {
    _writeBytes(data);
  }

  void _writeBytes(Uint8List data) {
    if (!isConnected) {
      AppLogger().warning('串口未连接，无法发送数据', category: 'SERIAL');
      throw StateError('串口未连接');
    }
    if (_nativeReader != null) {
      final sent = _nativeReader!.write(data);
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
    _cleanupPort();
    Future.microtask(() => notifyListeners());
  }

  void updateRts(bool value) {
    config = config.copyWith(rts: value);
    _saveSettings();
    if (isConnected) {
      if (_nativeReader != null) {
        _nativeReader!.setRts(value);
      }
    }
    AppLogger().info('RTS: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  void updateDtr(bool value) {
    config = config.copyWith(dtr: value);
    _saveSettings();
    if (isConnected) {
      if (_nativeReader != null) {
        _nativeReader!.setDtr(value);
      }
    }
    AppLogger().info('DTR: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  /// 设置时间窗口粒度（微秒）
  void setTimeWindowUs(int us) {
    timeWindowUs = us;
    _aggregator = TimeWindowAggregator(
      windowUs: us,
      onWindowComplete: (timestamp, data) {
        _addRawDataLine(timestamp, data);
      },
    );
    AppLogger().info('时间窗口粒度: $us μs', category: 'SERIAL');
  }

  // ========== 原始数据接收控制 ==========

  /// 开始接收原始数据
  void startRawReceiving() {
    if (!isConnected) {
      AppLogger().warning('串口未连接，无法开始接收', category: 'SERIAL');
      return;
    }
    if (isPlotting) {
      AppLogger().warning('正在绘图中，无法开始接收原始数据', category: 'SERIAL');
      return;
    }
    isRawReceiving = true;
    AppLogger().info('开始接收原始数据', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  /// 停止接收原始数据
  void stopRawReceiving() {
    isRawReceiving = false;
    AppLogger().info('停止接收原始数据', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  @override
  void dispose() {
    // 不要在这里调用 disconnect()，它会触发 notifyListeners()。
    // 如果发生在 super.dispose() 之后会抛异常，因此这里只直接清理资源。
    _disposed = true;
    _flushReceiveLog();
    _flushSendLog();
    _displayNotifyTimer?.cancel();
    _displayNotifyTimer = null;
    _portChangeDebounce?.cancel();
    _portChangeDebounce = null;
    unawaited(_portMonitorSubscription?.cancel());
    _portMonitorSubscription = null;
    _portMonitor?.dispose();
    _portMonitor = null;
    _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _nativeReader?.dispose();
    _nativeReader = null;
    isConnected = false;
    unawaited(ymodemService.dispose());
    _dataController.close();
    _shellDataController.close();
    super.dispose();
  }
}
