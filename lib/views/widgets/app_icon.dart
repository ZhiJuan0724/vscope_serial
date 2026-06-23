import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Central registry for app-owned SVG icons.
///
/// Keep asset names here instead of scattering string paths through pages, so
/// future P1/P2 icon replacement can stay mechanical and easy to audit.
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
}

class AppIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const AppIcon(this.name, {super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color;
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter:
          iconColor == null
              ? null
              : ColorFilter.mode(iconColor, BlendMode.srcIn),
    );
  }
}
