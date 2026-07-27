import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';
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
        plotFontBold: false,
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

    test('测量线颜色和不透明度变化只要求覆盖层重绘', () {
      final channels = [ChannelConfig(index: 0, color: Colors.red)];

      for (final layer in PlotPaintLayer.values) {
        final oldPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: const [],
          channels: channels,
          xMeasurementLine1Color: Colors.cyan,
          xMeasurementLine1Opacity: 1,
        );
        final newPainter = PlotLayerPainter(
          layer: layer,
          viewport: PlotViewport(),
          data: const [],
          channels: channels,
          xMeasurementLine1Color: Colors.purple,
          xMeasurementLine1Opacity: 0.4,
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

    test('X轴按规则数值生成刻度并随范围移动', () {
      expect(PlotLayerPainter.debugXTickValuesFor(0, 9, 720), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
      ]);
      expect(PlotLayerPainter.debugXTickValuesFor(0, 90, 720), [
        0,
        10,
        20,
        30,
        40,
        50,
        60,
        70,
        80,
        90,
      ]);
      expect(PlotLayerPainter.debugXTickValuesFor(10, 18, 320), [
        10,
        12,
        14,
        16,
        18,
      ]);
      expect(PlotLayerPainter.debugXTickValuesFor(13, 93, 720), [
        20,
        30,
        40,
        50,
        60,
        70,
        80,
        90,
      ]);
    });

    test('网格密度通过调整规则刻度间距改变格子数量', () {
      final xGridCount = PlotLayerPainter.debugXGridCountFor(800);
      final sparseX = PlotLayerPainter.debugXTickValuesFor(
        0,
        100,
        800,
        gridDensity: GridDensity.sparse,
      );
      final normalX = PlotLayerPainter.debugXTickValuesFor(0, 100, 800);
      final denseX = PlotLayerPainter.debugXTickValuesFor(
        0,
        100,
        800,
        gridDensity: GridDensity.dense,
      );
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
      expect(sparseX.length, lessThan(normalX.length));
      expect(normalX.length, lessThan(denseX.length));
      expect(xGridCount, 10);
    });

    test('大范围X轴向上调整规则步长避免长标签重叠', () {
      final ticks = PlotLayerPainter.debugXTickValuesFor(
        0,
        250000,
        1545,
        gridDensity: GridDensity.dense,
        minimumSpacing: 48,
      );

      expect(ticks[1] - ticks[0], 10000);
      final pixelSpacing = 1545 * (ticks[1] - ticks[0]) / 250000;
      expect(pixelSpacing, greaterThanOrEqualTo(48));
    });

    test('偏置Y轴在通道原始值域生成整数规则刻度', () {
      final ticks = PlotLayerPainter.debugOffsetAxisTickValuesFor(
        viewport: PlotViewport(yMin: 0, yMax: 20),
        channel: ChannelConfig(
          index: 0,
          color: Colors.red,
          yScale: 3,
          yOffset: 0.7,
          offsetEnabled: true,
        ),
        plotHeight: 500,
      );

      expect(ticks, [0, 1, 2, 3, 4, 5, 6]);
      expect(ticks.every((value) => value == value.roundToDouble()), isTrue);
    });

    test('浮点通道主Y轴最大放大时仍使用整数步长', () {
      final step = PlotLayerPainter.debugYTickStepFor(
        1,
        510,
        GridDensity.dense,
        yValuesAreInteger: true,
      );

      expect(step, 1);
    });

    test('左侧Y轴宽度随刻度文本和字体大小自适应', () {
      final viewport = PlotViewport(yMin: -100000000, yMax: 100000000);
      final smallWidth = PlotLayerPainter.calculateLeftAxisWidth(
        viewport: viewport,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: -3,
        plotFontBold: false,
      );
      final largeWidth = PlotLayerPainter.calculateLeftAxisWidth(
        viewport: viewport,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: 6,
        plotFontBold: false,
      );

      expect(smallWidth, greaterThanOrEqualTo(PlotViewport.defaultMarginLeft));
      expect(largeWidth, greaterThan(smallWidth));
    });

    test('左侧Y轴宽度会计入粗体文本宽度', () {
      final viewport = PlotViewport(yMin: -100000000, yMax: 100000000);
      final normalWidth = PlotLayerPainter.calculateLeftAxisWidth(
        viewport: viewport,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: 1,
        plotFontBold: false,
      );
      final boldWidth = PlotLayerPainter.calculateLeftAxisWidth(
        viewport: viewport,
        canvasHeight: 600,
        gridDensity: GridDensity.normal,
        plotFontSizeDelta: 1,
        plotFontBold: true,
      );

      expect(boldWidth, greaterThanOrEqualTo(normalWidth));
    });

    test('绘图字号在用户选择值基础上内部增加1', () {
      expect(PlotLayerPainter.debugFontSizeFor(12, -1), 12);
      expect(PlotLayerPainter.debugFontSizeFor(12, 0), 13);
      expect(PlotLayerPainter.debugFontSizeFor(12, 1), 14);
    });

    test('均衡和质量优先在完整中等密度窗口使用精确像素桶', () {
      final lod = PlotLodIndex();
      final data = <PlotDataPoint>[];
      for (var i = 0; i < 650; i++) {
        final value = math.sin(i / 31) * 40 + 50;
        lod.add(i, [value]);
        data.add(
          PlotDataPoint(index: i, timestamp: i.toDouble(), values: [value]),
        );
      }
      final channels = [ChannelConfig(index: 0, color: Colors.red)];
      final viewport = PlotViewport(xMin: 0, xMax: 649, yMin: 0, yMax: 100);

      final performance = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: viewport,
        data: data,
        lodIndex: lod,
        channels: channels,
        activeChannelCount: 1,
      );
      final balanced = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: viewport,
        data: data,
        lodIndex: lod,
        lodQuality: PlotLodQuality.balanced,
        channels: channels,
        activeChannelCount: 1,
      );
      final quality = PlotLayerPainter(
        layer: PlotPaintLayer.data,
        viewport: viewport,
        data: data,
        lodIndex: lod,
        lodQuality: PlotLodQuality.quality,
        channels: channels,
        activeChannelCount: 1,
      );

      expect(
        performance.debugUsesExactQualityBuckets(const Size(500, 300)),
        isFalse,
      );
      expect(
        balanced.debugUsesExactQualityBuckets(const Size(500, 300)),
        isTrue,
      );
      expect(
        quality.debugUsesExactQualityBuckets(const Size(500, 300)),
        isTrue,
      );
      expect(balanced.shouldRepaint(performance), isTrue);
      expect(quality.shouldRepaint(performance), isTrue);
    });

    testWidgets('精确窗口为空时仍使用LOD绘制数据', (tester) async {
      final lod = PlotLodIndex();
      for (var i = 0; i < 20000; i++) {
        lod.add(i, [math.sin(i / 31) * 40 + 50]);
      }

      final paintedPixels = await tester.runAsync(() async {
        const size = Size(280, 120);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        PlotLayerPainter(
          layer: PlotPaintLayer.data,
          viewport: PlotViewport(xMin: 3500, xMax: 16500, yMin: 0, yMax: 100),
          data: const [],
          lodIndex: lod,
          channels: [ChannelConfig(index: 0, color: Colors.red)],
          activeChannelCount: 1,
        ).paint(canvas, size);

        final image = await recorder.endRecording().toImage(280, 120);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        var count = 0;
        for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) != 0) count++;
        }
        image.dispose();
        return count;
      });

      expect(paintedPixels, greaterThan(0));
    });

    testWidgets('小范围视口换载期间使用粗略LOD避免空白', (tester) async {
      final lod = PlotLodIndex();
      for (var i = 0; i < 20000; i++) {
        lod.add(i, [math.sin(i / 31) * 40 + 50]);
      }

      final paintedPixels = await tester.runAsync(() async {
        const size = Size(900, 180);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        PlotLayerPainter(
          layer: PlotPaintLayer.data,
          viewport: PlotViewport(xMin: 3500, xMax: 3650, yMin: 0, yMax: 100),
          data: const [],
          lodIndex: lod,
          channels: [ChannelConfig(index: 0, color: Colors.red)],
          activeChannelCount: 1,
        ).paint(canvas, size);

        final image = await recorder.endRecording().toImage(900, 180);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        var count = 0;
        for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) != 0) count++;
        }
        image.dispose();
        return count;
      });

      expect(paintedPixels, greaterThan(0));
    });

    testWidgets('粗略LOD的边界连线不会绘制到主绘图区域外', (tester) async {
      final lod = PlotLodIndex();
      for (var i = 0; i < 20000; i++) {
        lod.add(i, [math.sin(i / 31) * 40 + 50]);
      }

      final counts = await tester.runAsync(() async {
        const width = 900;
        const height = 180;
        const size = Size(900, 180);
        final viewport = PlotViewport(
          xMin: 3500,
          xMax: 3650,
          yMin: 0,
          yMax: 100,
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        PlotLayerPainter(
          layer: PlotPaintLayer.data,
          viewport: viewport,
          data: const [],
          lodIndex: lod,
          channels: [ChannelConfig(index: 0, color: Colors.red)],
          activeChannelCount: 1,
        ).paint(canvas, size);

        final image = await recorder.endRecording().toImage(width, height);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        var inside = 0;
        var outside = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final alpha = bytes!.getUint8((y * width + x) * 4 + 3);
            if (alpha == 0) continue;
            final inPlot =
                x >= viewport.marginLeft &&
                x < width - viewport.marginRight &&
                y >= viewport.marginTop &&
                y < height - viewport.marginBottom;
            if (inPlot) {
              inside++;
            } else {
              outside++;
            }
          }
        }
        image.dispose();
        return (inside: inside, outside: outside);
      });

      expect(counts!.inside, greaterThan(0));
      expect(counts.outside, 0);
    });

    testWidgets('快速换窗时悬停光标和提示框不会绘制到主绘图区域外', (tester) async {
      final counts = await tester.runAsync(() async {
        const width = 320;
        const height = 180;
        const size = Size(320, 180);
        final viewport = PlotViewport(xMin: 0, xMax: 100, yMin: 0, yMax: 100);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        PlotLayerPainter(
          layer: PlotPaintLayer.overlay,
          viewport: viewport,
          data: const [],
          channels: [ChannelConfig(index: 0, color: Colors.red)],
          activeChannelCount: 1,
          cursor: CursorState(
            x: 50,
            y: 50,
            screenPosition: const Offset(310, 175),
            channelValues: const [50],
          ),
        ).paint(canvas, size);

        final image = await recorder.endRecording().toImage(width, height);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        var inside = 0;
        var outside = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final alpha = bytes!.getUint8((y * width + x) * 4 + 3);
            if (alpha == 0) continue;
            final inPlot =
                x >= viewport.marginLeft &&
                x < width - viewport.marginRight &&
                y >= viewport.marginTop &&
                y < height - viewport.marginBottom;
            if (inPlot) {
              inside++;
            } else {
              outside++;
            }
          }
        }
        image.dispose();
        return (inside: inside, outside: outside);
      });

      expect(counts!.inside, greaterThan(0));
      expect(counts.outside, 0);
    });

    testWidgets('快速换窗后视口外的旧悬停光标不再绘制', (tester) async {
      final paintedPixels = await tester.runAsync(() async {
        const width = 320;
        const height = 180;
        const size = Size(320, 180);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        PlotLayerPainter(
          layer: PlotPaintLayer.overlay,
          viewport: PlotViewport(xMin: 1000, xMax: 1100, yMin: 0, yMax: 100),
          data: const [],
          channels: [ChannelConfig(index: 0, color: Colors.red)],
          activeChannelCount: 1,
          cursor: CursorState(
            x: 50,
            y: 50,
            screenPosition: const Offset(160, 90),
            channelValues: const [50],
          ),
        ).paint(canvas, size);

        final image = await recorder.endRecording().toImage(width, height);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        var count = 0;
        for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) != 0) count++;
        }
        image.dispose();
        return count;
      });

      expect(paintedPixels, 0);
    });
  });
}
