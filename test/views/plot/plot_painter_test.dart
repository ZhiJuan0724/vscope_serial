import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  group('PlotLayerPainter', () {
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

      final widths = PlotLayerPainter.calculateOffsetAxisColumnWidths(
        viewport: viewport,
        channels: channels,
        activeChannelCount: channels.length,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: 0,
        yValuesAreInteger: true,
      );

      expect(widths, hasLength(1));
      expect(widths.single, greaterThan(PlotViewport.offsetAxisColumnWidth));
    });

    test('配置、网格和抗锯齿变化会触发重绘', () {
      final channels = [ChannelConfig(index: 0, color: Colors.red)];
      final data = [
        PlotDataPoint(index: 0, timestamp: 0, values: [1]),
      ];
      final oldPainter = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: PlotViewport(),
        data: data,
        channels: channels,
        channelConfigRevision: 1,
      );

      expect(
        PlotLayerPainter(
          layer: PlotPaintLayer.data,
          viewport: PlotViewport(),
          data: data,
          channels: channels,
          channelConfigRevision: 2,
        ).shouldRepaint(oldPainter),
        true,
      );

      final oldBackgroundPainter = PlotLayerPainter(
        layer: PlotPaintLayer.background,
        viewport: PlotViewport(),
        data: data,
        channels: channels,
      );
      expect(
        PlotLayerPainter(
          layer: PlotPaintLayer.background,
          viewport: PlotViewport(),
          data: data,
          channels: channels,
          gridDensity: GridDensity.dense,
        ).shouldRepaint(oldBackgroundPainter),
        true,
      );
      expect(
        PlotLayerPainter(
          layer: PlotPaintLayer.data,
          viewport: PlotViewport(),
          data: data,
          channels: channels,
          antiAliasEnabled: false,
        ).shouldRepaint(oldPainter),
        true,
      );
    });

    test('覆盖状态变化只要求覆盖层重绘', () {
      final channels = [ChannelConfig(index: 0, color: Colors.red)];
      final dataPainter = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: PlotViewport(),
        data: const [],
        channels: channels,
        overlayRevision: 1,
      );
      final nextDataPainter = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: PlotViewport(),
        data: const [],
        channels: channels,
        overlayRevision: 2,
      );
      final overlayPainter = PlotLayerPainter(
        layer: PlotPaintLayer.overlay,
        viewport: PlotViewport(),
        data: const [],
        channels: channels,
        overlayRevision: 1,
      );
      final nextOverlayPainter = PlotLayerPainter(
        layer: PlotPaintLayer.overlay,
        viewport: PlotViewport(),
        data: const [],
        channels: channels,
        overlayRevision: 2,
      );

      expect(nextDataPainter.shouldRepaint(dataPainter), false);
      expect(nextOverlayPainter.shouldRepaint(overlayPainter), true);
    });

    test('悬浮窗透明度变化只要求覆盖层重绘', () {
      final channels = [ChannelConfig(index: 0, color: Colors.red)];

      for (final layer in PlotPaintLayer.values) {
        final oldPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: const [],
          channels: channels,
          floatingPanelOpacity: 0.7,
        );
        final newPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: const [],
          channels: channels,
          floatingPanelOpacity: 0.9,
        );

        expect(
          newPainter.shouldRepaint(oldPainter),
          layer == PlotPaintLayer.overlay,
        );
      }
    });

    test('动态偏置轴宽度变化会触发重绘', () {
      final oldViewport = PlotViewport()..setOffsetAxisColumnWidths([42]);
      final newViewport = PlotViewport()..setOffsetAxisColumnWidths([96]);
      final channels = [ChannelConfig(index: 0, color: Colors.red)];
      final oldPainter = PlotLayerPainter(
        layer: PlotPaintLayer.axis,
        viewport: oldViewport,
        data: const [],
        channels: channels,
      );
      final newPainter = PlotLayerPainter(
        layer: PlotPaintLayer.axis,
        viewport: newViewport,
        data: const [],
        channels: channels,
      );

      expect(newPainter.shouldRepaint(oldPainter), true);
    });

    test('背景模式变化会触发各绘图层重绘', () {
      final channels = [ChannelConfig(index: 0, color: Colors.yellow)];
      final data = [
        PlotDataPoint(index: 0, timestamp: 0, values: [1]),
      ];

      for (final layer in PlotPaintLayer.values) {
        final oldPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: data,
          channels: channels,
          backgroundStyle: PlotBackgroundStyle.dark,
        );
        final newPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: data,
          channels: channels,
          backgroundStyle: PlotBackgroundStyle.light,
        );

        expect(newPainter.shouldRepaint(oldPainter), true);
      }
    });

    test('网格密度只改变Y刻度步长且不会被nice number合并', () {
      final xGridCount = PlotLayerPainter.debugXGridCountFor(800);
      final sparse = PlotLayerPainter.debugYTickStepFor(
        32768,
        510,
        GridDensity.sparse,
      );
      final normal = PlotLayerPainter.debugYTickStepFor(
        32768,
        510,
        GridDensity.normal,
      );
      final dense = PlotLayerPainter.debugYTickStepFor(
        32768,
        510,
        GridDensity.dense,
      );

      expect(sparse, greaterThan(normal));
      expect(normal, greaterThan(dense));
      expect(xGridCount, 10);
    });
  });
}
