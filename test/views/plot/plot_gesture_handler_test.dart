import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/views/plot/plot_gesture_handler.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  final initialViewport = PlotViewport(
    xMin: 0,
    xMax: 1000,
    yMin: -100,
    yMax: 100,
  );

  Future<PlotViewport> shiftDrag(
    WidgetTester tester, {
    required double deltaX,
    double deltaY = 0,
    Offset? localStart,
  }) async {
    var viewport = initialViewport;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (value, {fromDrag = false}) {
                viewport = value;
              },
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final plotCenter =
        localStart == null
            ? tester.getCenter(find.byType(PlotGestureHandler))
            : topLeft + localStart;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: plotCenter);
    await gesture.down(plotCenter);
    await gesture.moveTo(plotCenter + Offset(deltaX, deltaY));
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    return viewport;
  }

  testWidgets('Shift + right drag zooms in on the X axis', (tester) async {
    final viewport = await shiftDrag(tester, deltaX: 120);

    expect(viewport.xRange, lessThan(initialViewport.xRange));
    expect(viewport.yMin, initialViewport.yMin);
    expect(viewport.yMax, initialViewport.yMax);
  });

  testWidgets('Shift + left drag zooms out on the X axis', (tester) async {
    final viewport = await shiftDrag(tester, deltaX: -120);

    expect(viewport.xRange, greaterThan(initialViewport.xRange));
    expect(viewport.yMin, initialViewport.yMin);
    expect(viewport.yMax, initialViewport.yMax);
  });

  testWidgets('Shift + drag on Y axis locks to Y zoom', (tester) async {
    final viewport = await shiftDrag(
      tester,
      localStart: const Offset(30, 300),
      deltaX: 120,
      deltaY: -120,
    );

    expect(viewport.xMin, initialViewport.xMin);
    expect(viewport.xMax, initialViewport.xMax);
    expect(viewport.yRange, lessThan(initialViewport.yRange));
  });

  testWidgets('Shift + diagonal drag in plot area keeps X zoom locked', (
    tester,
  ) async {
    final viewport = await shiftDrag(tester, deltaX: 140, deltaY: -80);

    expect(viewport.xRange, lessThan(initialViewport.xRange));
    expect(viewport.yMin, initialViewport.yMin);
    expect(viewport.yMax, initialViewport.yMax);
  });

  testWidgets('Shift + vertical drag in plot area locks to Y zoom', (
    tester,
  ) async {
    final viewport = await shiftDrag(tester, deltaX: 60, deltaY: -140);

    expect(viewport.xMin, initialViewport.xMin);
    expect(viewport.xMax, initialViewport.xMax);
    expect(viewport.yRange, lessThan(initialViewport.yRange));
  });

  testWidgets('dragging offset Y axis column updates channel offset', (
    tester,
  ) async {
    final viewport = initialViewport.copy();
    viewport.setOffsetAxisColumnWidths(const [42]);
    double? offset;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: viewport,
              onViewportChanged: (_, {fromDrag = false}) {},
              onCursorChanged: (_) {},
              channels: [
                ChannelConfig(
                  index: 0,
                  color: Colors.red,
                  offsetEnabled: true,
                  yOffset: 30,
                ),
              ],
              activeChannelCount: 1,
              onChannelOffsetDrag: (index, yOffset) {
                expect(index, 0);
                offset = yOffset;
              },
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final start = topLeft + const Offset(750, 300);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveTo(start + const Offset(0, -80));
    await gesture.up();
    await tester.pump();

    expect(offset, isNotNull);
    expect(offset!, greaterThan(30));
  });

  testWidgets('Shift + wheel keeps its existing X and Y zoom behavior', (
    tester,
  ) async {
    var viewport = initialViewport;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (value, {fromDrag = false}) {
                viewport = value;
              },
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final plotCenter = tester.getCenter(find.byType(PlotGestureHandler));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: plotCenter,
        scrollDelta: const Offset(0, -20),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(viewport.xRange, lessThan(initialViewport.xRange));
    expect(viewport.yRange, lessThan(initialViewport.yRange));
  });

  testWidgets('观察定位模式悬停预览并由左键提交', (tester) async {
    double? hoverX;
    double? commitX;
    var viewportChanged = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (_, {fromDrag = false}) {
                viewportChanged = true;
              },
              onCursorChanged: (_) {},
              observationPlacementActive: true,
              onObservationPlacementHover: (x) => hoverX = x,
              onObservationPlacementCommit: (x) => commitX = x,
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final hoverPosition = topLeft + const Offset(320, 240);
    final commitPosition = topLeft + const Offset(480, 240);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: hoverPosition);
    await gesture.moveTo(hoverPosition + const Offset(1, 0));
    await tester.pump();

    expect(hoverX, isNotNull);
    final initialHoverX = hoverX!;

    await gesture.moveTo(commitPosition);
    await gesture.down(commitPosition);
    await gesture.up();
    await tester.pump();

    expect(commitX, isNotNull);
    expect(commitX, greaterThan(initialHoverX));
    expect(commitX, hoverX);
    expect(viewportChanged, isFalse);
  });
}
