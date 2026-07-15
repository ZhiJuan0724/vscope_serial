import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import '../core/utils/app_logger.dart';

// 加载 DLL
final DynamicLibrary _dll = _loadDll();

DynamicLibrary _loadDll() {
  // 在开发模式下，DLL 在 build/windows/x64/runner/Release/ 或 Debug/
  // 在发布模式下，DLL 和 exe 在同一目录
  if (Platform.resolvedExecutable.contains('build')) {
    // 尝试多个路径
    final possiblePaths = [
      '${File(Platform.resolvedExecutable).parent.path}/native_serial_reader.dll',
      '${File(Platform.resolvedExecutable).parent.parent.path}/native_serial_reader.dll',
      '${Directory.current.path}/build/windows/x64/runner/Release/native_serial_reader.dll',
      '${Directory.current.path}/build/windows/x64/runner/Debug/native_serial_reader.dll',
    ];
    for (final path in possiblePaths) {
      if (File(path).existsSync()) {
        return DynamicLibrary.open(path);
      }
    }
  }
  // 默认：和 exe 同目录
  return DynamicLibrary.open('native_serial_reader.dll');
}

// Dart API DL 初始化
typedef NsrInitDartApiC = Int32 Function(Pointer<Void> data);
typedef NsrInitDartApiDart = int Function(Pointer<Void> data);

// FFI 函数签名
typedef NsrOpenPortC = Int32 Function(Pointer<Utf8> portName, Int32 baudRate);
typedef NsrOpenPortDart = int Function(Pointer<Utf8> portName, int baudRate);

typedef NsrClosePortC = Void Function();
typedef NsrClosePortDart = void Function();

typedef NsrSetConfigC =
    Int32 Function(Int32 dataBits, Int32 stopBits, Int32 parity);
typedef NsrSetConfigDart = int Function(int dataBits, int stopBits, int parity);

typedef NsrSetRtsC = Void Function(Int32 on);
typedef NsrSetRtsDart = void Function(int on);

typedef NsrSetDtrC = Void Function(Int32 on);
typedef NsrSetDtrDart = void Function(int on);

typedef NsrStartReadingC = Int32 Function(Int64 dartPort, Int32 timeoutMs);
typedef NsrStartReadingDart = int Function(int dartPort, int timeoutMs);

typedef NsrStopReadingC = Void Function();
typedef NsrStopReadingDart = void Function();

typedef NsrWriteC = Int32 Function(Pointer<Uint8> data, Int32 length);
typedef NsrWriteDart = int Function(Pointer<Uint8> data, int length);

typedef NsrIsOpenC = Int32 Function();
typedef NsrIsOpenDart = int Function();

typedef NsrIsConnectionHealthyC = Int32 Function();
typedef NsrIsConnectionHealthyDart = int Function();

typedef NsrListPortsC = Int32 Function(Pointer<Uint8> buffer, Int32 capacity);
typedef NsrListPortsDart = int Function(Pointer<Uint8> buffer, int capacity);

typedef NsrListPortDetailsC =
    Int32 Function(Pointer<Uint8> buffer, Int32 capacity);
typedef NsrListPortDetailsDart =
    int Function(Pointer<Uint8> buffer, int capacity);

typedef NsrStartPortMonitorC = Int32 Function(Int64 dartPort);
typedef NsrStartPortMonitorDart = int Function(int dartPort);

typedef NsrStopPortMonitorC = Void Function();
typedef NsrStopPortMonitorDart = void Function();

// 获取函数指针
final _nsrInitDartApi = _dll
    .lookupFunction<NsrInitDartApiC, NsrInitDartApiDart>('nsr_init_dart_api');
final _nsrOpenPort = _dll.lookupFunction<NsrOpenPortC, NsrOpenPortDart>(
  'nsr_open_port',
);
final _nsrClosePort = _dll.lookupFunction<NsrClosePortC, NsrClosePortDart>(
  'nsr_close_port',
);
final _nsrSetConfig = _dll.lookupFunction<NsrSetConfigC, NsrSetConfigDart>(
  'nsr_set_config',
);
final _nsrSetRts = _dll.lookupFunction<NsrSetRtsC, NsrSetRtsDart>(
  'nsr_set_rts',
);
final _nsrSetDtr = _dll.lookupFunction<NsrSetDtrC, NsrSetDtrDart>(
  'nsr_set_dtr',
);
final _nsrStartReading = _dll
    .lookupFunction<NsrStartReadingC, NsrStartReadingDart>('nsr_start_reading');
final _nsrStopReading = _dll
    .lookupFunction<NsrStopReadingC, NsrStopReadingDart>('nsr_stop_reading');
final _nsrWrite = _dll.lookupFunction<NsrWriteC, NsrWriteDart>('nsr_write');
final _nsrIsOpen = _dll.lookupFunction<NsrIsOpenC, NsrIsOpenDart>(
  'nsr_is_open',
);
final _nsrIsConnectionHealthy = _dll
    .lookupFunction<NsrIsConnectionHealthyC, NsrIsConnectionHealthyDart>(
      'nsr_is_connection_healthy',
    );
final _nsrListPorts = _dll.lookupFunction<NsrListPortsC, NsrListPortsDart>(
  'nsr_list_ports',
);
final _nsrListPortDetails = _dll
    .lookupFunction<NsrListPortDetailsC, NsrListPortDetailsDart>(
      'nsr_list_port_details',
    );
final _nsrStartPortMonitor = _dll
    .lookupFunction<NsrStartPortMonitorC, NsrStartPortMonitorDart>(
      'nsr_start_port_monitor',
    );
final _nsrStopPortMonitor = _dll
    .lookupFunction<NsrStopPortMonitorC, NsrStopPortMonitorDart>(
      'nsr_stop_port_monitor',
    );

List<String> _listNativePorts() {
  final required = _nsrListPorts(nullptr, 0);
  if (required < 0) {
    throw StateError('Windows 串口枚举失败: $required');
  }
  if (required < 2) return const [];

  final buffer = calloc<Uint8>(required);
  try {
    final written = _nsrListPorts(buffer, required);
    if (written < 0) {
      throw StateError('Windows 串口枚举失败: $written');
    }
    if (written > required) {
      // 插拔可能导致两次调用之间的列表长度发生变化，重新读取即可。
      return _listNativePorts();
    }

    final bytes = buffer.asTypedList(written);
    final ports = <String>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      if (i == start) break;
      ports.add(utf8.decode(bytes.sublist(start, i)));
      start = i + 1;
    }
    return ports;
  } finally {
    calloc.free(buffer);
  }
}

List<NativeSerialPortDetail> _listNativePortDetails() {
  final required = _nsrListPortDetails(nullptr, 0);
  if (required < 0) {
    throw StateError('Windows 串口详细信息枚举失败: $required');
  }
  if (required < 2) return const [];

  final buffer = calloc<Uint8>(required);
  try {
    final written = _nsrListPortDetails(buffer, required);
    if (written < 0) {
      throw StateError('Windows 串口详细信息枚举失败: $written');
    }
    if (written > required) {
      return _listNativePortDetails();
    }

    final bytes = buffer.asTypedList(written);
    final details = <NativeSerialPortDetail>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0) continue;
      if (i == start) break;
      final entry = utf8.decode(bytes.sublist(start, i));
      final separator = entry.indexOf('\t');
      final port = separator < 0 ? entry : entry.substring(0, separator);
      final name = separator < 0 ? '' : entry.substring(separator + 1);
      if (port.isNotEmpty) {
        details.add(NativeSerialPortDetail(port: port, name: name));
      }
      start = i + 1;
    }
    return details;
  } finally {
    calloc.free(buffer);
  }
}

bool _checkNativeConnectionHealth() => _nsrIsConnectionHealthy() == 1;

int _writeNativeBytes(Uint8List data) {
  final ptr = calloc<Uint8>(data.length);
  try {
    ptr.asTypedList(data.length).setAll(0, data);
    return _nsrWrite(ptr, data.length);
  } finally {
    calloc.free(ptr);
  }
}

/// 常驻 isolate 的串口写入循环。
///
/// ReceivePort 按消息到达顺序逐条处理，保证普通发送、Shell 和文件传输
/// 共用同一条有序写入链路，同时避免同步 FFI 写入阻塞 Flutter UI isolate。
Future<void> _nativeWriteIsolateMain(SendPort readyPort) async {
  final commands = ReceivePort();
  readyPort.send(commands.sendPort);
  await for (final message in commands) {
    if (message is! List || message.length < 2) continue;
    final replyPort = message[0] as SendPort;
    final requestId = message[1] as int;
    if (message.length == 2) {
      replyPort.send(<Object?>[requestId, null, null]);
      commands.close();
      break;
    }

    try {
      final data =
          (message[2] as TransferableTypedData).materialize().asUint8List();
      final written = _writeNativeBytes(data);
      replyPort.send(<Object?>[requestId, written, null]);
    } catch (error, stackTrace) {
      replyPort.send(<Object?>[requestId, null, '$error\n$stackTrace']);
    }
  }
}

class _NativeSerialWriteQueue {
  final ReceivePort _responses = ReceivePort();
  final Map<int, Completer<int?>> _pending = <int, Completer<int?>>{};
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  int _nextRequestId = 1;
  bool _closing = false;

  _NativeSerialWriteQueue() {
    _responses.listen((message) {
      if (message is SendPort) {
        _commands = message;
        return;
      }
      if (message is! List || message.length < 3) return;
      final requestId = message[0] as int;
      final completer = _pending.remove(requestId);
      if (completer == null) return;
      final error = message[2];
      if (error != null) {
        completer.completeError(StateError(error as String));
      } else {
        completer.complete(message[1] as int?);
      }
    });
  }

  Future<void> _ensureStarted() {
    final existing = _starting;
    if (existing != null) return existing;
    final completer = Completer<void>();
    _starting = completer.future;
    Isolate.spawn(_nativeWriteIsolateMain, _responses.sendPort).then((
      isolate,
    ) async {
      _isolate = isolate;
      while (_commands == null) {
        await Future<void>.delayed(Duration.zero);
      }
      completer.complete();
    }, onError: completer.completeError);
    return completer.future;
  }

  Future<int> write(Uint8List data) async {
    if (_closing) throw StateError('串口写入队列正在关闭');
    if (data.isEmpty) return 0;
    await _ensureStarted();
    final requestId = _nextRequestId++;
    final completer = Completer<int?>();
    _pending[requestId] = completer;
    _commands!.send(<Object>[
      _responses.sendPort,
      requestId,
      TransferableTypedData.fromList(<Uint8List>[data]),
    ]);
    return (await completer.future)!;
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    if (_starting == null) {
      _responses.close();
      return;
    }
    await _ensureStarted();
    final requestId = _nextRequestId++;
    final completer = Completer<int?>();
    _pending[requestId] = completer;
    _commands!.send(<Object>[_responses.sendPort, requestId]);
    await completer.future;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _responses.close();
  }
}

class NativeSerialPortDetail {
  final String port;
  final String name;

  const NativeSerialPortDetail({required this.port, required this.name});
}

/// Windows 原生串口读取器
class NativeSerialReader {
  final _dataController = StreamController<NativeSerialData>.broadcast();
  Stream<NativeSerialData> get dataStream => _dataController.stream;

  ReceivePort? _receivePort;
  bool _isOpen = false;
  bool _dartApiInitialized = false;
  final _writeQueue = _NativeSerialWriteQueue();

  /// 初始化 Dart API（必须在其它操作前调用）。
  ///
  /// 调用方需要传入 dart:ffi 的 [NativeApi.initializeApiDLData]。
  /// 示例：initDartApi(NativeApi.initializeApiDLData)。
  bool initDartApi(Pointer<Void> initData) {
    if (_dartApiInitialized) return true;
    if (initData == nullptr) return false;

    final result = _nsrInitDartApi(initData);
    _dartApiInitialized = result == 0;
    return _dartApiInitialized;
  }

  /// 打开串口
  ///
  /// [initData] should be [NativeApi.initializeApiDLData] from dart:ffi.
  /// 如果没有提供，调用方必须在 [startReading] 前先调用 [initDartApi]。
  bool open(String portName, int baudRate, {Pointer<Void>? initData}) {
    // 如果提供了 initData，则确保 Dart API 已初始化。
    if (initData != null && !_dartApiInitialized) {
      initDartApi(initData);
    }

    final namePtr = portName.toNativeUtf8();
    try {
      final result = _nsrOpenPort(namePtr, baudRate);
      _isOpen = result == 0;
      return _isOpen;
    } finally {
      calloc.free(namePtr);
    }
  }

  /// 在 UI isolate 之外打开原生句柄。
  ///
  /// Windows CreateFile 在端口不可用时可能阻塞。
  /// 原生 DLL 状态是进程级的，后台操作完成后 UI isolate 可以挂接该句柄。
  static Future<bool> openInBackground(String portName, int baudRate) {
    return Isolate.run(() => _openNativePort(portName, baudRate));
  }

  /// 将当前读取器实例挂接到 [openInBackground] 打开的句柄。
  bool attachToOpenPort() {
    _isOpen = _nsrIsOpen() == 1;
    return _isOpen;
  }

  /// 关闭串口
  Future<void> close() async {
    stopReading();
    await _writeQueue.close();
    await Isolate.run(_closeNativePort);
    _isOpen = false;
  }

  /// 设置串口参数
  bool setConfig(int dataBits, int stopBits, int parity) {
    return _nsrSetConfig(dataBits, stopBits, parity) == 0;
  }

  /// 设置 RTS
  void setRts(bool on) => _nsrSetRts(on ? 1 : 0);

  /// 设置 DTR
  void setDtr(bool on) => _nsrSetDtr(on ? 1 : 0);

  /// 启动读取
  /// [timeoutMs]: ReadFile 超时时间（毫秒）
  ///   - 0: 阻塞直到有数据
  ///   - >0: 超时时间，超时后返回已读取的数据
  bool startReading({int timeoutMs = 0}) {
    if (!_isOpen) return false;
    if (_receivePort != null) return false;

    // 创建 ReceivePort 接收 C++ 回调
    _receivePort = ReceivePort();
    _receivePort!.listen(_onDataReceived);

    final result = _nsrStartReading(
      _receivePort!.sendPort.nativePort,
      timeoutMs,
    );
    if (result != 0) {
      _receivePort?.close();
      _receivePort = null;
      return false;
    }
    return true;
  }

  /// 停止读取
  void stopReading() {
    _nsrStopReading();
    // 先停止原生线程，确保不会再投递消息。
    _receivePort?.close();
    _receivePort = null;
  }

  /// 发送数据
  Future<int> write(Uint8List data) => _writeQueue.write(data);

  /// 是否打开
  bool get isOpen => _nsrIsOpen() == 1;

  /// 外部断开后，已打开句柄是否仍有响应。
  bool get isConnectionHealthy => _nsrIsConnectionHealthy() == 1;

  /// 在后台 isolate 中枚举串口，避免异常驱动阻塞 Flutter UI。
  static Future<List<String>> listPortsInBackground() {
    return Isolate.run(_listNativePorts);
  }

  /// 在后台 isolate 中读取串口友好名称，仅供用户主动开启详细信息时调用。
  static Future<List<NativeSerialPortDetail>> listPortDetailsInBackground() {
    return Isolate.run(_listNativePortDetails);
  }

  /// 在后台 isolate 中检查句柄，驱动异常时不阻塞 Flutter UI。
  static Future<bool> checkConnectionHealthInBackground() {
    return Isolate.run(_checkNativeConnectionHealth);
  }

  void _onDataReceived(dynamic message) {
    if (message is! Uint8List) {
      AppLogger().debug(
        '[NativeSerialReader] Received non-Uint8List message: ${message.runtimeType}',
        category: 'SERIAL',
      );
      return;
    }

    // C++ 发送的数据格式：[8 字节 timestamp_us][N 字节 data]。
    if (message.length < 8) {
      AppLogger().debug(
        '[NativeSerialReader] Message too short: ${message.length} bytes',
        category: 'SERIAL',
      );
      return;
    }

    final timestampUs = ByteData.sublistView(
      message,
    ).getInt64(0, Endian.little);
    final data = Uint8List.sublistView(message, 8);

    _dataController.add(NativeSerialData(data: data, timestampUs: timestampUs));
  }

  Future<void> dispose() async {
    // 先停止原生线程，再关闭 ReceivePort 和 stream controller。
    _nsrStopReading();
    _receivePort?.close();
    _receivePort = null;
    await _writeQueue.close();
    await Isolate.run(_closeNativePort);
    _isOpen = false;
    _dataController.close();
  }
}

/// Windows 串口设备到达/移除监听器。
///
/// 原生回调只发送变化信号，实际枚举由上层做防抖和并发合并。
class NativeSerialPortMonitor {
  final _changesController = StreamController<void>.broadcast();
  ReceivePort? _receivePort;

  Stream<void> get changes => _changesController.stream;

  bool start() {
    if (_receivePort != null) return true;
    if (_nsrInitDartApi(NativeApi.initializeApiDLData) != 0) return false;

    final receivePort = ReceivePort();
    receivePort.listen((_) => _changesController.add(null));
    if (_nsrStartPortMonitor(receivePort.sendPort.nativePort) != 0) {
      receivePort.close();
      return false;
    }
    _receivePort = receivePort;
    return true;
  }

  void dispose() {
    _nsrStopPortMonitor();
    _receivePort?.close();
    _receivePort = null;
    _changesController.close();
  }
}

bool _openNativePort(String portName, int baudRate) {
  final namePtr = portName.toNativeUtf8();
  try {
    return _nsrOpenPort(namePtr, baudRate) == 0;
  } finally {
    calloc.free(namePtr);
  }
}

void _closeNativePort() => _nsrClosePort();

/// 原生串口数据（带微秒级时间戳）
class NativeSerialData {
  final Uint8List data;
  final int timestampUs;

  NativeSerialData({required this.data, required this.timestampUs});

  String get hex => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
