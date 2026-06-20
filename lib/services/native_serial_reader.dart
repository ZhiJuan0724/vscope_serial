import 'dart:async';
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

/// Windows 原生串口读取器
class NativeSerialReader {
  final _dataController = StreamController<NativeSerialData>.broadcast();
  Stream<NativeSerialData> get dataStream => _dataController.stream;

  ReceivePort? _receivePort;
  bool _isOpen = false;
  bool _dartApiInitialized = false;

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
  void close() {
    stopReading();
    _nsrClosePort();
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
  int write(Uint8List data) {
    final ptr = calloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _nsrWrite(ptr, data.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 是否打开
  bool get isOpen => _nsrIsOpen() == 1;

  /// 外部断开后，已打开句柄是否仍有响应。
  bool get isConnectionHealthy => _nsrIsConnectionHealthy() == 1;

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

  void dispose() {
    // 先停止原生线程，再关闭 ReceivePort 和 stream controller。
    _nsrStopReading();
    _receivePort?.close();
    _receivePort = null;
    _nsrClosePort();
    _isOpen = false;
    _dataController.close();
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

/// 原生串口数据（带微秒级时间戳）
class NativeSerialData {
  final Uint8List data;
  final int timestampUs;

  NativeSerialData({required this.data, required this.timestampUs});

  String get hex => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
