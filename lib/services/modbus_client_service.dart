import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/models/data_packet.dart';
import '../data/models/modbus_models.dart';
import 'data_connection_service.dart';
import 'modbus_codec.dart';

/// Modbus协议层依赖的最小数据链路，测试时可替换为内存假实现。
abstract interface class ModbusDataLink {
  bool get isConnected;
  Stream<DataPacket> get dataStream;
  Stream<void> get disconnectStream;
  bool acquire();
  void release();
  Future<void> send(Uint8List data);
}

class DataConnectionModbusLink implements ModbusDataLink {
  DataConnectionModbusLink(this._service);

  final DataConnectionService _service;

  @override
  bool get isConnected => _service.isConnected;

  @override
  Stream<DataPacket> get dataStream => _service.modbusDataStream;

  @override
  Stream<void> get disconnectStream => _service.disconnectStream;

  @override
  bool acquire() => _service.tryAcquireActivity(DataActivityOwner.modbus);

  @override
  void release() => _service.releaseActivity(DataActivityOwner.modbus);

  @override
  Future<void> send(Uint8List data) => _service.sendRawBytes(data);
}

class ModbusTaskImportResult {
  const ModbusTaskImportResult(this.tasks, this.errors);
  final List<ModbusPollingTask> tasks;
  final List<String> errors;
}

class _PendingRequest {
  _PendingRequest(this.request)
    : completer = Completer<ModbusResponse>(),
      stopwatch = Stopwatch()..start();

  final ModbusRequest request;
  final Completer<ModbusResponse> completer;
  final Stopwatch stopwatch;
}

/// Modbus主站请求队列与轮询调度器。
///
/// 同一连接只保留一个在途请求。停止、断开或切换协议都会取消等待并清空分包器，
/// 防止上一轮迟到的数据被解释为下一轮响应。
class ModbusClientService extends ChangeNotifier {
  ModbusClientService(
    this._link, {
    ModbusMode initialMode = ModbusMode.rtu,
    int timeoutMs = 1000,
    List<ModbusPollingTask> initialTasks = const [],
    this.onTasksChanged,
  }) : _mode = initialMode,
       _timeoutMs = timeoutMs.clamp(100, 60000),
       _tasks = List.of(initialTasks),
       _parser = ModbusFrameParser(initialMode);

  final ModbusDataLink _link;
  final void Function(List<ModbusPollingTask> tasks)? onTasksChanged;
  final List<ModbusFrameRecord> _records = [];
  final Map<String, ModbusResponse> _taskResults = {};
  List<ModbusPollingTask> _tasks;
  late ModbusFrameParser _parser;
  StreamSubscription<DataPacket>? _subscription;
  StreamSubscription<void>? _disconnectSubscription;
  _PendingRequest? _pending;
  ModbusMode _mode;
  int _timeoutMs;
  int _transactionId = 0;
  int _pollGeneration = 0;
  int _requestEpoch = 0;
  bool _sessionActive = false;
  bool _polling = false;
  Object? _lastError;
  ModbusResponse? _lastResponse;

  ModbusMode get mode => _mode;
  int get timeoutMs => _timeoutMs;
  bool get sessionActive => _sessionActive;
  bool get polling => _polling;
  bool get requestPending => _pending != null;
  Object? get lastError => _lastError;
  ModbusResponse? get lastResponse => _lastResponse;
  List<ModbusPollingTask> get tasks => List.unmodifiable(_tasks);
  List<ModbusFrameRecord> get records => List.unmodifiable(_records);
  Map<String, ModbusResponse> get taskResults => Map.unmodifiable(_taskResults);

  void setTimeoutMs(int value) {
    final next = value.clamp(100, 60000);
    if (_timeoutMs == next) return;
    _timeoutMs = next;
    notifyListeners();
  }

  Future<void> setMode(ModbusMode value) async {
    if (_mode == value) return;
    await stop();
    _mode = value;
    _parser = ModbusFrameParser(value);
    notifyListeners();
  }

  void replaceTasks(List<ModbusPollingTask> value) {
    _tasks = List.of(value);
    onTasksChanged?.call(List.unmodifiable(_tasks));
    notifyListeners();
  }

  void addTask(ModbusPollingTask task) => replaceTasks([..._tasks, task]);

  void removeTask(String id) =>
      replaceTasks(_tasks.where((task) => task.id != id).toList());

  void setTaskEnabled(String id, bool enabled) => replaceTasks([
    for (final task in _tasks)
      if (task.id == id) task.copyWith(enabled: enabled) else task,
  ]);

  Future<void> startSession() async {
    if (_sessionActive) return;
    if (!_link.isConnected) throw StateError('数据连接未建立');
    if (!_link.acquire()) throw StateError('当前数据连接正被其他页面使用');
    _parser.reset();
    _subscription = _link.dataStream.listen(
      (packet) => _handleData(packet.data),
      onError: _handleStreamError,
      onDone: () => _handleStreamError(StateError('数据连接已断开')),
    );
    _disconnectSubscription = _link.disconnectStream.listen(
      (_) => _handleStreamError(StateError('数据连接已断开')),
    );
    _sessionActive = true;
    _lastError = null;
    notifyListeners();
  }

  Future<ModbusResponse> execute(
    ModbusRequest request, {
    int readRetries = 0,
  }) async {
    await startSession();
    if (_pending != null) throw StateError('已有Modbus请求正在等待响应');
    final retries = request.function.isRead ? readRetries.clamp(0, 3) : 0;
    final requestEpoch = _requestEpoch;
    Object? lastFailure;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await _executeOnce(request);
      } catch (error) {
        lastFailure = error;
        if (!_sessionActive ||
            !_link.isConnected ||
            requestEpoch != _requestEpoch) {
          rethrow;
        }
      }
    }
    throw lastFailure ?? StateError('Modbus请求失败');
  }

  Future<ModbusResponse> _executeOnce(ModbusRequest request) async {
    final effective = request.copyWith(
      mode: _mode,
      transactionId:
          _mode == ModbusMode.tcp
              ? _nextTransactionId()
              : request.transactionId,
    );
    final frame = ModbusCodec.encodeRequest(effective);
    final pending = _PendingRequest(effective);
    _pending = pending;
    _record(frame, outbound: true, status: '已发送');
    notifyListeners();
    try {
      await _link.send(frame);
      final response = await pending.completer.future.timeout(
        Duration(milliseconds: _timeoutMs),
        onTimeout:
            () =>
                throw TimeoutException(
                  'Modbus响应超时',
                  Duration(milliseconds: _timeoutMs),
                ),
      );
      _lastResponse = response;
      _lastError = null;
      return response;
    } catch (error) {
      _lastError = error;
      _record(frame, outbound: true, status: '失败：$error');
      rethrow;
    } finally {
      if (identical(_pending, pending)) _pending = null;
      _parser.reset();
      notifyListeners();
    }
  }

  int _nextTransactionId() {
    _transactionId = (_transactionId + 1) & 0xFFFF;
    return _transactionId;
  }

  void _handleData(Uint8List data) {
    for (final frame in _parser.add(data)) {
      final pending = _pending;
      if (pending == null) {
        _record(frame, outbound: false, status: '无等待请求');
        continue;
      }
      try {
        final response = ModbusCodec.decodeResponse(pending.request, frame);
        pending.stopwatch.stop();
        _record(
          frame,
          outbound: false,
          status:
              response.isException
                  ? '异常响应 0x${response.exceptionCode!.toRadixString(16).padLeft(2, '0')}'
                  : '成功',
          elapsed: pending.stopwatch.elapsed,
        );
        if (!pending.completer.isCompleted) {
          pending.completer.complete(response);
        }
      } catch (error, stackTrace) {
        _record(frame, outbound: false, status: '解析失败：$error');
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(error, stackTrace);
        }
      }
    }
    notifyListeners();
  }

  void _handleStreamError(Object error) {
    _lastError = error;
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error);
    }
    unawaited(stop());
  }

  void _record(
    Uint8List frame, {
    required bool outbound,
    required String status,
    Duration? elapsed,
  }) {
    _records.add(
      ModbusFrameRecord(
        timestamp: DateTime.now(),
        outbound: outbound,
        frame: Uint8List.fromList(frame),
        status: status,
        elapsed: elapsed,
      ),
    );
    if (_records.length > 1000) _records.removeRange(0, _records.length - 1000);
  }

  void clearRecords() {
    _records.clear();
    notifyListeners();
  }

  Future<void> startPolling() async {
    if (_polling) return;
    await startSession();
    if (!_tasks.any((task) => task.enabled)) {
      throw StateError('没有启用的轮询任务');
    }
    _polling = true;
    final generation = ++_pollGeneration;
    notifyListeners();
    unawaited(_pollLoop(generation));
  }

  Future<void> _pollLoop(int generation) async {
    while (_polling && generation == _pollGeneration && _link.isConnected) {
      final enabledTasks = _tasks.where((task) => task.enabled).toList();
      if (enabledTasks.isEmpty) break;
      for (final task in enabledTasks) {
        if (!_polling || generation != _pollGeneration) break;
        try {
          final response = await execute(
            ModbusRequest(
              mode: _mode,
              unitId: task.unitId,
              function: task.function,
              address: task.address,
              quantity: task.quantity,
            ),
            readRetries: task.readRetries,
          );
          _taskResults[task.id] = response;
        } catch (error) {
          _lastError = error;
        }
        if (!_polling || generation != _pollGeneration) break;
        await Future<void>.delayed(Duration(milliseconds: task.intervalMs));
      }
    }
    if (generation == _pollGeneration) {
      _polling = false;
      notifyListeners();
    }
  }

  Future<void> stopPolling() async {
    _polling = false;
    _pollGeneration++;
    _requestEpoch++;
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(StateError('Modbus活动已停止'));
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await stopPolling();
    _pending = null;
    _parser.reset();
    await _subscription?.cancel();
    _subscription = null;
    await _disconnectSubscription?.cancel();
    _disconnectSubscription = null;
    if (_sessionActive) _link.release();
    _sessionActive = false;
    notifyListeners();
  }

  String exportTasks() => const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'tasks': [for (final task in _tasks) task.toJson()],
  });

  ModbusTaskImportResult importTasks(String source) {
    final errors = <String>[];
    final tasks = <ModbusPollingTask>[];
    try {
      final root = jsonDecode(source);
      if (root is! Map ||
          root['schemaVersion'] != 1 ||
          root['tasks'] is! List) {
        return const ModbusTaskImportResult([], ['不是受支持的Modbus任务文件']);
      }
      final values = root['tasks'] as List;
      for (var index = 0; index < values.length; index++) {
        final task = ModbusPollingTask.fromJson(values[index]);
        if (task == null) {
          errors.add('第${index + 1}项无效');
        } else {
          tasks.add(task);
        }
      }
    } catch (error) {
      errors.add('JSON解析失败：$error');
    }
    if (tasks.isNotEmpty) replaceTasks(tasks);
    return ModbusTaskImportResult(tasks, errors);
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
