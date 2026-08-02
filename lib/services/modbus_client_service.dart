import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  const ModbusTaskImportResult(
    this.tasks,
    this.errors, {
    this.sendTasks = const [],
  });
  final List<ModbusPollingTask> tasks;
  final List<ModbusSendTask> sendTasks;
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
    int initialPollingIntervalMs = 1000,
    int initialSendingIntervalMs = 1000,
    List<ModbusPollingTask> initialTasks = const [],
    List<ModbusSendTask> initialSendTasks = const [],
    this.onTasksChanged,
    this.onSendTasksChanged,
    this.onPollingIntervalChanged,
    this.onSendingIntervalChanged,
    Random? random,
  }) : _mode = initialMode,
       _timeoutMs = timeoutMs.clamp(100, 60000),
       _pollingIntervalMs = initialPollingIntervalMs.clamp(50, 3600000),
       _sendingIntervalMs = initialSendingIntervalMs.clamp(50, 3600000),
       _tasks = List.of(initialTasks),
       _sendTasks = List.of(initialSendTasks),
       _random = random ?? Random(),
       _parser = ModbusFrameParser(initialMode);

  final ModbusDataLink _link;
  final void Function(List<ModbusPollingTask> tasks)? onTasksChanged;
  final void Function(List<ModbusSendTask> tasks)? onSendTasksChanged;
  final ValueChanged<int>? onPollingIntervalChanged;
  final ValueChanged<int>? onSendingIntervalChanged;
  final Random _random;
  final List<ModbusFrameRecord> _records = [];
  final Map<String, ModbusResponse> _taskResults = {};
  List<ModbusPollingTask> _tasks;
  List<ModbusSendTask> _sendTasks;
  final Map<String, List<int>> _sendTaskValues = {};
  final Map<String, DateTime> _nextTaskDue = {};
  late ModbusFrameParser _parser;
  StreamSubscription<DataPacket>? _subscription;
  StreamSubscription<void>? _disconnectSubscription;
  _PendingRequest? _pending;
  ModbusMode _mode;
  int _timeoutMs;
  int _pollingIntervalMs;
  int _sendingIntervalMs;
  int _transactionId = 0;
  int _requestEpoch = 0;
  bool _sessionActive = false;
  bool _polling = false;
  bool _sending = false;
  bool _periodicLoopRunning = false;
  Object? _lastError;
  ModbusResponse? _lastResponse;

  ModbusMode get mode => _mode;
  int get timeoutMs => _timeoutMs;
  int get pollingIntervalMs => _pollingIntervalMs;
  int get sendingIntervalMs => _sendingIntervalMs;
  bool get sessionActive => _sessionActive;
  bool get polling => _polling;
  bool get sending => _sending;
  bool get requestPending => _pending != null;
  Object? get lastError => _lastError;
  ModbusResponse? get lastResponse => _lastResponse;
  List<ModbusPollingTask> get tasks => List.unmodifiable(_tasks);
  List<ModbusSendTask> get sendTasks => List.unmodifiable(_sendTasks);
  List<ModbusFrameRecord> get records => List.unmodifiable(_records);
  Map<String, ModbusResponse> get taskResults => Map.unmodifiable(_taskResults);

  void setTimeoutMs(int value) {
    final next = value.clamp(100, 60000);
    if (_timeoutMs == next) return;
    _timeoutMs = next;
    notifyListeners();
  }

  void setPollingIntervalMs(int value) {
    final next = value.clamp(50, 3600000);
    if (_pollingIntervalMs == next) return;
    _pollingIntervalMs = next;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('poll:'));
    onPollingIntervalChanged?.call(next);
    notifyListeners();
  }

  void setSendingIntervalMs(int value) {
    final next = value.clamp(50, 3600000);
    if (_sendingIntervalMs == next) return;
    _sendingIntervalMs = next;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('send:'));
    onSendingIntervalChanged?.call(next);
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

  void replaceSendTasks(List<ModbusSendTask> value) {
    _sendTasks = List.of(value);
    _sendTaskValues.removeWhere(
      (id, _) => !_sendTasks.any((task) => task.id == id),
    );
    _nextTaskDue.clear();
    onSendTasksChanged?.call(List.unmodifiable(_sendTasks));
    notifyListeners();
  }

  void addSendTask(ModbusSendTask task) =>
      replaceSendTasks([..._sendTasks, task]);

  void removeSendTask(String id) =>
      replaceSendTasks(_sendTasks.where((task) => task.id != id).toList());

  void setSendTaskEnabled(String id, bool enabled) => replaceSendTasks([
    for (final task in _sendTasks)
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
    if (!_sessionActive) throw StateError('请先开始Modbus数据处理');
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
    if (!_sessionActive) throw StateError('请先开始Modbus数据处理');
    if (!_tasks.any((task) => task.enabled)) {
      throw StateError('没有启用的轮询任务');
    }
    _polling = true;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('poll:'));
    notifyListeners();
    _ensurePeriodicLoop();
  }

  Future<void> startSending() async {
    if (_sending) return;
    if (!_sessionActive) throw StateError('请先开始Modbus数据处理');
    if (!_sendTasks.any((task) => task.enabled)) {
      throw StateError('没有启用的周期发送任务');
    }
    _sending = true;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('send:'));
    notifyListeners();
    _ensurePeriodicLoop();
  }

  Future<void> stopPolling() async {
    _polling = false;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('poll:'));
    notifyListeners();
  }

  Future<void> stopSending() async {
    _sending = false;
    _nextTaskDue.removeWhere((key, _) => key.startsWith('send:'));
    notifyListeners();
  }

  void _ensurePeriodicLoop() {
    if (_periodicLoopRunning) return;
    _periodicLoopRunning = true;
    unawaited(_periodicLoop());
  }

  Future<void> _periodicLoop() async {
    try {
      while (_sessionActive && _link.isConnected && (_polling || _sending)) {
        final actions =
            <
              ({
                String key,
                int intervalMs,
                int priority,
                Future<void> Function() run,
              })
            >[];
        if (_polling) {
          for (final task in _tasks.where((task) => task.enabled)) {
            actions.add((
              key: 'poll:${task.id}',
              intervalMs: _pollingIntervalMs,
              priority: 0,
              run: () => _runPollingTask(task),
            ));
          }
        }
        if (_sending) {
          for (final task in _sendTasks.where((task) => task.enabled)) {
            actions.add((
              key: 'send:${task.id}',
              intervalMs: _sendingIntervalMs,
              priority: 1,
              run: () => _runSendTask(task),
            ));
          }
        }
        if (actions.isEmpty) {
          _polling = false;
          _sending = false;
          notifyListeners();
          break;
        }

        final now = DateTime.now();
        for (final action in actions) {
          _nextTaskDue.putIfAbsent(action.key, () => now);
        }
        actions.sort((left, right) {
          final dueOrder = _nextTaskDue[left.key]!.compareTo(
            _nextTaskDue[right.key]!,
          );
          return dueOrder != 0
              ? dueOrder
              : left.priority.compareTo(right.priority);
        });
        final action = actions.first;
        final wait = _nextTaskDue[action.key]!.difference(now);
        if (wait > Duration.zero) {
          await Future<void>.delayed(
            wait > const Duration(milliseconds: 50)
                ? const Duration(milliseconds: 50)
                : wait,
          );
          continue;
        }
        try {
          await action.run();
        } catch (error) {
          _lastError = error;
        }
        _nextTaskDue[action.key] = DateTime.now().add(
          Duration(milliseconds: action.intervalMs),
        );
        notifyListeners();
      }
    } finally {
      _periodicLoopRunning = false;
      if (_sessionActive && (_polling || _sending)) _ensurePeriodicLoop();
    }
  }

  Future<void> _runPollingTask(ModbusPollingTask task) async {
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
  }

  Future<void> _runSendTask(ModbusSendTask task) async {
    final values = _nextSendValues(task);
    await execute(
      ModbusRequest(
        mode: _mode,
        unitId: task.unitId,
        function: task.function,
        address: task.address,
        quantity: task.quantity,
        registerValues: task.function.isBitFunction ? const [] : values,
        coilValues:
            task.function.isBitFunction
                ? values.map((value) => value != 0).toList()
                : const [],
      ),
    );
  }

  List<int> _nextSendValues(ModbusSendTask task) {
    final count =
        task.function == ModbusFunction.writeSingleCoil ||
                task.function == ModbusFunction.writeSingleRegister
            ? 1
            : task.quantity;
    if (task.valueMode == ModbusSendValueMode.random) {
      return List<int>.generate(
        count,
        (_) =>
            task.function.isBitFunction
                ? _random.nextInt(2)
                : _random.nextInt(0x10000),
      );
    }
    final modulus = task.function.isBitFunction ? 2 : 0x10000;
    final current = _sendTaskValues.putIfAbsent(
      task.id,
      () => List<int>.generate(
        count,
        (index) => (task.initialValues.elementAtOrNull(index) ?? 0) % modulus,
      ),
    );
    final result = List<int>.from(current);
    final direction = task.valueMode == ModbusSendValueMode.increment ? 1 : -1;
    for (var index = 0; index < current.length; index++) {
      current[index] = (current[index] + direction * task.step) % modulus;
    }
    return result;
  }

  Future<void> stop() async {
    await stopPolling();
    await stopSending();
    _requestEpoch++;
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(StateError('Modbus活动已停止'));
    }
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
    'schemaVersion': 2,
    'pollingTasks': [for (final task in _tasks) task.toJson()],
    'sendTasks': [for (final task in _sendTasks) task.toJson()],
  });

  ModbusTaskImportResult importTasks(String source) {
    final errors = <String>[];
    final tasks = <ModbusPollingTask>[];
    final sendTasks = <ModbusSendTask>[];
    try {
      final root = jsonDecode(source);
      if (root is! Map ||
          (root['schemaVersion'] != 1 && root['schemaVersion'] != 2)) {
        return const ModbusTaskImportResult([], ['不是受支持的Modbus任务文件']);
      }
      final values =
          (root['schemaVersion'] == 1 ? root['tasks'] : root['pollingTasks']);
      if (values is! List) {
        return const ModbusTaskImportResult([], ['轮询任务列表无效']);
      }
      for (var index = 0; index < values.length; index++) {
        final task = ModbusPollingTask.fromJson(values[index]);
        if (task == null) {
          errors.add('第${index + 1}项轮询任务无效');
        } else {
          tasks.add(task);
        }
      }
      if (root['schemaVersion'] == 2) {
        final sendValues = root['sendTasks'];
        if (sendValues is! List) {
          errors.add('周期发送任务列表无效');
        } else {
          for (var index = 0; index < sendValues.length; index++) {
            final task = ModbusSendTask.fromJson(sendValues[index]);
            if (task == null) {
              errors.add('第${index + 1}项周期发送任务无效');
            } else {
              sendTasks.add(task);
            }
          }
        }
      }
    } catch (error) {
      errors.add('JSON解析失败：$error');
    }
    if (tasks.isNotEmpty) replaceTasks(tasks);
    if (sendTasks.isNotEmpty) replaceSendTasks(sendTasks);
    return ModbusTaskImportResult(tasks, errors, sendTasks: sendTasks);
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
