import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/data/models/plot_lod_index.dart';
import 'package:vscope_serial/data/models/plot_render_engine.dart';
import 'package:vscope_serial/views/plot/plot_layer_stack.dart';
import 'package:vscope_serial/views/plot/plot_render_snapshot.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

const _channel = MethodChannel('vscope_serial/plot_gpu_renderer');
const _outputDirectory = String.fromEnvironment(
  'PLOT_BENCHMARK_OUTPUT_DIR',
  defaultValue: 'build/performance',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('D3D11保持正弦包络并保留孤立尖峰真实位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sine = _buildIndex(
      80000,
      (index) => math.sin(index * math.pi * 2 / 20000) * 1000,
    );
    final sineFrame = await _renderAndCapture(
      tester,
      name: 'd3d11-sine-correctness',
      index: sine,
      viewport: PlotViewport(xMin: 0, xMax: 79999, yMin: -1200, yMax: 1200),
    );
    _expectSineEnvelope(sineFrame);

    final spike = _buildIndex(80000, (index) => index == 40000 ? 10000 : 0);
    final spikeFrame = await _renderAndCapture(
      tester,
      name: 'd3d11-isolated-spike-correctness',
      index: spike,
      viewport: PlotViewport(xMin: 0, xMax: 79999, yMin: -1000, yMax: 11000),
    );
    _expectNarrowSpike(spikeFrame);

    // 低密度数据应同时绘制细线和方形点。水平线本身在采样位置附近
    // 只有一条窄带，因此可以通过局部着色面积确认点图元确实存在。
    final markers = _buildIndex(17, (_) => 0);
    final markerFrame = await _renderAndCapture(
      tester,
      name: 'd3d11-point-markers-correctness',
      index: markers,
      data: List<PlotDataPoint>.generate(
        17,
        (index) => PlotDataPoint(
          index: index,
          timestamp: index.toDouble(),
          values: const <double>[0],
        ),
      ),
      viewport: PlotViewport(xMin: 0, xMax: 16, yMin: -10, yMax: 10),
      lineWidth: 1,
      pointSize: 7,
    );
    _expectSquarePointMarkers(markerFrame, 17);

    // 反复改变外部纹理尺寸，覆盖窗口拉伸时的共享句柄重建路径。
    for (final size in const <Size>[
      Size(640, 360),
      Size(1024, 600),
      Size(800, 420),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pump(const Duration(milliseconds: 150));
      final resized = await _channel.invokeMapMethod<String, Object?>(
        'capture',
      );
      expect(resized?['width'], size.width.toInt());
      expect(resized?['height'], size.height.toInt());
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}

PlotLodIndex _buildIndex(int length, double Function(int index) valueAt) {
  final result = PlotLodIndex();
  for (var index = 0; index < length; index++) {
    result.add(index, <double>[valueAt(index)]);
  }
  return result;
}

Future<_CapturedFrame> _renderAndCapture(
  WidgetTester tester, {
  required String name,
  required PlotLodIndex index,
  required PlotViewport viewport,
  List<PlotDataPoint> data = const <PlotDataPoint>[],
  double lineWidth = 1.5,
  double pointSize = 3,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlotLayerStack(
          snapshot: PlotRenderSnapshot(
            viewport: viewport,
            data: data,
            dataRevision: 1,
            lodIndex: index,
            lodQuality: PlotLodQuality.quality,
            renderEngine: PlotRenderEngine.d3d11,
            devicePixelRatio: 1,
            channels: <ChannelConfig>[
              ChannelConfig(
                index: 0,
                color: const Color(0xFFFF0000),
                lineWidth: lineWidth,
                pointSize: pointSize,
              ),
            ],
            activeChannelCount: 1,
            showGrid: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 100));
  final response = await _channel.invokeMapMethod<String, Object?>('capture');
  expect(response, isNotNull);
  final frame = _CapturedFrame(
    width: response!['width']! as int,
    height: response['height']! as int,
    pixels: response['pixels']! as Uint8List,
    viewport: viewport,
  );
  await _writePng(name, frame);
  return frame;
}

void _expectSineEnvelope(_CapturedFrame frame) {
  var coloredPixels = 0;
  final populatedColumns = <int>{};
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      if (!frame.isColored(x, y)) continue;
      coloredPixels++;
      populatedColumns.add(x);
      final dataStart = frame.viewport.screenToDataX(
        (x - 3).toDouble(),
        frame.width.toDouble(),
      );
      final dataEnd = frame.viewport.screenToDataX(
        (x + 3).toDouble(),
        frame.width.toDouble(),
      );
      var minimum = double.infinity;
      var maximum = double.negativeInfinity;
      final first = dataStart.floor().clamp(0, 79999);
      final last = dataEnd.ceil().clamp(0, 79999);
      for (var index = first; index <= last; index++) {
        final value = math.sin(index * math.pi * 2 / 20000) * 1000;
        minimum = math.min(minimum, value);
        maximum = math.max(maximum, value);
      }
      final value = frame.viewport.screenToDataY(
        y.toDouble(),
        frame.height.toDouble(),
      );
      // 两个像素的抗锯齿/线宽余量；其余像素必须处于原始数据包络内。
      final tolerance = frame.viewport.yRange / frame.height * 5;
      expect(value, inInclusiveRange(minimum - tolerance, maximum + tolerance));
    }
  }
  expect(coloredPixels, greaterThan(1000));
  expect(
    populatedColumns.length,
    greaterThan(
      (frame.viewport.plotWidth(frame.width.toDouble()) * 0.9).floor(),
    ),
  );
}

void _expectNarrowSpike(_CapturedFrame frame) {
  final baselineY = frame.viewport.dataToScreenY(0, frame.height.toDouble());
  final spikeX = frame.viewport.dataToScreenX(40000, frame.width.toDouble());
  var peakSeen = false;
  var offBaselineColumns = <int>{};
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      if (!frame.isColored(x, y)) continue;
      if ((y - baselineY).abs() > 4) {
        offBaselineColumns.add(x);
        expect((x - spikeX).abs(), lessThanOrEqualTo(3));
      }
      final value = frame.viewport.screenToDataY(
        y.toDouble(),
        frame.height.toDouble(),
      );
      if (value > 9000) peakSeen = true;
    }
  }
  expect(peakSeen, isTrue);
  expect(offBaselineColumns.length, lessThanOrEqualTo(7));
}

void _expectSquarePointMarkers(_CapturedFrame frame, int pointCount) {
  final centerY = frame.viewport.dataToScreenY(0, frame.height.toDouble());
  for (var point = 1; point < pointCount - 1; point++) {
    final centerX = frame.viewport.dataToScreenX(
      point.toDouble(),
      frame.width.toDouble(),
    );
    var coloredPixels = 0;
    for (var y = centerY.round() - 4; y <= centerY.round() + 4; y++) {
      for (var x = centerX.round() - 4; x <= centerX.round() + 4; x++) {
        if (x < 0 || x >= frame.width || y < 0 || y >= frame.height) continue;
        if (frame.isColored(x, y)) coloredPixels++;
      }
    }
    // 1px水平线在9x9区域内最多覆盖约两行；7px方点应明显更大。
    expect(coloredPixels, greaterThan(24), reason: '采样点$point附近未检测到方形点标记');
  }
}

Future<void> _writePng(String name, _CapturedFrame frame) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    frame.pixels,
    frame.width,
    frame.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final directory = Directory(_outputDirectory);
  await directory.create(recursive: true);
  await File(
    '${directory.path}/$name.png',
  ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
}

class _CapturedFrame {
  const _CapturedFrame({
    required this.width,
    required this.height,
    required this.pixels,
    required this.viewport,
  });

  final int width;
  final int height;
  final Uint8List pixels;
  final PlotViewport viewport;

  bool isColored(int x, int y) {
    final offset = (y * width + x) * 4;
    return pixels[offset + 3] > 24 && pixels[offset] > 24;
  }
}
