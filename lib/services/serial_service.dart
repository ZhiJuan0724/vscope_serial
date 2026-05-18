import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../core/utils/app_logger.dart';
import '../core/utils/crc.dart';
import '../data/models/data_packet.dart';
import '../data/models/serial_config.dart';

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

  void refreshPorts() {
    availablePorts = SerialPort.availablePorts;
    if (config.port != null && !availablePorts.contains(config.port)) {
      config = config.copyWith(port: null);
    }
    AppLogger().info('已刷新串口列表', category: 'SERIAL');
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
    notifyListeners();
    AppLogger().trace('isConnecting=true, 开始异步打开串口', category: 'SERIAL');

    // 如果切换了串口，清空之前的数据
    if (_lastConnectedPort != null && _lastConnectedPort != config.port) {
      _clearAllData();
      AppLogger().trace('已切换串口，数据已清空', category: 'SERIAL');
    }

    try {
      // 步骤1: 在 Isolate 中探测串口可用性（不阻塞UI）
      AppLogger().trace('启动 Isolate 探测串口可用性...', category: 'SERIAL');
      final probeResult = await _openPortInIsolate(
        portName: config.port!,
        baudRate: config.baudRate,
        dataBits: config.dataBits,
        stopBits: config.stopBits,
        parity: config.parity,
        rts: config.rts,
        dtr: config.dtr,
      );
      AppLogger().trace('Isolate 探测结果: success=${probeResult.success}', category: 'SERIAL');

      if (probeResult.success) {
        // Isolate 探测成功，在主线程打开（物理串口路径）
        AppLogger().trace('Isolate 探测成功，主线程打开串口...', category: 'SERIAL');
        await _openPortInMainThread();
      } else {
        // Isolate 探测失败，尝试直接在 Isolate 中打开并保持（虚拟串口路径）
        AppLogger().trace('Isolate 探测失败，尝试虚拟串口路径...', category: 'SERIAL');
        final virtualResult = await _openPortInIsolateKeepOpen(
          portName: config.port!,
          baudRate: config.baudRate,
          dataBits: config.dataBits,
          stopBits: config.stopBits,
          parity: config.parity,
          rts: config.rts,
          dtr: config.dtr,
        );
        if (!virtualResult.success) {
          throw Exception(virtualResult.error ?? '无法打开串口');
        }
        // 虚拟串口路径成功，但需要在主线程重新创建 SerialPortReader
        // 由于虚拟串口已经在 Isolate 中打开，这里直接尝试主线程打开
        // 如果失败，说明该虚拟串口不支持二次打开
        try {
          await _openPortInMainThread();
        } catch (e) {
          AppLogger().warning('虚拟串口主线程打开失败，尝试备用方案: $e', category: 'SERIAL');
          // 备用方案：直接尝试主线程打开，忽略 Isolate 探测结果
          await _openPortInMainThread(skipProbe: true);
        }
      }

      _lastConnectedPort = config.port;
      isConnected = true;
      AppLogger().info('串口已连接: ${config.port} @ ${config.baudRate}', category: 'SERIAL');
    } catch (e) {
      AppLogger().error('连接失败: $e', category: 'SERIAL');
      _cleanupPort();
    } finally {
      isConnecting = false;
      AppLogger().trace('connect() 结束, isConnecting=false', category: 'SERIAL');
      notifyListeners();
    }
  }

  /// 在主线程打开串口
  Future<void> _openPortInMainThread({bool skipProbe = false}) async {
    _serialPort = SerialPort(config.port!);
    final portConfig = SerialPortConfig();
    portConfig.baudRate = config.baudRate;
    portConfig.bits = config.dataBits;
    portConfig.stopBits = config.stopBits;
    portConfig.parity = config.parity;
    portConfig.setFlowControl(SerialPortFlowControl.none);
    portConfig.rts = config.rts ? SerialPortRts.on : SerialPortRts.off;
    portConfig.dtr = config.dtr ? SerialPortDtr.on : SerialPortDtr.off;
    _serialPort!.config = portConfig;

    if (!_serialPort!.openReadWrite()) {
      throw Exception('无法打开串口');
    }
    AppLogger().trace('openReadWrite() 返回 true', category: 'SERIAL');

    _reader = SerialPortReader(_serialPort!);
    _subscription = _reader!.stream.listen(
      (data) => _onDataReceived(data),
      onError: (error) => AppLogger().error('读取错误: $error', category: 'SERIAL'),
    );
    AppLogger().trace('SerialPortReader 创建完成', category: 'SERIAL');
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
    notifyListeners();
  }

  void _cleanupPort() {
    _subscription?.cancel();
    _subscription = null;
    _reader?.close();
    _reader = null;
    _serialPort?.close();
    _serialPort?.dispose();
    _serialPort = null;
    isConnected = false;
  }

  void _onDataReceived(Uint8List data) {
    final packet = DataPacket(data: data);
    AppLogger().debug('接收 ${data.length} bytes', category: 'DATA');
    _dataController.add(packet);

    // 保存原始字节
    _rawBytes.addAll(data);
    _rawBytesSize += data.length;
    while (_rawBytesSize > _maxRawBytes && _rawBytes.isNotEmpty) {
      _rawBytes.removeAt(0);
      _rawBytesSize--;
    }

    // 绘图时不更新原始数据界面
    if (!isPlotting) {
      // 保存为文本行（原始数据页面用）
      String text;
      if (receiveHex) {
        text = packet.hex;
      } else {
        text = utf8.decode(data, allowMalformed: true);
      }

      final ts = showTimestamp
          ? '[${_formatTimestamp(packet.timestamp)}] '
          : '';

      final line = '$ts$text';
      receivedLines.add(line);
      _receivedTextBytes += line.length * 2; // UTF-16 编码估算

      // 文本缓存限制
      while (_receivedTextBytes > _maxReceivedTextBytes && receivedLines.isNotEmpty) {
        final removed = receivedLines.removeAt(0);
        _receivedTextBytes -= removed.length * 2;
      }
      notifyListeners();
    }
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// 清空所有数据（切换串口时调用）
  void _clearAllData() {
    _rawBytes.clear();
    _rawBytesSize = 0;
    receivedLines.clear();
    _receivedTextBytes = 0;
    notifyListeners();
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
    if (_serialPort == null || !isConnected) {
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
    _serialPort!.write(data);
    AppLogger().info('发送 ${data.length} bytes', category: 'DATA');
  }

  void updateRts(bool value) {
    config = config.copyWith(rts: value);
    if (isConnected && _serialPort != null) {
      final cfg = _serialPort!.config;
      cfg.rts = value ? SerialPortRts.on : SerialPortRts.off;
      _serialPort!.config = cfg;
    }
    AppLogger().info('RTS: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    notifyListeners();
  }

  void updateDtr(bool value) {
    config = config.copyWith(dtr: value);
    if (isConnected && _serialPort != null) {
      final cfg = _serialPort!.config;
      cfg.dtr = value ? SerialPortDtr.on : SerialPortDtr.off;
      _serialPort!.config = cfg;
    }
    AppLogger().info('DTR: ${value ? 'ON' : 'OFF'}', category: 'SERIAL');
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _dataController.close();
    super.dispose();
  }
}
