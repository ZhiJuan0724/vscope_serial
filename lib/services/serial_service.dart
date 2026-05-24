import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/chunked_byte_buffer.dart';
import '../data/models/data_packet.dart';
import '../data/models/serial_config.dart';
import 'app_settings.dart';
import 'native_serial_reader.dart';
import 'time_window_aggregator.dart';

/// 串口服务 - 全局单例
class SerialService extends ChangeNotifier {
  static final SerialService _instance = SerialService._internal();
  factory SerialService() => _instance;
  SerialService._internal();

  // 串口相关
  List<String> availablePorts = [];
  SerialConfig config = SerialConfig();
  bool isConnected = false;
  bool isConnecting = false;

  // Windows 原生串口读取器（替代 flutter_libserialport 的读取功能）
  NativeSerialReader? _nativeReader;
  StreamSubscription? _nativeSubscription;

  // 时间窗口聚合器
  TimeWindowAggregator? _aggregator;

  Timer? _receiveLogFlushTimer;
  DateTime? _receiveLogWindowStart;
  bool _receiveLogHighFrequency = false;
  int _receiveLogPacketCount = 0;
  int _receiveLogBytes = 0;
  int _receiveLogFirstPacketBytes = 0;

  static const int _receiveLogDetectPacketCount = 10;
  static const int _receiveLogBatchPacketCount = 50;
  static const Duration _receiveLogDetectWindow = Duration(milliseconds: 200);
  static const Duration _receiveLogMaxBatchWindow = Duration(seconds: 1);

  // 时间窗口粒度（微秒），默认 1000us = 1ms
  int timeWindowUs = 1000;

  // 当前连接的串口标识（用于判断是否需要清空数据）
  String? _lastConnectedPort;

  // 数据流
  final _dataController = StreamController<DataPacket>.broadcast();
  Stream<DataPacket> get dataStream => _dataController.stream;

  // 原始字节数据（内部保留）
  final ChunkedByteBuffer _rawBytes = ChunkedByteBuffer();
  int get _rawBytesSize => _rawBytes.length;

  // 原始文本数据（用于原始数据页面显示）
  final List<String> receivedLines = [];
  int _receivedTextBytes = 0;
  static const int _maxReceivedTextBytes = 128 * 1024 * 1024; // 128MB 文本缓存
  // 虚拟滚动窗口：最多保留500行在内存中用于显示，超出时按FIFO丢弃
  static const int _maxDisplayLines = 500;

  // 显示选项
  bool receiveHex = false;
  bool showTimestamp = false;
  bool autoScroll = true;

  // 发送选项
  bool sendHex = false;
  bool enableCrc = false;
  bool crcReverseBytes = false; // CRC 高低位反转
  CrcType crcType = CrcType.crc16;
  String crcPolyName = 'CRC-16/MODBUS';

  // 绘图选项
  bool useRandomSource = false;

  // 绘图状态标志
  bool isPlotting = false;

  // 原始数据接收开关（独立于串口连接和绘图状态）
  bool isRawReceiving = false;

  /// 从 AppSettings 加载配置
  void loadSettings() {
    final settings = AppSettings();
    config = settings.saveToSerialConfig();
    useRandomSource = settings.useRandomSource;
  }

  /// 保存配置到 AppSettings
  void _saveSettings() {
    final settings = AppSettings();
    settings.loadFromSerialConfig(config);
    settings.useRandomSource = useRandomSource;
    settings.save();
  }

  void refreshPorts() {
    availablePorts = SerialPort.availablePorts;
    if (config.port != null && !availablePorts.contains(config.port)) {
      config = config.copyWith(port: null);
    }
    AppLogger().info('已刷新串口列表', category: 'SERIAL');
    // Defer notifyListeners to avoid calling during build phase
    Future.microtask(() => notifyListeners());
  }

  /// 更新串口配置并通知监听者（供外部调用）
  void updateConfig(SerialConfig newConfig) {
    config = newConfig;
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

    // 如果切换了串口，清空之前的数据
    if (_lastConnectedPort != null && _lastConnectedPort != config.port) {
      _clearAllData();
      AppLogger().trace('已切换串口，数据已清空', category: 'SERIAL');
    }

    try {
      // 直接使用 NativeSerialReader 打开串口（跳过 Isolate 探测）
      AppLogger().trace('使用 NativeSerialReader 打开串口...', category: 'SERIAL');
      await _openPortInMainThread();

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
    } finally {
      isConnecting = false;
      AppLogger().trace('connect() 结束, isConnecting=false', category: 'SERIAL');
      Future.microtask(() => notifyListeners());
    }
  }

  /// 在主线程打开串口
  Future<void> _openPortInMainThread() async {
    // 使用 Windows 原生串口读取器替代 flutter_libserialport 的 SerialPortReader
    _nativeReader = NativeSerialReader();
    // Initialize Dart API with NativeApi.initializeApiDLData before opening
    final initData = NativeApi.initializeApiDLData;
    _nativeReader!.initDartApi(initData);
    final opened = _nativeReader!.open(config.port!, config.baudRate);
    if (!opened) {
      throw Exception('无法打开串口');
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
    final shouldReceiveRaw = isConnected && isRawReceiving && !isPlotting;
    if (!isPlotting && !shouldReceiveRaw) {
      return;
    }

    if (isPlotting) {
      _dataController.add(DataPacket(data: data));
    }

    if (shouldReceiveRaw) {
      _recordReceiveLog(data.length);
      _rawBytes.append(data);

      // 使用 C++ 提供的微秒级时间戳
      final receiveTime = DateTime.fromMicrosecondsSinceEpoch(
        nativeData.timestampUs,
      );

      if (showTimestamp) {
        // 开启时间戳时使用时间窗口聚合器分包
        _aggregator ??= TimeWindowAggregator(
          windowUs: timeWindowUs,
          onWindowComplete: (timestamp, aggregatedData) {
            _addRawDataLine(timestamp, aggregatedData);
          },
        );
        _aggregator!.feed(data, receiveTime);
      } else {
        // 不开启时间戳时直接显示，不强制分包
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
        _receiveLogPacketCount >= _receiveLogDetectPacketCount &&
        elapsed <= _receiveLogDetectWindow) {
      _receiveLogHighFrequency = true;
    }

    if (_receiveLogHighFrequency) {
      if (_receiveLogPacketCount >= _receiveLogBatchPacketCount ||
          elapsed >= _receiveLogMaxBatchWindow) {
        _flushReceiveLog(now);
      } else {
        _scheduleReceiveLogFlush(_receiveLogMaxBatchWindow - elapsed);
      }
      return;
    }

    if (elapsed >= _receiveLogDetectWindow) {
      _flushReceiveLog(now);
    } else {
      _scheduleReceiveLogFlush(_receiveLogDetectWindow - elapsed);
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

  /// 添加一行接收数据显示
  void _addRawDataLine(DateTime timestamp, Uint8List data) {
    String text;
    if (receiveHex) {
      text = data
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
    } else {
      text = utf8.decode(data, allowMalformed: true);
    }

    final ts = showTimestamp ? '[${_formatTimestamp(timestamp)}] ' : '';
    final line = '← $ts$text (${data.length} bytes)';

    _addDisplayLine(line);
  }

  /// 添加一行发送数据显示
  void _addSendDataLine(Uint8List data) {
    String text;
    if (sendHex) {
      text = data
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
    } else {
      text = utf8.decode(data, allowMalformed: true);
    }

    final ts = showTimestamp ? '[${_formatTimestamp(DateTime.now())}] ' : '';
    // 当发送HEX但显示模式不是HEX时，标记为 [HEX] 以便区分
    final hexMark = (sendHex && !receiveHex) ? '[HEX] ' : '';
    final line = '→ $ts$hexMark$text (${data.length} bytes)';

    _addDisplayLine(line);
  }

  /// 添加一行到显示列表（通用）
  void _addDisplayLine(String line) {
    receivedLines.add(line);
    _receivedTextBytes += line.length * 2; // UTF-16 编码估算

    // 文本缓存限制（按字节）
    while (_receivedTextBytes > _maxReceivedTextBytes &&
        receivedLines.isNotEmpty) {
      final removed = receivedLines.removeAt(0);
      _receivedTextBytes -= removed.length * 2;
    }
    // 显示行数限制（虚拟滚动：最多保留 _maxDisplayLines 行）
    while (receivedLines.length > _maxDisplayLines) {
      final removed = receivedLines.removeAt(0);
      _receivedTextBytes -= removed.length * 2;
    }
    Future.microtask(() => notifyListeners());
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
    receivedLines.clear();
    _receivedTextBytes = 0;
    Future.microtask(() => notifyListeners());
  }

  /// 手动清空数据
  void clearReceivedData() {
    _clearAllData();
    AppLogger().info('接收区已清空', category: 'SERIAL');
  }

  /// 导出数据为字符串文件
  Future<String?> exportAsText() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.txt';
      final file = File(path);
      final content = receivedLines.join('\n');
      await file.writeAsString(content);
      AppLogger().info('已导出文本: $path', category: 'DATA');
      return path;
    } catch (e) {
      AppLogger().error('导出失败: $e', category: 'DATA');
      return null;
    }
  }

  /// 导出数据为原始字节文件（末尾附加 CRC-32 校验）
  Future<String?> exportAsRawBytes() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory('${exeDir.path}/exports');
      await dir.create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vscope_serial_$timestamp.bin';
      final file = File(path);

      // 原始数据
      final bytes = _rawBytes.toBytes();

      // 计算 CRC-32 并附加到末尾
      final crcPoly = crc32Polys['CRC-32']!;
      final crcValue = calculateCrc(bytes, crcPoly);
      final crcBytes = crcToBytes(crcValue, 32);

      // 写入文件：数据 + CRC
      final output = BytesBuilder();
      output.add(bytes);
      output.add(Uint8List.fromList(crcBytes));
      await file.writeAsBytes(output.toBytes());

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
  Map<String, String> get dataStats => {
    '原始字节':
        '$_rawBytesSize B (${(_rawBytesSize / 1024 / 1024).toStringAsFixed(2)} MB)',
    '文本行数': '${receivedLines.length}',
    '文本缓存': '${(_receivedTextBytes / 1024 / 1024).toStringAsFixed(2)} MB',
  };

  Uint8List? prepareSendData(String text) {
    if (!isConnected) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }
    if (_nativeReader == null) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }

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
        data = Uint8List.fromList(utf8.encode(text));
      }

      // 追加 CRC
      if (enableCrc && sendHex) {
        final poly = getPolysByType(crcType)[crcPolyName];
        if (poly != null) {
          final crc = calculateCrc(data, poly);
          var crcBytes = crcToBytes(crc, poly.width);
          // 如果勾选高低位反转，反转 CRC 字节顺序
          if (crcReverseBytes) {
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

  void send(Uint8List data) {
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
      AppLogger().info('发送 $sent bytes', category: 'DATA');
    } else {
      _handleIoDisconnected('发送失败，串口读取器不可用');
      throw StateError('串口已断开连接，发送失败');
    }
    // 发送的数据也显示在数据窗口
    _addSendDataLine(data);
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
    // Do NOT call disconnect() here - it triggers notifyListeners()
    // which will throw if called after super.dispose().
    // Just clean up resources directly.
    _flushReceiveLog();
    _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _nativeReader?.dispose();
    _nativeReader = null;
    isConnected = false;
    _dataController.close();
    super.dispose();
  }
}
