import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../data/models/ssh_connection_config.dart';

/// SSH 密码安全存储边界，便于界面测试替换系统凭据库。
abstract interface class SshPasswordStore {
  String? read(SshConnectionConfig config);

  void write(SshConnectionConfig config, String password);

  void delete(SshConnectionConfig config);
}

/// 使用 Windows Credential Manager 保存 SSH 密码。
///
/// 密码不会写入应用 JSON；凭据由 Windows 绑定到当前登录用户进行保护。
final class WindowsSshPasswordStore implements SshPasswordStore {
  const WindowsSshPasswordStore();

  static String _targetName(SshConnectionConfig config) {
    final identity =
        '${config.endpointKey}\n${config.username.trim().toLowerCase()}';
    final digest = sha256.convert(utf8.encode(identity));
    return 'VScopeSerial/SSH/$digest';
  }

  static void _requireWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError('SSH 密码安全存储目前仅支持 Windows');
    }
  }

  @override
  String? read(SshConnectionConfig config) {
    _requireWindows();
    final target = _targetName(config).toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      if (CredRead(target, CRED_TYPE_GENERIC, 0, result) != TRUE) {
        final error = GetLastError();
        if (error == ERROR_NOT_FOUND) return null;
        throw WindowsException(HRESULT_FROM_WIN32(error));
      }
      final credential = result.value.ref;
      final bytes = credential.CredentialBlob.asTypedList(
        credential.CredentialBlobSize,
      );
      return utf8.decode(bytes);
    } finally {
      if (result.value.address != 0) CredFree(result.value);
      calloc.free(result);
      calloc.free(target);
    }
  }

  @override
  void write(SshConnectionConfig config, String password) {
    _requireWindows();
    final target = _targetName(config).toNativeUtf16();
    final username = config.username.toNativeUtf16();
    final passwordBytes = utf8.encode(password);
    final passwordBlob = calloc<Uint8>(passwordBytes.length);
    final credential = calloc<CREDENTIAL>();
    passwordBlob.asTypedList(passwordBytes.length).setAll(0, passwordBytes);
    credential.ref
      ..Type = CRED_TYPE_GENERIC
      ..TargetName = target
      ..Persist = CRED_PERSIST_LOCAL_MACHINE
      ..UserName = username
      ..CredentialBlob = passwordBlob
      ..CredentialBlobSize = passwordBytes.length;
    try {
      if (CredWrite(credential, 0) != TRUE) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
    } finally {
      // 释放前主动覆盖当前进程中的密码副本。
      passwordBlob
          .asTypedList(passwordBytes.length)
          .fillRange(0, passwordBytes.length, 0);
      calloc.free(credential);
      calloc.free(passwordBlob);
      calloc.free(username);
      calloc.free(target);
    }
  }

  @override
  void delete(SshConnectionConfig config) {
    _requireWindows();
    final target = _targetName(config).toNativeUtf16();
    try {
      if (CredDelete(target, CRED_TYPE_GENERIC, 0) != TRUE) {
        final error = GetLastError();
        // 删除操作保持幂等；部分 Windows 环境在目标不存在时返回 FALSE，
        // 但 LastError 仍为 ERROR_SUCCESS。
        if (error != ERROR_NOT_FOUND && error != ERROR_SUCCESS) {
          throw WindowsException(HRESULT_FROM_WIN32(error));
        }
      }
    } finally {
      calloc.free(target);
    }
  }
}
