import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/utils/app_logger.dart';
import '../data/models/data_packet.dart';
import '../data/models/modbus_models.dart';
import 'data_connection_service.dart';
import 'modbus_codec.dart';
import 'modbus_profile_service.dart';
import 'modbus_value_codec.dart';

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

class ModbusRowState {
  const ModbusRowState({
    this.value,
    this.rawRegisters = const [],
    this.error,
    this.updatedAt,
    this.busy = false,
    this.lastWriteValue,
  });

  final Object? value;
  final List<int> rawRegisters;
  final Object? error;
  final DateTime? updatedAt;
  final bool busy;
  final String? lastWriteValue;

  ModbusRowState copyWith({
    Object? value,
    List<int>? rawRegisters,
    Object? error,
    DateTime? updatedAt,
    bool? busy,
    String? lastWriteValue,
    bool clearError = false,
  }) => ModbusRowState(
    value: value ?? this.value,
    rawRegisters: rawRegisters ?? this.rawRegisters,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
    busy: busy ?? this.busy,
    lastWriteValue: lastWriteValue ?? this.lastWriteValue,
  );
}

class ModbusConfigurationImportResult {
  const ModbusConfigurationImportResult({
    required this.pages,
    required this.errors,
    this.skippedPageKeys = const [],
  });

  final List<ModbusRegisterPage> pages;
  final List<String> errors;
  final List<String> skippedPageKeys;
}

class _RequestJob {
  _RequestJob({
    required this.manual,
    required this.due,
    required this.sequence,
    required this.isRead,
    required this.run,
    this.periodicKey,
    this.rowKey,
    this.completer,
  });

  final bool manual;
  final DateTime due;
  final int sequence;
  final bool isRead;
  final Future<ModbusResponse> Function() run;
  final String? periodicKey;
  final String? rowKey;
  final Completer<ModbusResponse>? completer;
}

/// Modbus主站请求队列与页面级轮询调度器。
///
/// 连接、协议解析和请求队列只存在于主窗口的这个实例中。独立页面窗口
/// 通过窗口桥接发送命令，不会创建第二个数据连接或调度器。
class ModbusClientService extends ChangeNotifier {
  ModbusClientService(
    this._link, {
    ModbusMode initialMode = ModbusMode.rtu,
    int timeoutMs = 1000,
    ModbusRegisterLayoutMode initialLayoutMode =
        ModbusRegisterLayoutMode.columnMajor,
    ModbusByteOrder initialByteOrder = ModbusByteOrder.highByteFirst,
    ModbusWordOrder initialWordOrder = ModbusWordOrder.highWordFirst,
    int initialLogMaxLines = modbusDefaultLogMaxLines,
    List<ModbusRegisterPage> initialPages = const [],
    this.onPagesChanged,
    this.onLayoutModeChanged,
    this.onModeChanged,
    this.onTimeoutChanged,
    this.onByteOrderChanged,
    this.onWordOrderChanged,
    this.onLogMaxLinesChanged,
    this.onSelectedProfileChanged,
    ModbusProfileService? profileService,
    Random? random,
  }) : _mode = initialMode,
       _timeoutMs = timeoutMs.clamp(100, 60000),
       _layoutMode = initialLayoutMode,
       _byteOrder = initialByteOrder,
       _wordOrder = initialWordOrder,
       _logMaxLines = initialLogMaxLines.clamp(
         modbusMinLogMaxLines,
         modbusMaxLogMaxLines,
       ),
       _pages = List.of(initialPages),
       _profileService = profileService ?? ModbusProfileService(),
       _random = random ?? Random(),
       _parser = ModbusFrameParser(initialMode);

  final ModbusDataLink _link;
  final ValueChanged<List<ModbusRegisterPage>>? onPagesChanged;
  final ValueChanged<ModbusRegisterLayoutMode>? onLayoutModeChanged;
  final ValueChanged<ModbusMode>? onModeChanged;
  final ValueChanged<int>? onTimeoutChanged;
  final ValueChanged<ModbusByteOrder>? onByteOrderChanged;
  final ValueChanged<ModbusWordOrder>? onWordOrderChanged;
  final ValueChanged<int>? onLogMaxLinesChanged;
  final ValueChanged<String>? onSelectedProfileChanged;
  final ModbusProfileService _profileService;
  final Random _random;
  final List<ModbusFrameRecord> _records = [];
  final Map<String, ModbusRowState> _rowStates = {};
  final Map<String, String> _sendStates = {};
  final Map<String, DateTime> _nextDue = {};
  final Set<String> _queuedPeriodic = {};
  final List<_RequestJob> _queue = [];
  late ModbusFrameParser _parser;
  StreamSubscription<DataPacket>? _subscription;
  StreamSubscription<void>? _disconnectSubscription;
  _PendingRequest? _pending;
  ModbusMode _mode;
  int _timeoutMs;
  ModbusRegisterLayoutMode _layoutMode;
  ModbusByteOrder _byteOrder;
  ModbusWordOrder _wordOrder;
  int _logMaxLines;
  List<ModbusRegisterPage> _pages;
  int _sequence = 0;
  int _transactionId = 0;
  int _requestEpoch = 0;
  bool _sessionActive = false;
  bool _workerRunning = false;
  Object? _lastError;
  ModbusResponse? _lastResponse;
  ModbusProfile? _selectedProfile;
  bool _profilesInitialized = false;
  bool _applyingProfile = false;
  Future<void> _profileSaveQueue = Future<void>.value();

  ModbusMode get mode => _mode;
  int get timeoutMs => _timeoutMs;
  ModbusRegisterLayoutMode get layoutMode => _layoutMode;
  ModbusByteOrder get byteOrder => _byteOrder;
  ModbusWordOrder get wordOrder => _wordOrder;
  int get logMaxLines => _logMaxLines;
  bool get sessionActive => _sessionActive;
  bool get requestPending =>
      _pending != null || _queue.any((job) => job.manual);
  Object? get lastError => _lastError;
  ModbusResponse? get lastResponse => _lastResponse;
  List<ModbusRegisterPage> get pages => List.unmodifiable(_pages);
  List<ModbusFrameRecord> get records => List.unmodifiable(_records);
  List<ModbusProfile> get profiles => _profileService.profiles;
  ModbusProfile? get selectedProfile => _selectedProfile;
  bool get profilesInitialized => _profilesInitialized;
  String? get profileDirectoryPath => _profileService.directoryPath;

  Future<void> initializeProfiles({String? selectedProfileId}) async {
    if (_profilesInitialized) return;
    await _profileService.init();
    var profile = _profileService.findById(selectedProfileId);
    final hasLegacyConfiguration =
        _pages.isNotEmpty ||
        _mode != ModbusMode.rtu ||
        _timeoutMs != 1000 ||
        _layoutMode != ModbusRegisterLayoutMode.columnMajor ||
        _byteOrder != ModbusByteOrder.highByteFirst ||
        _wordOrder != ModbusWordOrder.highWordFirst ||
        _logMaxLines != modbusDefaultLogMaxLines;
    if (profile == null && hasLegacyConfiguration) {
      final defaultProfile = await _profileService.ensureDefaultProfile();
      profile = defaultProfile.copyWith(source: exportConfiguration());
      await _profileService.save(profile);
    }
    profile ??= await _profileService.ensureDefaultProfile();
    _profilesInitialized = true;
    await _applyProfile(profile);
  }

  Future<void> selectProfile(String id) async {
    if (_sessionActive || !_profilesInitialized) return;
    final profile = _profileService.findById(id);
    if (profile == null || profile.id == _selectedProfile?.id) return;
    await _profileSaveQueue;
    await _applyProfile(profile);
  }

  Future<void> createProfile(String name) async {
    if (_sessionActive || !_profilesInitialized) return;
    final profile = await _profileService.create(name);
    await _applyProfile(profile);
  }

  Future<void> renameSelectedProfile(String name) async {
    final selected = _selectedProfile;
    if (selected != null) await renameProfile(selected.id, name);
  }

  Future<void> deleteSelectedProfile() async {
    final selected = _selectedProfile;
    if (selected != null) await deleteProfile(selected.id);
  }

  Future<void> renameProfile(String id, String name) async {
    if (_sessionActive) return;
    final profile = _profileService.findById(id);
    if (profile == null) return;
    if (id == _selectedProfile?.id) await _profileSaveQueue;
    final renamed = await _profileService.rename(profile, name);
    if (id == _selectedProfile?.id) _selectedProfile = renamed;
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    if (_sessionActive) return;
    final deletingSelected = id == _selectedProfile?.id;
    if (deletingSelected) await _profileSaveQueue;
    await _profileService.delete(id);
    if (deletingSelected) {
      final next = await _profileService.ensureDefaultProfile();
      await _applyProfile(next);
    } else {
      notifyListeners();
    }
  }

  Future<void> importProfile(String path) async {
    if (_sessionActive || !_profilesInitialized) return;
    final profile = await _profileService.importJson(path);
    await _applyProfile(profile);
  }

  Future<void> exportSelectedProfile(String path) async {
    final selected = _selectedProfile;
    if (selected != null) await exportProfile(selected.id, path);
  }

  Future<void> exportProfile(String id, String path) async {
    if (id == _selectedProfile?.id) await _profileSaveQueue;
    final profile = _profileService.findById(id);
    if (profile != null) await _profileService.exportJson(profile, path);
  }

  Future<void> _applyProfile(ModbusProfile profile) async {
    _applyingProfile = true;
    try {
      await stop();
      _mode = ModbusMode.rtu;
      _parser = ModbusFrameParser(_mode);
      _timeoutMs = 1000;
      _layoutMode = ModbusRegisterLayoutMode.columnMajor;
      _byteOrder = ModbusByteOrder.highByteFirst;
      _wordOrder = ModbusWordOrder.highWordFirst;
      _logMaxLines = modbusDefaultLogMaxLines;
      replacePages(const []);
      final result = await importConfiguration(profile.source);
      if (result.errors.isNotEmpty) {
        throw FormatException(result.errors.join('；'));
      }
      onModeChanged?.call(_mode);
      onTimeoutChanged?.call(_timeoutMs);
      onLayoutModeChanged?.call(_layoutMode);
      onByteOrderChanged?.call(_byteOrder);
      onWordOrderChanged?.call(_wordOrder);
      onLogMaxLinesChanged?.call(_logMaxLines);
      _selectedProfile = _profileService.findById(profile.id) ?? profile;
      onSelectedProfileChanged?.call(profile.id);
    } finally {
      _applyingProfile = false;
    }
    notifyListeners();
  }

  void _queueProfileSave() {
    final selected = _selectedProfile;
    if (!_profilesInitialized || _applyingProfile || selected == null) return;
    final updated = selected.copyWith(source: exportConfiguration());
    _selectedProfile = updated;
    _profileSaveQueue = _profileSaveQueue
        .then((_) => _profileService.save(updated))
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger().error(
            '保存Modbus配置失败: $error',
            category: 'MODBUS',
            error: error,
            stackTrace: stackTrace,
          );
        });
  }

  ModbusRowState rowState(String pageKey, String rowId) =>
      _rowStates[_rowKey(pageKey, rowId)] ?? const ModbusRowState();

  void setTimeoutMs(int value) {
    final next = value.clamp(100, 60000).toInt();
    if (_timeoutMs == next) return;
    _timeoutMs = next;
    onTimeoutChanged?.call(next);
    _queueProfileSave();
    notifyListeners();
  }

  void setLayoutMode(ModbusRegisterLayoutMode value) {
    if (_layoutMode == value) return;
    _layoutMode = value;
    onLayoutModeChanged?.call(value);
    _queueProfileSave();
    notifyListeners();
  }

  void setByteOrder(ModbusByteOrder value) {
    if (_byteOrder == value) return;
    if (_sessionActive) return;
    _byteOrder = value;
    onByteOrderChanged?.call(value);
    _queueProfileSave();
    notifyListeners();
  }

  void setWordOrder(ModbusWordOrder value) {
    if (_wordOrder == value) return;
    if (_sessionActive) return;
    _wordOrder = value;
    onWordOrderChanged?.call(value);
    _queueProfileSave();
    notifyListeners();
  }

  void setLogMaxLines(int value) {
    final next =
        value.clamp(modbusMinLogMaxLines, modbusMaxLogMaxLines).toInt();
    if (_logMaxLines == next) return;
    _logMaxLines = next;
    if (_records.length > next) {
      _records.removeRange(0, _records.length - next);
    }
    onLogMaxLinesChanged?.call(next);
    _queueProfileSave();
    notifyListeners();
  }

  Future<void> setMode(ModbusMode value) async {
    if (_mode == value) return;
    await stop();
    _mode = value;
    _parser = ModbusFrameParser(value);
    onModeChanged?.call(value);
    _queueProfileSave();
    notifyListeners();
  }

  void replacePages(List<ModbusRegisterPage> value) {
    final unique = <String, ModbusRegisterPage>{};
    for (final page in value) {
      if (page.unitId >= 0 && page.unitId <= 255) unique[page.key] = page;
    }
    final next = unique.values.toList(growable: false);
    final activeKeys = {
      for (final page in next)
        for (final row in page.rows) _rowKey(page.key, row.id),
    };
    _rowStates.removeWhere((key, _) => !activeKeys.contains(key));
    _sendStates.removeWhere((key, _) => !activeKeys.contains(key));
    _cancelRemovedPeriodic(next);
    _pages = List.unmodifiable(next);
    onPagesChanged?.call(_pages);
    _queueProfileSave();
    notifyListeners();
    _ensureWorker();
  }

  bool addPage(ModbusRegisterPage page) {
    if (_pages.any((item) => item.key == page.key)) return false;
    replacePages([..._pages, page]);
    return true;
  }

  void removePage(String pageKey) {
    replacePages(_pages.where((page) => page.key != pageKey).toList());
  }

  void updatePage(ModbusRegisterPage page) {
    final index = _pages.indexWhere((item) => item.key == page.key);
    if (index < 0) return;
    final next = List<ModbusRegisterPage>.from(_pages)..[index] = page;
    replacePages(next);
  }

  void setPageEnabled(String pageKey, bool enabled) {
    final page = _page(pageKey);
    if (page == null || page.enabled == enabled) return;
    updatePage(page.copyWith(enabled: enabled));
    if (!enabled) _cancelPagePeriodic(pageKey);
  }

  void setPageVariableTypeVisible(String pageKey, bool visible) {
    final page = _page(pageKey);
    if (page == null || page.showVariableType == visible) return;
    updatePage(page.copyWith(showVariableType: visible));
  }

  void addRow(String pageKey, ModbusRegisterRow row) {
    final page = _page(pageKey);
    if (page == null) return;
    updatePage(
      page.copyWith(rows: [...page.rows, _normalizeRow(page.area, row)]),
    );
  }

  void updateRow(String pageKey, ModbusRegisterRow row) {
    final page = _page(pageKey);
    if (page == null) return;
    final rows = [
      for (final current in page.rows)
        if (current.id == row.id) _normalizeRow(page.area, row) else current,
    ];
    _sendStates.remove(_rowKey(pageKey, row.id));
    updatePage(page.copyWith(rows: rows));
  }

  void removeRow(String pageKey, String rowId) {
    final page = _page(pageKey);
    if (page == null) return;
    _cancelPeriodicForRow(pageKey, rowId);
    updatePage(
      page.copyWith(rows: page.rows.where((row) => row.id != rowId).toList()),
    );
    _rowStates.remove(_rowKey(pageKey, rowId));
    _sendStates.remove(_rowKey(pageKey, rowId));
  }

  void setRowPolling(String pageKey, String rowId, bool enabled) {
    final row = _findRow(pageKey, rowId);
    if (row == null) return;
    updateRow(pageKey, row.copyWith(pollEnabled: enabled));
  }

  void setRowSending(String pageKey, String rowId, bool enabled) {
    final page = _page(pageKey);
    final row = _findRow(pageKey, rowId);
    if (page == null || row == null || !page.area.isWritable) return;
    updateRow(pageKey, row.copyWith(sendEnabled: enabled));
  }

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
    final now = DateTime.now();
    for (final page in _pages.where((page) => page.enabled)) {
      for (final row in page.rows) {
        if (row.pollEnabled || (page.area.isWritable && row.sendEnabled)) {
          _nextDue[_periodicKey(page, row, true)] = now;
          _nextDue[_periodicKey(page, row, false)] = now;
        }
      }
    }
    notifyListeners();
    _ensureWorker();
  }

  /// 手动请求仅入队一次，且优先级高于周期任务。
  Future<ModbusResponse> execute(
    ModbusRequest request, {
    int readRetries = 0,
  }) async {
    if (!_sessionActive) throw StateError('请先开始Modbus数据处理');
    final completer = Completer<ModbusResponse>();
    _queue.add(
      _RequestJob(
        manual: true,
        due: DateTime.now(),
        sequence: _sequence++,
        isRead: request.function.isRead,
        run: () => _executeWithRetries(request, readRetries: readRetries),
        completer: completer,
      ),
    );
    _ensureWorker();
    try {
      final response = await completer.future;
      _lastResponse = response;
      _lastError = null;
      notifyListeners();
      return response;
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<ModbusResponse> sendRowOnce(
    String pageKey,
    String rowId,
    String valueText,
  ) async {
    final page = _page(pageKey);
    final row = _findRow(pageKey, rowId);
    if (page == null || row == null) throw StateError('寄存器行不存在');
    if (!page.area.isWritable) throw StateError('当前寄存器区只读');
    final request = _writeRequest(page, row, valueText);
    final response = await execute(request);
    _updateRowState(
      pageKey,
      rowId,
      _rowState(pageKey, rowId).copyWith(
        value: ModbusValueCodec.parse(row.variableType, valueText),
        rawRegisters: request.registerValues,
        lastWriteValue: valueText,
        updatedAt: DateTime.now(),
        clearError: true,
      ),
    );
    return response;
  }

  Future<void> _runPeriodic(String pageKey, String rowId, bool isRead) async {
    final page = _page(pageKey);
    final row = _findRow(pageKey, rowId);
    if (page == null || row == null || !page.enabled) return;
    if (isRead && !row.pollEnabled) return;
    if (!isRead && (!page.area.isWritable || !row.sendEnabled)) return;
    _setBusy(pageKey, rowId, true);
    try {
      if (isRead) {
        final response = await _executeWithRetries(
          _readRequest(page, row),
          readRetries: row.readRetries,
        );
        final value =
            page.area.isBitArea
                ? ModbusValueCodec.decodeCoil(response.coilValues)
                : ModbusValueCodec.decodeRegisters(
                  row.variableType,
                  response.registerValues,
                  byteOrder: _byteOrder,
                  wordOrder: _wordOrder,
                );
        _updateRowState(
          pageKey,
          rowId,
          _rowState(pageKey, rowId).copyWith(
            value: value,
            rawRegisters:
                page.area.isBitArea
                    ? [value == true ? 1 : 0]
                    : response.registerValues,
            updatedAt: DateTime.now(),
            clearError: true,
          ),
        );
      } else {
        final valueText = _nextPeriodicValue(page, row);
        final request = _writeRequest(page, row, valueText);
        await _executeWithRetries(request);
        _updateRowState(
          pageKey,
          rowId,
          _rowState(pageKey, rowId).copyWith(
            value: ModbusValueCodec.parse(row.variableType, valueText),
            rawRegisters: request.registerValues,
            lastWriteValue: valueText,
            updatedAt: DateTime.now(),
            clearError: true,
          ),
        );
      }
    } catch (error) {
      _updateRowState(
        pageKey,
        rowId,
        _rowState(
          pageKey,
          rowId,
        ).copyWith(error: error, updatedAt: DateTime.now()),
      );
      rethrow;
    } finally {
      _setBusy(pageKey, rowId, false);
    }
  }

  Future<ModbusResponse> _executeWithRetries(
    ModbusRequest request, {
    int readRetries = 0,
  }) async {
    final retries = request.function.isRead ? readRetries.clamp(0, 3) : 0;
    final epoch = _requestEpoch;
    Object? lastFailure;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await _executeOnce(request);
      } catch (error) {
        lastFailure = error;
        if (!_sessionActive || !_link.isConnected || epoch != _requestEpoch) {
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
        onTimeout: () => throw TimeoutException('Modbus响应超时'),
      );
      return response;
    } catch (error) {
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

  Future<void> _worker() async {
    try {
      while (_sessionActive) {
        _enqueueDuePeriodicJobs();
        final job = _takeNextJob();
        if (job == null) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        try {
          final response = await job.run();
          if (job.completer != null && !job.completer!.isCompleted) {
            job.completer!.complete(response);
          }
        } catch (error, stackTrace) {
          if (job.completer != null && !job.completer!.isCompleted) {
            job.completer!.completeError(error, stackTrace);
          }
        } finally {
          if (job.periodicKey != null) {
            _queuedPeriodic.remove(job.periodicKey);
            final interval = _periodicInterval(job.periodicKey!);
            if (interval != null) {
              _nextDue[job.periodicKey!] = DateTime.now().add(
                Duration(milliseconds: interval),
              );
            }
          }
          notifyListeners();
        }
      }
    } finally {
      _workerRunning = false;
      if (_sessionActive) _ensureWorker();
    }
  }

  void _ensureWorker() {
    if (!_sessionActive || _workerRunning) return;
    _workerRunning = true;
    unawaited(_worker());
  }

  void _enqueueDuePeriodicJobs() {
    if (!_sessionActive) return;
    final now = DateTime.now();
    for (final page in _pages) {
      if (!page.enabled) continue;
      for (final row in page.rows) {
        if (row.pollEnabled) _enqueueIfDue(page, row, true, now);
        if (page.area.isWritable && row.sendEnabled) {
          _enqueueIfDue(page, row, false, now);
        }
      }
    }
  }

  void _enqueueIfDue(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    bool isRead,
    DateTime now,
  ) {
    final key = _periodicKey(page, row, isRead);
    final due = _nextDue.putIfAbsent(key, () => now);
    if (due.isAfter(now) || !_queuedPeriodic.add(key)) return;
    _queue.add(
      _RequestJob(
        manual: false,
        due: due,
        sequence: _sequence++,
        isRead: isRead,
        periodicKey: key,
        rowKey: _rowKey(page.key, row.id),
        run:
            () => _runPeriodic(page.key, row.id, isRead).then(
              (_) => ModbusResponse(
                request: _readRequest(page, row),
                rawFrame: Uint8List(0),
              ),
            ),
      ),
    );
  }

  _RequestJob? _takeNextJob() {
    if (_queue.isEmpty) return null;
    _queue.sort((left, right) {
      if (left.manual != right.manual) return left.manual ? -1 : 1;
      final due = left.due.compareTo(right.due);
      if (due != 0) return due;
      if (left.isRead != right.isRead) return left.isRead ? -1 : 1;
      return left.sequence.compareTo(right.sequence);
    });
    return _queue.removeAt(0);
  }

  ModbusRequest _readRequest(ModbusRegisterPage page, ModbusRegisterRow row) =>
      ModbusRequest(
        mode: _mode,
        unitId: page.unitId,
        function: page.area.readFunction,
        address: row.address,
        quantity: page.area.isBitArea ? 1 : row.variableType.registerWidth,
      );

  ModbusRequest _writeRequest(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    String valueText,
  ) {
    if (page.area.isBitArea) {
      final value = ModbusValueCodec.parse(
        ModbusVariableType.boolean,
        valueText,
      );
      return ModbusRequest(
        mode: _mode,
        unitId: page.unitId,
        function: ModbusFunction.writeSingleCoil,
        address: row.address,
        quantity: 1,
        coilValues: [value == true],
      );
    }
    final values = ModbusValueCodec.encodeRegisters(
      row.variableType,
      valueText,
      byteOrder: _byteOrder,
      wordOrder: _wordOrder,
    );
    return ModbusRequest(
      mode: _mode,
      unitId: page.unitId,
      function:
          values.length == 1
              ? ModbusFunction.writeSingleRegister
              : ModbusFunction.writeMultipleRegisters,
      address: row.address,
      quantity: values.length,
      registerValues: values,
    );
  }

  String _nextPeriodicValue(ModbusRegisterPage page, ModbusRegisterRow row) {
    final key = _rowKey(page.key, row.id);
    if (row.sendMode == ModbusSendValueMode.fixed) return row.sendValue;
    if (row.sendMode == ModbusSendValueMode.random) {
      return _randomValue(row.variableType);
    }
    final currentText = _sendStates[key] ?? row.sendValue;
    final current = ModbusValueCodec.parse(row.variableType, currentText);
    final step = ModbusValueCodec.parse(row.variableType, row.sendStep);
    final next = _stepValue(row.variableType, current, step, row.sendMode);
    _sendStates[key] = _valueText(next);
    return currentText;
  }

  Object _stepValue(
    ModbusVariableType type,
    Object current,
    Object step,
    ModbusSendValueMode mode,
  ) {
    final direction = mode == ModbusSendValueMode.increment ? 1 : -1;
    if (type == ModbusVariableType.boolean) return current != true;
    if (type.isFloatingPoint) {
      final value = (current as double) + direction * (step as double);
      if (!value.isFinite) return current;
      return value;
    }
    final currentValue =
        current is BigInt ? current : BigInt.from(current as int);
    final stepValue = step is BigInt ? step : BigInt.from(step as int);
    final value = currentValue + BigInt.from(direction) * stepValue;
    final (min, max) = switch (type) {
      ModbusVariableType.u8 => (BigInt.zero, BigInt.from(0xFF)),
      ModbusVariableType.i8 => (BigInt.from(-0x80), BigInt.from(0x7F)),
      ModbusVariableType.u16 => (BigInt.zero, BigInt.from(0xFFFF)),
      ModbusVariableType.i16 => (BigInt.from(-0x8000), BigInt.from(0x7FFF)),
      ModbusVariableType.u32 => (BigInt.zero, BigInt.from(0xFFFFFFFF)),
      ModbusVariableType.i32 => (
        BigInt.from(-0x80000000),
        BigInt.from(0x7FFFFFFF),
      ),
      ModbusVariableType.u64 => (BigInt.zero, (BigInt.one << 64) - BigInt.one),
      ModbusVariableType.i64 => (
        -(BigInt.one << 63),
        (BigInt.one << 63) - BigInt.one,
      ),
      ModbusVariableType.boolean ||
      ModbusVariableType.floatValue ||
      ModbusVariableType.doubleValue => (BigInt.zero, BigInt.one),
    };
    final span = max - min + BigInt.one;
    final result = min + ((value - min) % span + span) % span;
    return type == ModbusVariableType.u64 ? result : result.toInt();
  }

  String _randomValue(ModbusVariableType type) {
    if (type == ModbusVariableType.boolean) {
      return _random.nextBool() ? '1' : '0';
    }
    if (type.isFloatingPoint) return _random.nextDouble().toString();
    final max = switch (type) {
      ModbusVariableType.u8 => 0xFF,
      ModbusVariableType.i8 => 0x7F,
      ModbusVariableType.u16 => 0xFFFF,
      ModbusVariableType.i16 => 0x7FFF,
      ModbusVariableType.u32 => 0xFFFFFFFF,
      ModbusVariableType.i32 => 0x7FFFFFFF,
      ModbusVariableType.u64 || ModbusVariableType.i64 => 0x7FFFFFFF,
      _ => 0xFFFF,
    };
    final value = _random.nextInt(max + 1);
    final signed = type.isSigned && _random.nextBool() ? -value : value;
    return '$signed';
  }

  String _valueText(Object value) =>
      value is bool ? (value ? '1' : '0') : '$value';

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
    if (_records.length > _logMaxLines) {
      _records.removeRange(0, _records.length - _logMaxLines);
    }
  }

  void clearRecords() {
    _records.clear();
    notifyListeners();
  }

  Future<void> stop() async {
    // 停止 Modbus 会话时同步停止所有页面级调度器。
    // 保留每个寄存器的轮询和发送配置，供下次手动启动使用。
    final runningPages = _pages.where((page) => page.enabled).toList();
    if (runningPages.isNotEmpty) {
      _pages = List.unmodifiable([
        for (final page in _pages)
          page.enabled ? page.copyWith(enabled: false) : page,
      ]);
      onPagesChanged?.call(_pages);
    }
    final wasActive = _sessionActive;
    _sessionActive = false;
    _requestEpoch++;
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(StateError('Modbus活动已停止'));
    }
    _pending = null;
    for (final job in _queue) {
      final completer = job.completer;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(StateError('Modbus活动已停止'));
      }
    }
    _queue.clear();
    _queuedPeriodic.clear();
    _nextDue.clear();
    _parser.reset();
    await _subscription?.cancel();
    _subscription = null;
    await _disconnectSubscription?.cancel();
    _disconnectSubscription = null;
    if (wasActive) _link.release();
    notifyListeners();
  }

  String exportConfiguration() {
    final modbus = <String, Object?>{};
    if (_mode != ModbusMode.rtu) {
      modbus['connection'] = {'mode': _mode.value};
    }
    if (_timeoutMs != 1000) {
      (modbus['connection'] ??= <String, Object?>{}) as Map<String, Object?>;
      (modbus['connection'] as Map<String, Object?>)['timeoutMs'] = _timeoutMs;
    }
    if (_layoutMode != ModbusRegisterLayoutMode.columnMajor) {
      modbus['view'] = {'layoutMode': _layoutMode.value};
    }
    if (_byteOrder != ModbusByteOrder.highByteFirst) {
      modbus['byteOrder'] = _byteOrder.value;
    }
    if (_wordOrder != ModbusWordOrder.highWordFirst) {
      modbus['wordOrder'] = _wordOrder.value;
    }
    if (_logMaxLines != modbusDefaultLogMaxLines) {
      modbus['logging'] = {'maxLines': _logMaxLines};
    }
    if (_pages.isNotEmpty) {
      modbus['pages'] = [for (final page in _pages) page.toSparseJson()];
    }
    return const JsonEncoder.withIndent(
      '  ',
    ).convert({'schemaVersion': 1, 'modbus': modbus});
  }

  Future<ModbusConfigurationImportResult> importConfiguration(
    String source,
  ) async {
    final errors = <String>[];
    final skipped = <String>[];
    final parsed = <ModbusRegisterPage>[];
    try {
      final root = jsonDecode(source);
      if (root is! Map || root['schemaVersion'] != 1) {
        return const ModbusConfigurationImportResult(
          pages: [],
          errors: ['不是受支持的 Modbus 配置文件'],
        );
      }
      final modbus = root['modbus'];
      if (modbus is! Map) {
        return const ModbusConfigurationImportResult(
          pages: [],
          errors: ['Modbus 配置节点无效'],
        );
      }
      final connection = modbus['connection'];
      if (connection is Map) {
        final timeout = (connection['timeoutMs'] as num?)?.toInt();
        if (timeout != null) setTimeoutMs(timeout);
        final mode = ModbusMode.fromString(connection['mode'] as String?);
        if (mode != _mode && !_link.isConnected) await setMode(mode);
      }
      final view = modbus['view'];
      if (view is Map) {
        setLayoutMode(ModbusRegisterLayoutMode.fromValue(view['layoutMode']));
      }
      setByteOrder(ModbusByteOrder.fromString(modbus['byteOrder']));
      setWordOrder(ModbusWordOrder.fromString(modbus['wordOrder']));
      final logging = modbus['logging'];
      if (logging is Map && logging['maxLines'] is num) {
        setLogMaxLines((logging['maxLines'] as num).toInt());
      }
      final values = modbus['pages'];
      if (values is! List) {
        return ModbusConfigurationImportResult(pages: [], errors: errors);
      }
      final existing = _pages.map((page) => page.key).toSet();
      for (var index = 0; index < values.length; index++) {
        final page = ModbusRegisterPage.fromJson(values[index]);
        if (page == null) {
          errors.add('第${index + 1}个页面无效');
        } else if (existing.contains(page.key) ||
            parsed.any((item) => item.key == page.key)) {
          skipped.add(page.key);
        } else {
          parsed.add(page.copyWith(enabled: false));
        }
      }
      if (parsed.isNotEmpty) replacePages([..._pages, ...parsed]);
    } catch (error) {
      errors.add('JSON解析失败：$error');
    }
    return ModbusConfigurationImportResult(
      pages: List.unmodifiable(parsed),
      errors: List.unmodifiable(errors),
      skippedPageKeys: List.unmodifiable(skipped),
    );
  }

  void _setBusy(String pageKey, String rowId, bool busy) {
    _updateRowState(
      pageKey,
      rowId,
      _rowState(pageKey, rowId).copyWith(busy: busy),
    );
  }

  void _updateRowState(String pageKey, String rowId, ModbusRowState state) {
    _rowStates[_rowKey(pageKey, rowId)] = state;
    notifyListeners();
  }

  ModbusRowState _rowState(String pageKey, String rowId) =>
      _rowStates[_rowKey(pageKey, rowId)] ?? const ModbusRowState();

  ModbusRegisterPage? _page(String key) => _pages
      .cast<ModbusRegisterPage?>()
      .firstWhere((page) => page!.key == key, orElse: () => null);

  ModbusRegisterRow? _findRow(String pageKey, String rowId) {
    final page = _page(pageKey);
    if (page == null) return null;
    for (final row in page.rows) {
      if (row.id == rowId) return row;
    }
    return null;
  }

  ModbusRegisterRow _normalizeRow(
    ModbusRegisterArea area,
    ModbusRegisterRow row,
  ) =>
      area.isBitArea
          ? row.copyWith(
            variableType: ModbusVariableType.boolean,
            sendEnabled: area.isWritable ? row.sendEnabled : false,
          )
          : row.copyWith(
            sendEnabled: area.isWritable ? row.sendEnabled : false,
          );

  String _rowKey(String pageKey, String rowId) => '$pageKey/$rowId';

  String _periodicKey(
    ModbusRegisterPage page,
    ModbusRegisterRow row,
    bool read,
  ) => '${read ? 'poll' : 'send'}:${page.key}:${row.id}';

  int? _periodicInterval(String key) {
    for (final page in _pages) {
      for (final row in page.rows) {
        if (key == _periodicKey(page, row, true)) return row.pollIntervalMs;
        if (key == _periodicKey(page, row, false)) return row.sendIntervalMs;
      }
    }
    return null;
  }

  void _cancelRemovedPeriodic(List<ModbusRegisterPage> pages) {
    final active = {
      for (final page in pages)
        for (final row in page.rows) ...{
          _periodicKey(page, row, true),
          _periodicKey(page, row, false),
        },
    };
    _nextDue.removeWhere((key, _) => !active.contains(key));
    _queuedPeriodic.removeWhere((key) => !active.contains(key));
    _queue.removeWhere(
      (job) => job.periodicKey != null && !active.contains(job.periodicKey),
    );
  }

  void _cancelPagePeriodic(String pageKey) {
    _nextDue.removeWhere((key, _) => key.contains(':$pageKey:'));
    _queuedPeriodic.removeWhere((key) => key.contains(':$pageKey:'));
    _queue.removeWhere(
      (job) => job.periodicKey?.contains(':$pageKey:') ?? false,
    );
  }

  void _cancelPeriodicForRow(String pageKey, String rowId) {
    final prefix = ':$pageKey:$rowId';
    _nextDue.removeWhere((key, _) => key.contains(prefix));
    _queuedPeriodic.removeWhere((key) => key.contains(prefix));
    _queue.removeWhere((job) => job.periodicKey?.contains(prefix) ?? false);
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

class _PendingRequest {
  _PendingRequest(this.request)
    : completer = Completer<ModbusResponse>(),
      stopwatch = Stopwatch()..start();

  final ModbusRequest request;
  final Completer<ModbusResponse> completer;
  final Stopwatch stopwatch;
}
