import 'dart:io';

import 'package:flutter/services.dart';

class AppInfo {
  AppInfo._();

  static const name = 'VScope Serial';
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
      // Fall through to a stable placeholder when assets are unavailable in
      // unusual test or tooling contexts.
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
    try {
      return File(Platform.resolvedExecutable).lastModified();
    } catch (_) {
      return null;
    }
  }
}
