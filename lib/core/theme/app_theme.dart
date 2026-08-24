import 'package:flutter/material.dart';

/// 应用级视觉主题，集中管理跨页面复用的基础颜色与字体。
abstract final class AppTheme {
  /// 页面、工具栏、浅色内容区和选中主标签共用的浅灰白背景。
  ///
  /// 相比纯白略微降低亮度，长时间查看时更柔和，同时保留足够的内容对比度。
  static const Color pageBackgroundColor = Color.fromARGB(255, 241, 241, 241);

  /// 构建应用统一使用的浅色主题。
  static ThemeData buildLightTheme() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(surface: pageBackgroundColor);
    final baseTheme = ThemeData(
      useMaterial3: false,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: pageBackgroundColor,
      canvasColor: pageBackgroundColor,
    );
    return baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'SarasaUiSC'),
      primaryTextTheme: baseTheme.primaryTextTheme.apply(
        fontFamily: 'SarasaUiSC',
      ),
    );
  }
}
