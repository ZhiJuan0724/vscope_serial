import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  group('PlotPainter', () {
    test('offset axis width grows for long tick labels', () {
      final viewport = PlotViewport(yMin: 0, yMax: 100);
      final channels = [
        ChannelConfig(
          index: 0,
          color: Colors.yellow,
          offsetEnabled: true,
          yOffset: 75000,
        ),
      ];

      final widths = PlotPainter.calculateOffsetAxisColumnWidths(
        viewport: viewport,
        channels: channels,
        activeChannelCount: channels.length,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: 0,
      );

      expect(widths, hasLength(1));
      expect(widths.single, greaterThan(PlotViewport.offsetAxisColumnWidth));
    });
  });
}
