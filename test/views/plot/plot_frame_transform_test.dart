import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/views/plot/plot_frame_transform.dart';
import 'package:vscope_serial/views/plot/plot_presentation_coordinator.dart';
import 'package:vscope_serial/views/plot/plot_render_snapshot.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  test('PlotFrameTransform逻辑和物理坐标与PlotViewport完全一致', () {
    final viewport = PlotViewport(xMin: 100, xMax: 900, yMin: -20, yMax: 80);
    for (final dpr in <double>[1, 1.25, 1.5, 2]) {
      final transform = PlotFrameTransform(
        frameId: 7,
        dataRevision: 3,
        geometryGeneration: 2,
        viewport: viewport,
        logicalSize: const Size(960, 540),
        devicePixelRatio: dpr,
      );

      for (final x in <double>[100, 350, 900]) {
        expect(transform.dataToLogicalX(x), viewport.dataToScreenX(x, 960));
        expect(
          transform.logicalToDataX(transform.dataToLogicalX(x)),
          closeTo(x, 1e-9),
        );
        final native = transform.physicalXTransform;
        expect(
          x * native.$1 + native.$2,
          closeTo(transform.dataToPhysicalX(x), 1e-6),
        );
      }
      for (final y in <double>[-20, 10, 80]) {
        expect(transform.dataToLogicalY(y), viewport.dataToScreenY(y, 540));
        expect(
          transform.logicalToDataY(transform.dataToLogicalY(y)),
          closeTo(y, 1e-9),
        );
        final native = transform.physicalYTransform;
        expect(
          y * native.$1 + native.$2,
          closeTo(transform.dataToPhysicalY(y), 1e-6),
        );
      }
    }
  });

  test('PlotPresentationCoordinator拒绝过期D3D11帧回跳', () {
    final coordinator = PlotPresentationCoordinator();
    addTearDown(coordinator.dispose);
    final first = _snapshot(PlotViewport(xMin: 0, xMax: 100));
    final latest = _snapshot(PlotViewport(xMin: 200, xMax: 300));

    coordinator.present(latest, frameId: 12);
    coordinator.present(first, frameId: 11);

    expect(coordinator.presentedFrameId, 12);
    expect(coordinator.presentedSnapshot, same(latest));
  });
}

PlotRenderSnapshot _snapshot(PlotViewport viewport) => PlotRenderSnapshot(
  viewport: viewport,
  data: const [],
  channels: <ChannelConfig>[
    ChannelConfig(index: 0, color: const Color(0xFFFF0000)),
  ],
);
