/// 绘图性能基准使用的轻量计数器。
///
/// 仅在传入 `--dart-define=PLOT_PERF_METRICS=true` 时记录数据，正式构建中
/// 所有调用都会被常量分支直接跳过。
final class PlotPerformanceMetrics {
  static const bool enabled = bool.fromEnvironment('PLOT_PERF_METRICS');
  static final PlotPerformanceMetrics instance = PlotPerformanceMetrics._();

  final Map<String, int> _counters = <String, int>{};

  PlotPerformanceMetrics._();

  void increment(String name) {
    if (!enabled) return;
    _counters.update(name, (value) => value + 1, ifAbsent: () => 1);
  }

  void reset() {
    if (!enabled) return;
    _counters.clear();
  }

  Map<String, int> snapshot() {
    if (!enabled) return const <String, int>{};
    return Map<String, int>.unmodifiable(_counters);
  }
}

abstract final class PlotPerformanceMetric {
  static const String viewModelNotify = 'viewModel.notify';
  static const String pageBuild = 'widget.page';
  static const String primaryToolbarBuild = 'widget.primaryToolbar';
  static const String secondaryToolbarBuild = 'widget.secondaryToolbar';
  static const String channelPanelBuild = 'widget.channelPanel';
  static const String plotAreaBuild = 'widget.plotArea';
  static const String legacyPainterPaint = 'paint.legacy';
  static const String backgroundPainterPaint = 'paint.background';
  static const String dataPainterPaint = 'paint.data';
  static const String axisPainterPaint = 'paint.axis';
  static const String overlayPainterPaint = 'paint.overlay';
}
