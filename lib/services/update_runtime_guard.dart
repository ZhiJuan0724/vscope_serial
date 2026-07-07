import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

abstract interface class UpdateRuntimeGuard {
  Future<T> runWithUpdateLock<T>(Future<T> Function() action);

  Future<List<int>> findOtherInstanceProcessIds();

  Future<void> requestCloseProcesses(List<int> processIds);

  Future<bool> waitForOtherInstancesToExit(Duration timeout);
}

final class UpdateRuntimeGuardException implements Exception {
  final String message;
  const UpdateRuntimeGuardException(this.message);

  @override
  String toString() => message;
}

final class WindowsUpdateRuntimeGuard implements UpdateRuntimeGuard {
  static const String updateMutexName = r'Local\vscope_serial_update_lock';
  static const int _maxPathChars = 32768;
  static Set<int> _closeTargetProcessIds = <int>{};

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final int Function(
    Pointer<Void>,
    int,
    Pointer<Utf16>,
  ) _createMutex = _kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
        int Function(Pointer<Void>, int, Pointer<Utf16>)
      >('CreateMutexW');
  static final int Function(int) _releaseMutex = _kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'ReleaseMutex',
      );

  @override
  Future<T> runWithUpdateLock<T>(Future<T> Function() action) async {
    if (!Platform.isWindows) return action();

    final name = updateMutexName.toNativeUtf16();
    final handle = _createMutex(nullptr, 0, name);
    calloc.free(name);
    if (handle == 0) {
      throw const UpdateRuntimeGuardException('无法创建更新锁');
    }

    var ownsMutex = false;
    try {
      final waitResult = WaitForSingleObject(handle, 0);
      if (waitResult != WAIT_OBJECT_0) {
        throw const UpdateRuntimeGuardException('已有更新任务正在进行，请稍后再试');
      }
      ownsMutex = true;
      return await action();
    } finally {
      if (ownsMutex) _releaseMutex(handle);
      CloseHandle(handle);
    }
  }

  @override
  Future<List<int>> findOtherInstanceProcessIds() async {
    if (!Platform.isWindows) return const <int>[];
    final currentExecutable = _normalizePath(Platform.resolvedExecutable);
    final currentPid = pid;
    final processIds = _enumProcessIds();
    final matches = <int>[];
    for (final processId in processIds) {
      if (processId == 0 || processId == currentPid) continue;
      final imagePath = _queryProcessImagePath(processId);
      if (imagePath == null) continue;
      if (_normalizePath(imagePath) == currentExecutable) {
        matches.add(processId);
      }
    }
    return matches;
  }

  @override
  Future<void> requestCloseProcesses(List<int> processIds) async {
    if (!Platform.isWindows || processIds.isEmpty) return;
    _closeTargetProcessIds = processIds.toSet();
    final callback = Pointer.fromFunction<WNDENUMPROC>(
      _enumWindowsCloseProc,
      TRUE,
    );
    EnumWindows(callback, 0);
    _closeTargetProcessIds = <int>{};
  }

  @override
  Future<bool> waitForOtherInstancesToExit(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = await findOtherInstanceProcessIds();
      if (remaining.isEmpty) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return (await findOtherInstanceProcessIds()).isEmpty;
  }

  static int _enumWindowsCloseProc(int hWnd, int lParam) {
    if (IsWindowVisible(hWnd) == 0) return TRUE;
    final processId = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hWnd, processId);
      if (_closeTargetProcessIds.contains(processId.value)) {
        PostMessage(hWnd, WM_CLOSE, 0, 0);
      }
    } finally {
      calloc.free(processId);
    }
    return TRUE;
  }

  static List<int> _enumProcessIds() {
    const capacity = 8192;
    final processIds = calloc<Uint32>(capacity);
    final bytesNeeded = calloc<Uint32>();
    try {
      final ok = EnumProcesses(
        processIds,
        capacity * sizeOf<Uint32>(),
        bytesNeeded,
      );
      if (ok == 0) return const <int>[];
      final count = bytesNeeded.value ~/ sizeOf<Uint32>();
      return [
        for (var i = 0; i < count && i < capacity; i++) processIds[i],
      ];
    } finally {
      calloc.free(processIds);
      calloc.free(bytesNeeded);
    }
  }

  static String? _queryProcessImagePath(int processId) {
    final handle = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      FALSE,
      processId,
    );
    if (handle == 0) return null;
    final buffer = wsalloc(_maxPathChars);
    final size = calloc<Uint32>()..value = _maxPathChars;
    try {
      final ok = QueryFullProcessImageName(handle, 0, buffer, size);
      if (ok == 0) return null;
      return buffer.toDartString();
    } finally {
      calloc.free(size);
      free(buffer);
      CloseHandle(handle);
    }
  }

  static String _normalizePath(String path) =>
      File(path).absolute.path.replaceAll('/', r'\').toLowerCase();
}
