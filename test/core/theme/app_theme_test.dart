import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/theme/app_theme.dart';

void main() {
  test('浅色主题的页面与表面使用统一的非纯白背景', () {
    final theme = AppTheme.buildLightTheme();

    expect(theme.scaffoldBackgroundColor, AppTheme.pageBackgroundColor);
    expect(theme.canvasColor, AppTheme.pageBackgroundColor);
    expect(theme.colorScheme.surface, AppTheme.pageBackgroundColor);
    expect(AppTheme.pageBackgroundColor, isNot(Colors.white));
  });
}
