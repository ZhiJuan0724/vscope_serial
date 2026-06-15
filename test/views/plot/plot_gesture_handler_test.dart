import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

    final plotCenter = tester.getCenter(find.byType(PlotGestureHandler));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: plotCenter);
    await gesture.down(plotCenter);
    await gesture.moveTo(plotCenter + Offset(deltaX, 0));
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
}
