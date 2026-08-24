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

  test('定位条两端为选区描边保留可视空间', () {
    const size = Size(400, 44);
    final leftFrame =
        PlotLocatorBarPainter(
          pointCount: 100,
          xMin: 0,
          xMax: 1,
        ).frameRectForSize(size)!;
    final rightFrame =
        PlotLocatorBarPainter(
          pointCount: 100,
          xMin: 98,
          xMax: 99,
        ).frameRectForSize(size)!;

    expect(leftFrame.left, kPlotLocatorHorizontalPadding);
    expect(rightFrame.right, size.width - kPlotLocatorHorizontalPadding);
    expect(leftFrame.width, greaterThanOrEqualTo(8));
    expect(rightFrame.width, greaterThanOrEqualTo(8));
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

    expect(navigations, isNotEmpty);
    expect(navigations.last, closeTo(21.433, 0.01));

    await gesture.up();
    await tester.pump();
    expect(dragEndCount, 1);
  });

  testWidgets('定位条可从当前窗口块以外直接开始拖动', (tester) async {
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
                viewport: PlotViewport(xMin: 10, xMax: 11, yMin: 0, yMax: 1),
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
    final gesture = await tester.startGesture(topLeft + const Offset(300, 22));
    await gesture.moveTo(topLeft + const Offset(340, 22));
    await tester.pump();

    expect(navigations, isNotEmpty);
    expect(navigations.last, greaterThan(70));

    await gesture.up();
    await tester.pump();
    expect(dragEndCount, 1);
  });
}
