import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _MultiByteToWideCharNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 flags,
      Pointer<Uint8> input,
      Int32 inputLength,
      Pointer<Uint16> output,
      Int32 outputLength,
    );
typedef _MultiByteToWideCharDart =
    int Function(
      int codePage,
      int flags,
      Pointer<Uint8> input,
      int inputLength,
      Pointer<Uint16> output,
      int outputLength,
    );
typedef _WideCharToMultiByteNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 flags,
      Pointer<Uint16> input,
      Int32 inputLength,
      Pointer<Uint8> output,
      Int32 outputLength,
      Pointer<Uint8> defaultChar,
      Pointer<Int32> usedDefaultChar,
    );
typedef _WideCharToMultiByteDart =
    int Function(
      int codePage,
      int flags,
      Pointer<Uint16> input,
      int inputLength,
      Pointer<Uint8> output,
      int outputLength,
      Pointer<Uint8> defaultChar,
      Pointer<Int32> usedDefaultChar,
    );

final DynamicLibrary _kernel32 =
    Platform.isWindows
        ? DynamicLibrary.open('kernel32.dll')
        : DynamicLibrary.process();
final _MultiByteToWideCharDart _multiByteToWideChar = _kernel32
    .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
      'MultiByteToWideChar',
    );
final _WideCharToMultiByteDart _wideCharToMultiByte = _kernel32
    .lookupFunction<_WideCharToMultiByteNative, _WideCharToMultiByteDart>(
      'WideCharToMultiByte',
    );

/// 使用 Windows 系统代码页转换双字节文本，避免维护庞大的静态字符映射表。
///
/// 本项目仅发布 Windows 版本；在其它平台调用会明确报错，防止静默产生乱码。
String decodeWindowsCodePage(Uint8List data, int codePage) {
  if (!Platform.isWindows) throw UnsupportedError('Windows 代码页仅支持 Windows');
  if (data.isEmpty) return '';
  final input = calloc<Uint8>(data.length);
  try {
    input.asTypedList(data.length).setAll(0, data);
    final length = _multiByteToWideChar(
      codePage,
      0,
      input,
      data.length,
      nullptr,
      0,
    );
    if (length <= 0) throw FormatException('代码页 $codePage 解码失败');
    final output = calloc<Uint16>(length);
    try {
      final written = _multiByteToWideChar(
        codePage,
        0,
        input,
        data.length,
        output,
        length,
      );
      if (written <= 0) throw FormatException('代码页 $codePage 解码失败');
      return String.fromCharCodes(output.asTypedList(written));
    } finally {
      calloc.free(output);
    }
  } finally {
    calloc.free(input);
  }
}

Uint8List encodeWindowsCodePage(String text, int codePage) {
  if (!Platform.isWindows) throw UnsupportedError('Windows 代码页仅支持 Windows');
  if (text.isEmpty) return Uint8List(0);
  final units = text.codeUnits;
  final input = calloc<Uint16>(units.length);
  try {
    input.asTypedList(units.length).setAll(0, units);
    final length = _wideCharToMultiByte(
      codePage,
      0,
      input,
      units.length,
      nullptr,
      0,
      nullptr,
      nullptr,
    );
    if (length <= 0) throw FormatException('代码页 $codePage 编码失败');
    final output = calloc<Uint8>(length);
    try {
      final written = _wideCharToMultiByte(
        codePage,
        0,
        input,
        units.length,
        output,
        length,
        nullptr,
        nullptr,
      );
      if (written <= 0) throw FormatException('代码页 $codePage 编码失败');
      return Uint8List.fromList(output.asTypedList(written));
    } finally {
      calloc.free(output);
    }
  } finally {
    calloc.free(input);
  }
}
