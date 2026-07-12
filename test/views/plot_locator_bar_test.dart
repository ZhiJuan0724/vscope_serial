import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/plot/plot_locator_bar.dart';
import 'package:vscope_serial/views/plot/plot_viewport.dart';

void main() {
  test('定位条仅在 X 窗口或数据范围变化时重绘', () {
    final bar = PlotLocatorBarPainter(pointCount: 100, xMin: 10, xMax: 20);
    final sameBar = PlotLocatorBarPainter(pointCount: 100, xMin: 10, xMax: 20);
    final movedBar = PlotLocatorBarPainter(pointCount: 100, xMin: 30, xMax: 40);

    expect(bar.shouldRepaint(sameBar), isFalse);
    expect(movedBar.shouldRepaint(bar), isTrue);
  });

  testWidgets('定位条拖动提交最新位置', (tester) async {
    final navigations = <double>[];
    var dragEndCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 44,
              child: PlotLocatorBar(
                pointCount: 100,
                viewport: PlotViewport(xMin: 10, xMax: 20, yMin: 0, yMax: 1),
                onNavigate:
                    (centerX, {required fromDrag}) => navigations.add(centerX),
                onDragEnd: () => dragEndCount++,
              ),
            ),
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byType(PlotLocatorBar));
    final gesture = await tester.startGesture(topLeft + const Offset(50, 22));
    await gesture.moveTo(topLeft + const Offset(70, 22));
    await gesture.moveTo(topLeft + const Offset(90, 22));
    await tester.pump();

    expect(navigations, hasLength(1));
    expect(navigations.single, closeTo(22.275, 0.01));

    await gesture.up();
    await tester.pump();
    expect(dragEndCount, 1);
  });
}
