import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models/modbus_models.dart';
import 'modbus_client_service.dart';

/// 管理 Modbus 独立页面窗口在主窗口侧的生命周期。
///
/// 子引擎不直接持有 ModbusDataLink，只向此处发送命令，并渲染由唯一服务
/// 所有者广播的状态快照。
class ModbusWindowManager extends ChangeNotifier {
  ModbusWindowManager(this._service) {
    DesktopMultiWindow.setMethodHandler(_handleMethod);
    _service.addListener(_onServiceChanged);
  }

  final ModbusClientService _service;
  final Map<String, WindowController> _windowsByPage = {};
  final Map<int, String> _pagesByWindow = {};
  bool _broadcastScheduled = false;
  bool _reconcileRunning = false;
  Timer? _windowMonitor;

  bool isDetached(String pageKey) => _windowsByPage.containsKey(pageKey);

  Future<void> detachPage(String pageKey) async {
    final page = _service.pages.cast<ModbusRegisterPage?>().firstWhere(
      (item) => item!.key == pageKey,
      orElse: () => null,
    );
    if (page == null) return;
    final existing = _windowsByPage[pageKey];
    if (existing != null) {
      await existing.show();
      return;
    }
    final title = 'Modbus · U${page.unitId} · ${page.area.label}';
    final window = await DesktopMultiWindow.createWindow(
      jsonEncode({
        'business': 'modbusPage',
        'pageKey': pageKey,
        'windowTitle': title,
      }),
    );
    _windowsByPage[pageKey] = window;
    _pagesByWindow[window.windowId] = pageKey;
    _startWindowMonitor();
    notifyListeners();
    await window.setFrame(const Rect.fromLTWH(120, 120, 1080, 720));
    await window.setTitle(title);
    await window.show();
  }

  Future<void> closePage(String pageKey) async {
    final window = _windowsByPage.remove(pageKey);
    if (window == null) return;
    _pagesByWindow.remove(window.windowId);
    await window.close();
    _stopWindowMonitorIfIdle();
    notifyListeners();
  }

  Future<void> closeAll() async {
    final windows = _windowsByPage.values.toList(growable: false);
    _windowsByPage.clear();
    _pagesByWindow.clear();
    _windowMonitor?.cancel();
    _windowMonitor = null;
    for (final window in windows) {
      try {
        await window.close();
      } catch (_) {
        // 用户可能已经关闭了子窗口。
      }
    }
    notifyListeners();
  }

  Future<dynamic> _handleMethod(MethodCall call, int fromWindowId) async {
    final args =
        call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
    switch (call.method) {
      case 'modbusReady':
        final pageKey =
            args['pageKey'] as String? ?? _pagesByWindow[fromWindowId];
        if (pageKey != null) await _sendSnapshot(fromWindowId, pageKey);
      case 'modbusDetachedClosed':
        final pageKey = _pagesByWindow.remove(fromWindowId);
        if (pageKey != null) {
          _windowsByPage.remove(pageKey);
          _stopWindowMonitorIfIdle();
          notifyListeners();
        }
      case 'modbusCommand':
        await _applyCommand(args);
    }
    return null;
  }

  Future<void> _applyCommand(Map<String, dynamic> args) async {
    final pageKey = args['pageKey'] as String?;
    final command = args['command'] as String?;
    if (pageKey == null || command == null) return;
    switch (command) {
      case 'setPageEnabled':
        _service.setPageEnabled(pageKey, args['enabled'] == true);
      case 'setPageVariableTypeVisible':
        _service.setPageVariableTypeVisible(pageKey, args['visible'] == true);
      case 'setRowPolling':
        _service.setRowPolling(
          pageKey,
          '${args['rowId']}',
          args['enabled'] == true,
        );
      case 'setRowSending':
        _service.setRowSending(
          pageKey,
          '${args['rowId']}',
          args['enabled'] == true,
        );
      case 'sendOnce':
        await _service.sendRowOnce(
          pageKey,
          '${args['rowId']}',
          '${args['value'] ?? ''}',
        );
      case 'setLayoutMode':
        _service.setLayoutMode(
          ModbusRegisterLayoutMode.fromValue(args['value']),
        );
      case 'removeRow':
        _service.removeRow(pageKey, '${args['rowId']}');
      case 'updateRow':
        final page = _service.pages.cast<ModbusRegisterPage?>().firstWhere(
          (item) => item!.key == pageKey,
          orElse: () => null,
        );
        final rowMap =
            args['row'] is Map
                ? Map<String, dynamic>.from(args['row'] as Map)
                : null;
        if (page != null && rowMap != null) {
          rowMap['id'] = '${args['rowId']}';
          final row = ModbusRegisterRow.fromJson(rowMap, page.area);
          if (row != null) _service.updateRow(pageKey, row);
        }
      case 'addRows':
        final page = _service.pages.cast<ModbusRegisterPage?>().firstWhere(
          (item) => item!.key == pageKey,
          orElse: () => null,
        );
        final start = (args['start'] as num?)?.toInt();
        final count = (args['count'] as num?)?.toInt();
        if (page != null && start != null && count != null) {
          final type =
              ModbusVariableType.fromString(args['variableType']) ??
              ModbusVariableType.defaultFor(page.area);
          for (var index = 0; index < count; index++) {
            _service.addRow(
              pageKey,
              ModbusRegisterRow(
                id: '${DateTime.now().microsecondsSinceEpoch}-$index',
                address: start + index,
                variableType:
                    page.area.isBitArea ? ModbusVariableType.boolean : type,
              ),
            );
          }
        }
    }
  }

  void _onServiceChanged() {
    if (_broadcastScheduled || _windowsByPage.isEmpty) return;
    _broadcastScheduled = true;
    scheduleMicrotask(() {
      _broadcastScheduled = false;
      unawaited(_broadcastSnapshots());
    });
  }

  void _startWindowMonitor() {
    _windowMonitor ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_reconcileWindows()),
    );
  }

  void _stopWindowMonitorIfIdle() {
    if (_windowsByPage.isNotEmpty) return;
    _windowMonitor?.cancel();
    _windowMonitor = null;
  }

  Future<void> _reconcileWindows() async {
    if (_reconcileRunning || _pagesByWindow.isEmpty) return;
    _reconcileRunning = true;
    try {
      final activeIds = (await DesktopMultiWindow.getAllSubWindowIds()).toSet();
      var changed = false;
      for (final entry in _pagesByWindow.entries.toList(growable: false)) {
        if (activeIds.contains(entry.key)) continue;
        _pagesByWindow.remove(entry.key);
        _windowsByPage.remove(entry.value);
        changed = true;
      }
      if (changed) {
        _stopWindowMonitorIfIdle();
        notifyListeners();
      }
    } finally {
      _reconcileRunning = false;
    }
  }

  Future<void> _broadcastSnapshots() async {
    for (final entry in _pagesByWindow.entries.toList(growable: false)) {
      await _sendSnapshot(entry.key, entry.value);
    }
  }

  Future<void> _sendSnapshot(int windowId, String pageKey) async {
    final page = _service.pages.cast<ModbusRegisterPage?>().firstWhere(
      (item) => item!.key == pageKey,
      orElse: () => null,
    );
    if (page == null) return;
    final states = <String, Object?>{};
    for (final row in page.rows) {
      final state = _service.rowState(page.key, row.id);
      states[row.id] = {
        'value': state.value,
        'rawRegisters': state.rawRegisters,
        'error': state.error?.toString(),
        'busy': state.busy,
        'lastWriteValue': state.lastWriteValue,
        'updatedAt': state.updatedAt?.toIso8601String(),
      };
    }
    try {
      final pageSnapshot = page.toSparseJson();
      final rows = pageSnapshot['rows'];
      if (rows is List) {
        for (
          var index = 0;
          index < rows.length && index < page.rows.length;
          index++
        ) {
          final row = rows[index];
          if (row is Map<String, Object?>) row['id'] = page.rows[index].id;
        }
      }
      await DesktopMultiWindow.invokeMethod(windowId, 'modbusSnapshot', {
        'page': pageSnapshot,
        'layoutMode': _service.layoutMode.value,
        'sessionActive': _service.sessionActive,
        'states': states,
      });
    } catch (_) {
      _pagesByWindow.remove(windowId);
      _windowsByPage.remove(pageKey);
      _stopWindowMonitorIfIdle();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    DesktopMultiWindow.setMethodHandler(null);
    _windowMonitor?.cancel();
    unawaited(closeAll());
    super.dispose();
  }
}
