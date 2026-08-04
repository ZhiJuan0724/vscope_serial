import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/views/plot/plot_gesture_handler.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';
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

  testWidgets('框选模式忽略单击和过薄选区', (tester) async {
    var viewport = initialViewport;
    var updateCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              boxZoomEnabled: true,
              onViewportChanged: (value, {fromDrag = false}) {
                viewport = value;
                updateCount++;
              },
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(PlotGestureHandler));
    final click = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await click.addPointer(location: center);
    await click.down(center);
    await click.up();
    await click.removePointer();

    final thin = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await thin.addPointer(location: center);
    await thin.down(center);
    await thin.moveTo(center + const Offset(120, 2));
    await thin.up();
    await thin.removePointer();
    await tester.pump();

    expect(updateCount, 0);
    expect(viewport.xMin, initialViewport.xMin);
    expect(viewport.xMax, initialViewport.xMax);
    expect(viewport.yMin, initialViewport.yMin);
    expect(viewport.yMax, initialViewport.yMax);
  });

  testWidgets('有效框选完成后通知调用方关闭单次模式', (tester) async {
    var updateCount = 0;
    var completionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              boxZoomEnabled: true,
              onViewportChanged: (_, {fromDrag = false}) => updateCount++,
              onBoxZoomCompleted: () => completionCount++,
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(PlotGestureHandler));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: center);
    await gesture.down(center);
    await gesture.moveTo(center + const Offset(120, 80));
    await gesture.up();
    await tester.pump();

    expect(updateCount, 1);
    expect(completionCount, 1);
  });

  testWidgets('框选模式下右键拖动仍平移视口', (tester) async {
    var viewport = initialViewport;
    var completionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              boxZoomEnabled: true,
              onViewportChanged: (value, {fromDrag = false}) {
                viewport = value;
              },
              onBoxZoomCompleted: () => completionCount++,
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(PlotGestureHandler));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: center);
    await gesture.down(center);
    await gesture.moveTo(center + const Offset(100, 60));
    await gesture.up();
    await tester.pump();

    expect(viewport.xMin, lessThan(initialViewport.xMin));
    expect(viewport.yMin, greaterThan(initialViewport.yMin));
    expect(completionCount, 0);
  });

  testWidgets('Y 测量关闭吸附后按指针数据位置拖动', (tester) async {
    double? draggedY;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (_, {fromDrag = false}) {},
              onCursorChanged: (_) {},
              channels: const [],
              data: [
                PlotDataPoint(index: 0, timestamp: 0, values: [80]),
              ],
              yCursor1: 0,
              yMeasurementSnapEnabled: false,
              onYCursor1Drag: (value) => draggedY = value,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final handler = find.byType(PlotGestureHandler);
    final topLeft = tester.getTopLeft(handler);
    final start =
        topLeft +
        Offset(
          initialViewport.marginLeft - 18,
          initialViewport.dataToScreenY(0, 600),
        );
    final target =
        topLeft +
        Offset(
          initialViewport.marginLeft - 18,
          initialViewport.dataToScreenY(30, 600),
        );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveTo(target);
    await gesture.up();
    await tester.pump();

    expect(draggedY, closeTo(30, 0.001));
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

  testWidgets('offset binding group shares one Y axis column', (tester) async {
    final viewport = initialViewport.copy();
    viewport.setOffsetAxisColumnWidths(const [42]);
    int? draggedIndex;
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
                  offsetBindingGroupId: 1,
                ),
                ChannelConfig(
                  index: 1,
                  color: Colors.green,
                  offsetEnabled: true,
                  yOffset: 30,
                  offsetBindingGroupId: 1,
                ),
              ],
              activeChannelCount: 2,
              onChannelOffsetDrag: (index, yOffset) {
                draggedIndex = index;
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

    expect(draggedIndex, 0);
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

  testWidgets('连续光标 hover 每帧只回调最后一个位置', (tester) async {
    final cursors = <CursorState>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (_, {fromDrag = false}) {},
              onCursorChanged: (cursor) {
                if (cursor != null) cursors.add(cursor);
              },
              vCursorEnabled: true,
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: topLeft + const Offset(100, 200));
    for (var x = 101.0; x <= 700; x++) {
      await gesture.moveTo(topLeft + Offset(x, 200));
    }

    expect(cursors, isEmpty);
    await tester.pump();
    expect(cursors, hasLength(1));
    expect(cursors.single.screenPosition!.dx, closeTo(700, 0.001));
  });

  Future<void> pumpObservationGestureHarness(
    WidgetTester tester, {
    required bool locked,
    required void Function(int index, double x) onDrag,
    required void Function(int index) onDelete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: PlotGestureHandler(
              viewport: initialViewport,
              onViewportChanged: (_, {fromDrag = false}) {},
              onCursorChanged: (_) {},
              observations: [
                PlotObservation(cursor: CursorState(x: 500), locked: locked),
              ],
              onObservationDrag: onDrag,
              onObservationDelete: onDelete,
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('锁定观察在绘图区不能右键删除也不能拖动', (tester) async {
    var dragCount = 0;
    var deleteCount = 0;
    await pumpObservationGestureHarness(
      tester,
      locked: true,
      onDrag: (_, _) => dragCount++,
      onDelete: (_) => deleteCount++,
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final observationHandle = topLeft + const Offset(400, 20);

    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.addPointer(location: observationHandle);
    await secondary.down(observationHandle);
    await secondary.up();
    await secondary.removePointer();

    final primary = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await primary.addPointer(location: observationHandle);
    await primary.down(observationHandle);
    await primary.moveTo(observationHandle + const Offset(80, 0));
    await primary.up();
    await primary.removePointer();
    await tester.pump();

    expect(deleteCount, 0);
    expect(dragCount, 0);
  });

  testWidgets('未锁定观察在绘图区仍可右键删除和拖动', (tester) async {
    var dragCount = 0;
    var deleteCount = 0;
    await pumpObservationGestureHarness(
      tester,
      locked: false,
      onDrag: (_, _) => dragCount++,
      onDelete: (_) => deleteCount++,
    );

    final topLeft = tester.getTopLeft(find.byType(PlotGestureHandler));
    final observationHandle = topLeft + const Offset(400, 20);

    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.addPointer(location: observationHandle);
    await secondary.down(observationHandle);
    await secondary.up();
    await secondary.removePointer();

    final primary = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await primary.addPointer(location: observationHandle);
    await primary.down(observationHandle);
    await primary.moveTo(observationHandle + const Offset(80, 0));
    await primary.up();
    await primary.removePointer();
    await tester.pump();

    expect(deleteCount, 1);
    expect(dragCount, greaterThan(0));
  });

  testWidgets('触控板双指移动平移视口并在结束后保存', (tester) async {
    var viewport = initialViewport;
    final fromDragValues = <bool>[];
    var dragEndCount = 0;

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
                fromDragValues.add(fromDrag);
              },
              onDragEnd: () => dragEndCount++,
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(PlotGestureHandler));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(center);
    await gesture.panZoomUpdate(center, pan: const Offset(80, -40), scale: 1);
    await gesture.panZoomEnd();
    await tester.pump();

    expect(viewport.xRange, initialViewport.xRange);
    expect(viewport.yRange, initialViewport.yRange);
    expect(viewport.xMin, isNot(initialViewport.xMin));
    expect(viewport.yMin, isNot(initialViewport.yMin));
    expect(fromDragValues, isNotEmpty);
    expect(fromDragValues.every((value) => value), isTrue);
    expect(dragEndCount, 1);
  });

  testWidgets('触控板累计捏合比例按增量缩放且不标记为拖动', (tester) async {
    var viewport = initialViewport;
    final fromDragValues = <bool>[];
    var dragEndCount = 0;

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
                fromDragValues.add(fromDrag);
              },
              onDragEnd: () => dragEndCount++,
              onCursorChanged: (_) {},
              channels: const [],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(PlotGestureHandler));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(center);
    await gesture.panZoomUpdate(center, scale: 1.2);
    await gesture.panZoomUpdate(center, scale: 2);
    await gesture.panZoomEnd();
    await tester.pump();

    expect(viewport.xRange, closeTo(initialViewport.xRange / 2, 0.001));
    expect(viewport.yRange, closeTo(initialViewport.yRange / 2, 0.001));
    expect(fromDragValues, isNotEmpty);
    expect(fromDragValues.every((value) => !value), isTrue);
    expect(dragEndCount, 0);
  });
}
