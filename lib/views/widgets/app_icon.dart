import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 应用自有 SVG 图标的集中注册表。
///
/// 资源名称只在此处维护，避免页面散落字符串路径，后续替换图标时可机械检查影响范围。
abstract final class AppIcons {
  static const plotMeasureXx = 'ic_plot_measure_xx';
  static const plotMeasureYy = 'ic_plot_measure_yy';
  static const plotZoomXIn = 'ic_plot_zoom_x_in';
  static const plotZoomXOut = 'ic_plot_zoom_x_out';
  static const plotZoomYIn = 'ic_plot_zoom_y_in';
  static const plotZoomYOut = 'ic_plot_zoom_y_out';
  static const plotFitX = 'ic_plot_fit_x';
  static const plotFitY = 'ic_plot_fit_y';
  static const plotFitAll = 'ic_plot_fit_all';
  static const plotImport = 'ic_plot_import';
  static const plotCursor = 'ic_plot_cursor_vertical';
  static const plotFollow = 'ic_plot_follow_latest';

  static const all = [
    plotMeasureXx,
    plotMeasureYy,
    plotZoomXIn,
    plotZoomXOut,
    plotZoomYIn,
    plotZoomYOut,
    plotFitX,
    plotFitY,
    plotFitAll,
    plotImport,
    plotCursor,
    plotFollow,
  ];
}

class AppIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const AppIcon(this.name, {super.key, this.size = 24, this.color});

  static String assetPath(String name) => 'assets/icons/$name.svg';

  static Future<void> precacheAll() async {
    await Future.wait(
      AppIcons.all.map(
        (name) => SvgAssetLoader(assetPath(name)).loadBytes(null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color;
    return SvgPicture.asset(
      assetPath(name),
      width: size,
      height: size,
      colorFilter:
          iconColor == null
              ? null
              : ColorFilter.mode(iconColor, BlendMode.srcIn),
    );
  }
}
