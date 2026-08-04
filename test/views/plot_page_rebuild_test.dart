import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/utils/plot_performance_metrics.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/services/data_connection_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';
import 'package:vscope_serial/views/plot/plot_gesture_handler.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

void main() {
  testWidgets('框选开关立即同步到绘图手势层', (tester) async {
    final connectionService = DataConnectionService();
    final vm = PlotViewModel(connectionService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );
    vm.ingestParsedResultForTest(
      ParseResult.ok([1, 2, 3, 4], bytesConsumed: 16),
    );
    vm.notifyListeners();
    await tester.pump();

    PlotGestureHandler gestureHandler() =>
        tester.widget<PlotGestureHandler>(find.byType(PlotGestureHandler));
    ToolbarToggleIconButton boxZoomButton() =>
        tester.widget<ToolbarToggleIconButton>(
          find.byWidgetPredicate(
            (widget) =>
                widget is ToolbarToggleIconButton &&
                widget.tooltip.startsWith('框选放大'),
          ),
        );

    expect(gestureHandler().boxZoomEnabled, isFalse);
    vm.setBoxZoomEnabled(true);
    await tester.pump();
    expect(gestureHandler().boxZoomEnabled, isTrue);
    expect(boxZoomButton().activeColor, Colors.blue);

    vm.setBoxZoomEnabled(true, continuous: true);
    await tester.pump();
    expect(gestureHandler().boxZoomEnabled, isTrue);
    expect(boxZoomButton().activeColor, Colors.orange);

    vm.setBoxZoomEnabled(false);
    await tester.pump();
    expect(gestureHandler().boxZoomEnabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    connectionService.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('绘图页面按数据、通道和覆盖状态隔离重建', (tester) async {
    final connectionService = DataConnectionService();
    final vm = PlotViewModel(connectionService);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<PlotViewModel>.value(
        value: vm,
        child: const MaterialApp(home: Scaffold(body: PlotPage())),
      ),
    );

    vm.ingestParsedResultForTest(
      ParseResult.ok([1, 2, 3, 4], bytesConsumed: 16),
    );
    vm.notifyListeners();
    await tester.pump();
    final layerSizes = [
      for (final name in ['background', 'data', 'axis', 'overlay'])
        tester.getSize(find.byKey(ValueKey<String>('plot-layer-$name'))),
    ];
    expect(layerSizes.toSet(), hasLength(1));

    PlotPerformanceMetrics.instance.reset();
    vm.ingestParsedResultForTest(
      ParseResult.ok([2, 3, 4, 5], bytesConsumed: 16),
    );
    vm.notifyListeners();
    await tester.pump();
    var counters = PlotPerformanceMetrics.instance.snapshot();
    expect(counters[PlotPerformanceMetric.plotAreaBuild], 1);
    expect(counters[PlotPerformanceMetric.primaryToolbarBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.secondaryToolbarBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.channelPanelBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.dataPainterPaint], 1);
    expect(counters[PlotPerformanceMetric.backgroundPainterPaint] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.axisPainterPaint] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.overlayPainterPaint] ?? 0, 0);

    PlotPerformanceMetrics.instance.reset();
    vm.updateCursor(CursorState(x: 1, y: 2, hasData: true));
    await tester.pump();
    counters = PlotPerformanceMetrics.instance.snapshot();
    expect(counters[PlotPerformanceMetric.plotAreaBuild], 1);
    expect(counters[PlotPerformanceMetric.primaryToolbarBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.channelPanelBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.overlayPainterPaint], 1);
    expect(counters[PlotPerformanceMetric.backgroundPainterPaint] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.dataPainterPaint] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.axisPainterPaint] ?? 0, 0);

    PlotPerformanceMetrics.instance.reset();
    vm.setChannelColor(0, Colors.purple);
    await tester.pump();
    counters = PlotPerformanceMetrics.instance.snapshot();
    expect(counters[PlotPerformanceMetric.plotAreaBuild], 1);
    expect(counters[PlotPerformanceMetric.channelPanelBuild], 1);
    expect(counters[PlotPerformanceMetric.primaryToolbarBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.secondaryToolbarBuild] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.backgroundPainterPaint] ?? 0, 0);
    expect(counters[PlotPerformanceMetric.dataPainterPaint], 1);
    expect(counters[PlotPerformanceMetric.axisPainterPaint], 1);
    expect(counters[PlotPerformanceMetric.overlayPainterPaint], 1);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    connectionService.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  }, skip: !PlotPerformanceMetrics.enabled);
}
