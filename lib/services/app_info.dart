import 'dart:io';

import 'package:flutter/services.dart';

class AppInfo {
  AppInfo._();

  static const name = 'SerialTools';
  static const _buildTimeValue = String.fromEnvironment('BUILD_TIME');
  static String? _cachedVersion;

  static Future<String> version() async {
    final cached = _cachedVersion;
    if (cached != null) return cached;

    try {
      final pubspec = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(
        r'^\s*version\s*:\s*([^\s#]+)',
        multiLine: true,
      ).firstMatch(pubspec);
      final version = match?.group(1)?.trim();
      if (version != null && version.isNotEmpty) {
        _cachedVersion = version;
        return version;
      }
    } catch (_) {
      // 在异常测试或工具上下文中资源不可用时，回退到稳定占位值。
    }

    const fallback = '0.0.0';
    _cachedVersion = fallback;
    return fallback;
  }

  static Future<String> displayVersion() async {
    final value = await version();
    return value.startsWith(RegExp(r'[vV]')) ? value : 'v$value';
  }

  static Future<DateTime?> buildTime() async {
    if (_buildTimeValue.isNotEmpty) {
      final parsed = DateTime.tryParse(_buildTimeValue);
      if (parsed != null) return parsed;
    }

    try {
      return File(Platform.resolvedExecutable).lastModified();
    } catch (_) {
      return null;
    }
  }
}
