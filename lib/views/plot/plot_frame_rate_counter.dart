import 'dart:async';

import 'package:flutter/foundation.dart';

/// 只统计绘图数据层实际完成的帧，不接收Flutter全应用的帧时序。
///
/// Canvas在数据层绘制完成后记录，D3D11在原生纹理呈现完成后记录。超过一秒
/// 没有新的绘图帧时归零，避免状态栏停留在其它界面动画产生的历史帧率。
class PlotFrameRateCounter {
  PlotFrameRateCounter({
    this.sampleWindow = const Duration(milliseconds: 500),
    this.idleTimeout = const Duration(seconds: 1),
  });

  final Duration sampleWindow;
  final Duration idleTimeout;
  final Stopwatch _clock = Stopwatch()..start();
  final ValueNotifier<double?> _fps = ValueNotifier<double?>(null);

  int? _windowStartMicros;
  int _frameCount = 0;
  Timer? _idleTimer;

  ValueListenable<double?> get fps => _fps;

  void recordFrame({int? timestampMicros}) {
    final timestamp = timestampMicros ?? _clock.elapsedMicroseconds;
    final start = _windowStartMicros;
    if (start != null && timestamp < start) return;

    _windowStartMicros ??= timestamp;
    _frameCount++;
    _restartIdleTimer();

    final elapsed = timestamp - _windowStartMicros!;
    if (elapsed < sampleWindow.inMicroseconds) return;
    _fps.value = (_frameCount - 1) * Duration.microsecondsPerSecond / elapsed;
    _windowStartMicros = timestamp;
    _frameCount = 1;
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      _windowStartMicros = null;
      _frameCount = 0;
      _fps.value = 0;
    });
  }

  void dispose() {
    _idleTimer?.cancel();
    _clock.stop();
    _fps.dispose();
  }
}
