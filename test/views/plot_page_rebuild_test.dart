import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/utils/plot_performance_metrics.dart';
import 'package:vscope_serial/data/models/parse_result.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/pages/plot_page.dart';
import 'package:vscope_serial/views/plot/plot_painter.dart';

void main() {
  testWidgets('绘图页面按数据、通道和覆盖状态隔离重建', (tester) async {
    final serialService = SerialService();
    final vm = PlotViewModel(serialService);

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
    serialService.dispose();
    await tester.pump(const Duration(milliseconds: 100));
  }, skip: !PlotPerformanceMetrics.enabled);
}
