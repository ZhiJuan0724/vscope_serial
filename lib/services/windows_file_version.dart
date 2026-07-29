import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 不启动目标程序，直接读取 Windows PE 文件的 ProductVersion/FileVersion。
///
/// 外部工具的“版本查询”参数在不同版本间并不稳定，直接读取版本资源可避免
/// 工具误进入正常启动流程并弹出交互窗口。
String? readWindowsFileVersion(String path) {
  if (!Platform.isWindows || !File(path).existsSync()) return null;
  final fileName = path.toNativeUtf16();
  final ignoredHandle = calloc<Uint32>();
  Pointer<Uint8>? data;
  try {
    final size = GetFileVersionInfoSize(fileName, ignoredHandle);
    if (size <= 0) return null;
    data = calloc<Uint8>(size);
    if (GetFileVersionInfo(fileName, 0, size, data) == 0) return null;

    final translations = _readTranslations(data);
    for (final translation in translations) {
      final prefix =
          translation
              .map((value) => value.toRadixString(16).padLeft(4, '0'))
              .join();
      for (final key in const ['ProductVersion', 'FileVersion']) {
        final value = _queryVersionString(
          data,
          '\\StringFileInfo\\$prefix\\$key',
        );
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return _readFixedFileVersion(data);
  } finally {
    if (data != null) calloc.free(data);
    calloc.free(ignoredHandle);
    calloc.free(fileName);
  }
}

List<List<int>> _readTranslations(Pointer<Uint8> data) {
  final result = <List<int>>[];
  final value = calloc<Pointer<Void>>();
  final length = calloc<Uint32>();
  final key = r'\VarFileInfo\Translation'.toNativeUtf16();
  try {
    if (VerQueryValue(data, key, value.cast<Pointer>(), length) != 0 &&
        length.value >= 4) {
      final words = value.value.cast<Uint16>();
      for (var index = 0; index + 1 < length.value ~/ 2; index += 2) {
        result.add([words[index], words[index + 1]]);
      }
    }
  } finally {
    calloc.free(key);
    calloc.free(length);
    calloc.free(value);
  }
  // 常见英文版本资源作为无 Translation 表时的兼容回退。
  if (result.isEmpty) {
    result.addAll(const [
      [0x0409, 0x04B0],
      [0x0409, 0x04E4],
    ]);
  }
  return result;
}

String? _queryVersionString(Pointer<Uint8> data, String subBlock) {
  final value = calloc<Pointer<Void>>();
  final length = calloc<Uint32>();
  final key = subBlock.toNativeUtf16();
  try {
    if (VerQueryValue(data, key, value.cast<Pointer>(), length) == 0 ||
        value.value == nullptr ||
        length.value == 0) {
      return null;
    }
    return value.value
        .cast<Utf16>()
        .toDartString(length: length.value - 1)
        .trim();
  } finally {
    calloc.free(key);
    calloc.free(length);
    calloc.free(value);
  }
}

String? _readFixedFileVersion(Pointer<Uint8> data) {
  final value = calloc<Pointer<Void>>();
  final length = calloc<Uint32>();
  final key = r'\'.toNativeUtf16();
  try {
    if (VerQueryValue(data, key, value.cast<Pointer>(), length) == 0 ||
        length.value < sizeOf<VS_FIXEDFILEINFO>()) {
      return null;
    }
    final info = value.value.cast<VS_FIXEDFILEINFO>().ref;
    return '${info.dwFileVersionMS >> 16}.'
        '${info.dwFileVersionMS & 0xFFFF}.'
        '${info.dwFileVersionLS >> 16}.'
        '${info.dwFileVersionLS & 0xFFFF}';
  } finally {
    calloc.free(key);
    calloc.free(length);
    calloc.free(value);
  }
}
