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

typedef NsrGetReadMetricsC =
    Void Function(
      Pointer<Uint64> bytesRead,
      Pointer<Uint64> maxBlockBytes,
      Pointer<Uint64> callbackCount,
      Pointer<Uint64> postFailureCount,
    );
typedef NsrGetReadMetricsDart =
    void Function(
      Pointer<Uint64> bytesRead,
      Pointer<Uint64> maxBlockBytes,
      Pointer<Uint64> callbackCount,
      Pointer<Uint64> postFailureCount,
    );

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
final _nsrGetReadMetrics = _dll
    .lookupFunction<NsrGetReadMetricsC, NsrGetReadMetricsDart>(
      'nsr_get_read_metrics',
    );
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

/// 单连接使用的有序原生写队列。
///
/// 队列一旦超时或 isolate 异常退出便永久失效；重连必须创建新实例，
/// 防止旧连接中失去响应的请求污染新连接。
class NativeSerialWriteQueue {
  static const Duration defaultStartupTimeout = Duration(seconds: 2);
  static const Duration defaultRequestTimeout = Duration(seconds: 3);
  static const Duration defaultShutdownTimeout = Duration(seconds: 2);

  final ReceivePort _responses = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Map<int, Completer<int?>> _pending = <int, Completer<int?>>{};
  final Map<int, Timer> _requestTimers = <int, Timer>{};
  final void Function(SendPort) _entryPoint;
  final Duration startupTimeout;
  final Duration requestTimeout;
  final Duration shutdownTimeout;
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  Completer<void>? _ready;
  Completer<void>? _exited;
  int _nextRequestId = 1;
  bool _closing = false;
  bool _closed = false;
  Object? _failure;

  NativeSerialWriteQueue({
    void Function(SendPort) entryPoint = _nativeWriteIsolateMain,
    this.startupTimeout = defaultStartupTimeout,
    this.requestTimeout = defaultRequestTimeout,
    this.shutdownTimeout = defaultShutdownTimeout,
  }) : _entryPoint = entryPoint {
    _responses.listen((message) {
      if (message is SendPort) {
        _commands = message;
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
        return;
      }
      if (message is! List || message.length < 3) return;
      final requestId = message[0] as int;
      final completer = _pending.remove(requestId);
      _requestTimers.remove(requestId)?.cancel();
      if (completer == null) return;
      final error = message[2];
      if (error != null) {
        completer.completeError(StateError(error as String));
      } else {
        completer.complete(message[1] as int?);
      }
    });
    _errors.listen((message) {
      final description =
          message is List && message.isNotEmpty
              ? message.join('\n')
              : message.toString();
      _fail(StateError('串口写入 isolate 异常: $description'));
    });
    _exits.listen((_) {
      final exited = _exited;
      if (exited != null && !exited.isCompleted) exited.complete();
      if (!_closing) {
        _fail(StateError('串口写入 isolate 意外退出'));
      }
    });
  }

  Future<void> _ensureStarted({bool allowClosing = false}) {
    final failure = _failure;
    if (failure != null) return Future<void>.error(failure);
    if (_closed || (_closing && !allowClosing)) {
      return Future<void>.error(StateError('串口写入队列已关闭'));
    }
    final existing = _starting;
    if (existing != null) return existing;
    _ready = Completer<void>();
    _exited = Completer<void>();
    final start = () async {
      try {
        _isolate = await Isolate.spawn(
          _entryPoint,
          _responses.sendPort,
          onError: _errors.sendPort,
          onExit: _exits.sendPort,
          errorsAreFatal: true,
        );
        await _ready!.future.timeout(startupTimeout);
      } catch (error, stackTrace) {
        final failure =
            error is TimeoutException
                ? TimeoutException('串口写入队列启动超时', startupTimeout)
                : error;
        _fail(failure, stackTrace);
        Error.throwWithStackTrace(failure, stackTrace);
      }
    }();
    _starting = start;
    return start;
  }

  Future<int> write(Uint8List data) async {
    if (_closing) throw StateError('串口写入队列正在关闭');
    if (data.isEmpty) return 0;
    await _ensureStarted();
    final requestId = _nextRequestId++;
    final completer = Completer<int?>();
    _pending[requestId] = completer;
    _requestTimers[requestId] = Timer(requestTimeout, () {
      final timedOut = _pending.remove(requestId);
      _requestTimers.remove(requestId);
      if (timedOut == null) return;
      final error = TimeoutException('串口写入请求超时', requestTimeout);
      timedOut.completeError(error);
      _fail(error);
    });
    _commands!.send(<Object>[
      _responses.sendPort,
      requestId,
      TransferableTypedData.fromList(<Uint8List>[data]),
    ]);
    return (await completer.future)!;
  }

  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    if (_starting == null) {
      _disposePorts();
      return;
    }
    try {
      await _ensureStarted(allowClosing: true);
      if (_failure == null && _commands != null) {
        final requestId = _nextRequestId++;
        final completer = Completer<int?>();
        _pending[requestId] = completer;
        _commands!.send(<Object>[_responses.sendPort, requestId]);
        await Future.any<void>([
          completer.future.then<void>((_) {}),
          _exited!.future,
        ]).timeout(shutdownTimeout);
      }
    } on TimeoutException {
      AppLogger().warning('串口写入队列关闭超时，已强制终止', category: 'SERIAL');
    } catch (error) {
      AppLogger().warning('串口写入队列关闭异常: $error', category: 'SERIAL');
    } finally {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _completePendingWithError(StateError('串口写入队列已关闭'));
      _disposePorts();
    }
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_failure != null || _closed) return;
    _failure = error;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    _completePendingWithError(error, stackTrace);
  }

  void _completePendingWithError(Object error, [StackTrace? stackTrace]) {
    for (final timer in _requestTimers.values) {
      timer.cancel();
    }
    _requestTimers.clear();
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }

  void _disposePorts() {
    if (_closed) return;
    _closed = true;
    _responses.close();
    _errors.close();
    _exits.close();
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
  NativeSerialWriteQueue? _writeQueue;

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
      if (_isOpen) _writeQueue = NativeSerialWriteQueue();
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
    if (_isOpen) _writeQueue = NativeSerialWriteQueue();
    return _isOpen;
  }

  /// 关闭串口
  Future<void> close() async {
    stopReading();
    final writeQueue = _writeQueue;
    _writeQueue = null;
    await writeQueue?.close();
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
    final metrics = _readNativeMetrics();
    if (metrics.callbackCount > 0 || metrics.postFailureCount > 0) {
      AppLogger().info(
        '串口读取汇总: ${metrics.bytesRead} bytes, '
        '${metrics.callbackCount} 次回调, 最大块 ${metrics.maxBlockBytes} bytes, '
        '投递失败 ${metrics.postFailureCount} 次',
        category: 'SERIAL',
      );
    }
  }

  /// 发送数据
  Future<int> write(Uint8List data) {
    final writeQueue = _writeQueue;
    if (writeQueue == null) {
      return Future<int>.error(StateError('串口写入队列未启动'));
    }
    return writeQueue.write(data);
  }

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

    final nativeData = NativeSerialData.tryParse(message);
    if (nativeData == null) {
      AppLogger().debug(
        '[NativeSerialReader] Message too short: ${message.length} bytes',
        category: 'SERIAL',
      );
      return;
    }
    _dataController.add(nativeData);
  }

  Future<void> dispose() async {
    // 先停止原生线程，再关闭 ReceivePort 和 stream controller。
    _nsrStopReading();
    _receivePort?.close();
    _receivePort = null;
    final writeQueue = _writeQueue;
    _writeQueue = null;
    await writeQueue?.close();
    await Isolate.run(_closeNativePort);
    _isOpen = false;
    await _dataController.close();
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

NativeSerialReadMetrics _readNativeMetrics() {
  final values = calloc<Uint64>(4);
  try {
    _nsrGetReadMetrics(values, values + 1, values + 2, values + 3);
    return NativeSerialReadMetrics(
      bytesRead: values[0],
      maxBlockBytes: values[1],
      callbackCount: values[2],
      postFailureCount: values[3],
    );
  } finally {
    calloc.free(values);
  }
}

class NativeSerialReadMetrics {
  final int bytesRead;
  final int maxBlockBytes;
  final int callbackCount;
  final int postFailureCount;

  const NativeSerialReadMetrics({
    required this.bytesRead,
    required this.maxBlockBytes,
    required this.callbackCount,
    required this.postFailureCount,
  });
}

/// 原生串口数据：单调时间用于间隔计算，墙钟时间用于界面显示。
class NativeSerialData {
  static const int headerBytes = 16;

  final Uint8List data;
  final int monotonicUs;
  final int wallClockUs;

  NativeSerialData({
    required this.data,
    required this.monotonicUs,
    required this.wallClockUs,
  });

  /// 解析原生 DLL 投递的双时间戳包头。
  static NativeSerialData? tryParse(Uint8List message) {
    if (message.length < headerBytes) return null;
    final header = ByteData.sublistView(message, 0, headerBytes);
    return NativeSerialData(
      monotonicUs: header.getInt64(0, Endian.little),
      wallClockUs: header.getInt64(8, Endian.little),
      data: Uint8List.sublistView(message, headerBytes),
    );
  }

  String get hex => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
