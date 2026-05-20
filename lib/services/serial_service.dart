import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/data_packet.dart';
import '../data/models/serial_config.dart';
import 'app_settings.dart';
import 'native_serial_reader.dart';
import 'time_window_aggregator.dart';

class _OpenPortArgs {
  final SendPort sendPort;
  final String portName;
  final int baudRate;
  final int dataBits;
  final int stopBits;
  final int parity;
  final bool rts;
  final bool dtr;

  _OpenPortArgs({
    required this.sendPort,
    required this.portName,
    required this.baudRate,
    required this.dataBits,
    required this.stopBits,
    required this.parity,
    required this.rts,
    required this.dtr,
  });
}

class _OpenPortResult {
  final bool success;
  final String? error;

  _OpenPortResult({required this.success, this.error});
}

/// 串口服务 - 全局单例
class SerialService extends ChangeNotifier {
  static final SerialService _instance = SerialService._internal();
  factory SerialService() => _instance;
  SerialService._internal();

  // 串口相关
  List<String> availablePorts = [];
  SerialConfig config = SerialConfig();
  SerialPort? _serialPort;
  SerialPortReader? _reader;
  StreamSubscription? _subscription;
  bool isConnected = false;
  bool isConnecting = false;

  // Windows 原生串口读取器（替代 flutter_libserialport 的读取功能）
  NativeSerialReader? _nativeReader;
  StreamSubscription? _nativeSubscription;

  // 时间窗口聚合器
  TimeWindowAggregator? _aggregator;

  // 时间窗口粒度（毫秒），默认 1ms
  int timeWindowMs = 1;

  // 当前连接的串口标识（用于判断是否需要清空数据）
  String? _lastConnectedPort;

  // 数据流
  final _dataController = StreamController<DataPacket>.broadcast();
  Stream<DataPacket> get dataStream => _dataController.stream;

  // 原始字节数据（内部保留）
  final List<int> _rawBytes = [];
  int _rawBytesSize = 0;
  static const int _maxRawBytes = 512 * 1024 * 1024; // 512MB

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
    notifyListeners();
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
      AppLogger().trace('connect() 被忽略，isConnecting=$isConnecting, isConnected=$isConnected', category: 'SERIAL');
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
      AppLogger().info('串口已连接: ${config.port} @ ${config.baudRate}', category: 'SERIAL');
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
  Future<void> _openPortInMainThread({bool skipProbe = false}) async {
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

    // 启动读取（timeoutMs=10 表示 10ms 超时，避免阻塞）
    _nativeReader!.startReading(timeoutMs: 10);

    // 监听数据流
    _nativeSubscription = _nativeReader!.dataStream.listen(
      (nativeData) => _onNativeDataReceived(nativeData),
      onError: (error) => AppLogger().error('原生读取错误: $error', category: 'SERIAL'),
    );

    AppLogger().trace('NativeSerialReader 读取线程已启动', category: 'SERIAL');
  }

  static Future<_OpenPortResult> _openPortInIsolate({
    required String portName,
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required int parity,
    required bool rts,
    required bool dtr,
  }) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(
      _openPortIsolateEntry,
      _OpenPortArgs(
        sendPort: receivePort.sendPort,
        portName: portName,
        baudRate: baudRate,
        dataBits: dataBits,
        stopBits: stopBits,
        parity: parity,
        rts: rts,
        dtr: dtr,
      ),
    );
    return await receivePort.first as _OpenPortResult;
  }

  static void _openPortIsolateEntry(_OpenPortArgs args) {
    try {
      final port = SerialPort(args.portName);
      final portConfig = SerialPortConfig();
      portConfig.baudRate = args.baudRate;
      portConfig.bits = args.dataBits;
      portConfig.stopBits = args.stopBits;
      portConfig.parity = args.parity;
      portConfig.setFlowControl(SerialPortFlowControl.none);
      portConfig.rts = args.rts ? SerialPortRts.on : SerialPortRts.off;
      portConfig.dtr = args.dtr ? SerialPortDtr.on : SerialPortDtr.off;
      port.config = portConfig;

      final opened = port.openReadWrite();
      port.close();
      port.dispose();

      args.sendPort.send(_OpenPortResult(success: opened));
    } catch (e) {
      args.sendPort.send(_OpenPortResult(success: false, error: e.toString()));
    }
  }

  /// 在 Isolate 中打开串口并保持打开状态（用于虚拟串口）
  static Future<_OpenPortResult> _openPortInIsolateKeepOpen({
    required String portName,
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required int parity,
    required bool rts,
    required bool dtr,
  }) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(
      _openPortIsolateKeepOpenEntry,
      _OpenPortArgs(
        sendPort: receivePort.sendPort,
        portName: portName,
        baudRate: baudRate,
        dataBits: dataBits,
        stopBits: stopBits,
        parity: parity,
        rts: rts,
        dtr: dtr,
      ),
    );
    return await receivePort.first as _OpenPortResult;
  }

  static void _openPortIsolateKeepOpenEntry(_OpenPortArgs args) {
    try {
      final port = SerialPort(args.portName);
      final portConfig = SerialPortConfig();
      portConfig.baudRate = args.baudRate;
      portConfig.bits = args.dataBits;
      portConfig.stopBits = args.stopBits;
      portConfig.parity = args.parity;
      portConfig.setFlowControl(SerialPortFlowControl.none);
      portConfig.rts = args.rts ? SerialPortRts.on : SerialPortRts.off;
      portConfig.dtr = args.dtr ? SerialPortDtr.on : SerialPortDtr.off;
      port.config = portConfig;

      final opened = port.openReadWrite();
      if (opened) {
        // 保持打开一小段时间，测试虚拟串口稳定性
        sleep(const Duration(milliseconds: 100));
        port.close();
      }
      port.dispose();

      args.sendPort.send(_OpenPortResult(success: opened));
    } catch (e) {
      args.sendPort.send(_OpenPortResult(success: false, error: e.toString()));
    }
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
    _subscription?.cancel();
    _subscription = null;
    _reader?.close();
    _reader = null;
    _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _nativeReader?.close();
    _nativeReader = null;
    _serialPort?.close();
    _serialPort?.dispose();
    _serialPort = null;
    isConnected = false;
    // 断开串口时自动关闭原始数据接收
    if (isRawReceiving) {
      isRawReceiving = false;
    }
  }

  /// 初始化时间窗口聚合器
  void _initAggregator() {
    _aggregator = TimeWindowAggregator(
      windowMs: timeWindowMs,
      onWindowComplete: (timestamp, data) {
        _addRawDataLine(timestamp, data);
      },
    );
  }

  /// 原生串口数据接收回调
  void _onNativeDataReceived(NativeSerialData nativeData) {
    final data = nativeData.data;
    print('[SerialService._onNativeDataReceived] Received ${data.length} bytes');

    // 绘图时禁用逐包debug日志
    if (!isPlotting) {
      AppLogger().debug('接收 ${data.length} bytes', category: 'DATA');
    }

    // 转发给绘图数据流（保持兼容）
    _dataController.add(DataPacket(data: data));

    // 保存原始字节（始终保存，用于导出）
    _rawBytes.addAll(data);
    _rawBytesSize += data.length;
    while (_rawBytesSize > _maxRawBytes && _rawBytes.isNotEmpty) {
      _rawBytes.removeAt(0);
      _rawBytesSize--;
    }

    // 原始数据文本接收条件：串口已连接 + 用户开启接收 + 不在绘图状态
    final shouldReceiveRaw = isConnected && isRawReceiving && !isPlotting;
    print('[SerialService._onNativeDataReceived] shouldReceiveRaw=$shouldReceiveRaw, isConnected=$isConnected, isRawReceiving=$isRawReceiving, isPlotting=$isPlotting');
    if (shouldReceiveRaw) {
      // 使用时间窗口聚合器聚合数据
      _aggregator ??= TimeWindowAggregator(
        windowMs: timeWindowMs,
        onWindowComplete: (timestamp, aggregatedData) {
          _addRawDataLine(timestamp, aggregatedData);
        },
      );

      // 使用 C++ 提供的微秒级时间戳，转换为毫秒精度
      final receiveTime = DateTime.fromMicrosecondsSinceEpoch(
        nativeData.timestampUs,
      );
      _aggregator!.feed(data, receiveTime);
    }
  }

  /// 添加一行原始数据显示
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
    final line = '$ts$text (${data.length} bytes)';

    receivedLines.add(line);
    _receivedTextBytes += line.length * 2; // UTF-16 编码估算

    // 文本缓存限制（按字节）
    while (_receivedTextBytes > _maxReceivedTextBytes && receivedLines.isNotEmpty) {
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
    final us = dt.microsecond.toString().padLeft(6, '0');
    return '$h:$m:$s.$ms$us';
  }

  /// 清空所有数据（切换串口时调用）
  void _clearAllData() {
    _rawBytes.clear();
    _rawBytesSize = 0;
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
      final bytes = Uint8List.fromList(_rawBytes);

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
  Uint8List get rawBytes => Uint8List.fromList(_rawBytes);

  /// 获取数据大小信息
  Map<String, String> get dataStats => {
    '原始字节': '$_rawBytesSize B (${(_rawBytesSize / 1024 / 1024).toStringAsFixed(2)} MB)',
    '文本行数': '${receivedLines.length}',
    '文本缓存': '${(_receivedTextBytes / 1024 / 1024).toStringAsFixed(2)} MB',
  };

  Uint8List? prepareSendData(String text) {
    if (!isConnected) {
      AppLogger().error('串口未连接', category: 'SERIAL');
      return null;
    }
    if (_serialPort == null && _nativeReader == null) {
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
          final crcBytes = crcToBytes(crc, poly.width);
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
    print('[SerialService.send] _nativeReader=$_nativeReader, _serialPort=$_serialPort');
    if (_nativeReader != null) {
      print('[SerialService.send] _nativeReader.isOpen=${_nativeReader!.isOpen}');
      final sent = _nativeReader!.write(data);
      AppLogger().info('发送 $sent bytes', category: 'DATA');
      print('[SerialService.send] sent=$sent');
    } else if (_serialPort != null) {
      _serialPort!.write(data);
      AppLogger().info('发送 ${data.length} bytes', category: 'DATA');
    } else {
      throw StateError('串口未连接');
    }
  }

  void updateRts(bool value) {
    config = config.copyWith(rts: value);
    _saveSettings();
    if (isConnected) {
      if (_nativeReader != null) {
        _nativeReader!.setRts(value);
      } else if (_serialPort != null) {
        final cfg = _serialPort!.config;
        cfg.rts = value ? SerialPortRts.on : SerialPortRts.off;
        _serialPort!.config = cfg;
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
      } else if (_serialPort != null) {
        final cfg = _serialPort!.config;
        cfg.dtr = value ? SerialPortDtr.on : SerialPortDtr.off;
        _serialPort!.config = cfg;
      }
    }
    AppLogger().info('DTR: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    Future.microtask(() => notifyListeners());
  }

  /// 设置时间窗口粒度（毫秒）
  void setTimeWindowMs(int ms) {
    timeWindowMs = ms;
    _aggregator = TimeWindowAggregator(
      windowMs: ms,
      onWindowComplete: (timestamp, data) {
        _addRawDataLine(timestamp, data);
      },
    );
    AppLogger().info('时间窗口粒度: ${ms}ms', category: 'SERIAL');
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
    _subscription?.cancel();
    _subscription = null;
    _reader?.close();
    _reader = null;
    _nativeSubscription?.cancel();
    _nativeSubscription = null;
    _nativeReader?.dispose();
    _nativeReader = null;
    // NOTE: Do NOT call _serialPort?.dispose() on app exit.
    // flutter_libserialport's C library may call abort() during process
    // termination cleanup. Let the OS reclaim the handle instead.
    _serialPort?.close();
    _serialPort = null;
    isConnected = false;
    _dataController.close();
    super.dispose();
  }
}
