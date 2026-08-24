/// 绘图性能基准使用的轻量计数器。
///
/// 仅在传入 `--dart-define=PLOT_PERF_METRICS=true` 时记录数据，正式构建中
/// 所有调用都会被常量分支直接跳过。
final class PlotPerformanceMetrics {
  static const bool enabled = bool.fromEnvironment('PLOT_PERF_METRICS');
  static final PlotPerformanceMetrics instance = PlotPerformanceMetrics._();

  final Map<String, int> _counters = <String, int>{};
  final Map<String, List<int>> _samples = <String, List<int>>{};

  PlotPerformanceMetrics._();

  void increment(String name) {
    if (!enabled) return;
    _counters.update(name, (value) => value + 1, ifAbsent: () => 1);
  }

  /// 记录一次耗时或数量样本，单位由指标名约定。
  ///
  /// 性能开关关闭时该调用会被常量分支快速跳过；开启时每项最多保留
  /// 最近 4096 个样本，避免长时间基准自身无限占用内存。
  void record(String name, int value) {
    if (!enabled) return;
    final samples = _samples.putIfAbsent(name, () => <int>[]);
    if (samples.length >= 4096) samples.removeRange(0, 1024);
    samples.add(value);
  }

  void reset() {
    if (!enabled) return;
    _counters.clear();
    _samples.clear();
  }

  Map<String, int> snapshot() {
    if (!enabled) return const <String, int>{};
    return Map<String, int>.unmodifiable(_counters);
  }

  Map<String, List<int>> sampleSnapshot() {
    if (!enabled) return const <String, List<int>>{};
    return Map<String, List<int>>.unmodifiable({
      for (final entry in _samples.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    });
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
  static const String lodQueryMicros = 'lod.query.us';
  static const String geometryBuildMicros = 'geometry.build.us';
  static const String canvasSubmitMicros = 'canvas.submit.us';
  static const String gpuSubmitMicros = 'gpu.submit.us';
  static const String gpuSubmitCount = 'gpu.submit.count';
  static const String gpuGeometryUploadCount = 'gpu.geometry.upload.count';
  static const String gpuViewportOnlyCount = 'gpu.viewport.only.count';
  static const String gpuSegmentCount = 'gpu.segment.count';
  static const String lodBucketCount = 'lod.bucket.count';
  static const String geometryPointCount = 'geometry.point.count';
  static const String lodCacheHit = 'lod.cache.hit';
  static const String lodCacheMiss = 'lod.cache.miss';
  static const String geometryBufferGrowth = 'geometry.buffer.growth';
}
