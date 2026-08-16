import 'package:flutter/foundation.dart';

import 'plot_render_snapshot.dart';

/// 协调目标视口和真正已经显示到外部纹理上的视口。
///
/// D3D11提交是异步的。观察、光标和测量若直接使用目标视口，会比纹理提前
/// 一帧移动。协调器只在原生端完成前后台纹理切换后发布对应快照。
class PlotPresentationCoordinator extends ChangeNotifier {
  PlotRenderSnapshot? _presentedSnapshot;
  int _presentedFrameId = 0;

  PlotRenderSnapshot? get presentedSnapshot => _presentedSnapshot;
  int get presentedFrameId => _presentedFrameId;

  void present(
    PlotRenderSnapshot snapshot, {
    required int frameId,
    bool notify = true,
    bool resetFrameSequence = false,
  }) {
    // D3D11 使用全局递增帧号，Canvas 使用同步的 viewportRevision；两者
    // 属于不同编号域。切换到同步渲染路径时必须重置比较基准，否则 Canvas
    // 快照会因编号较小而被误判为过期帧。
    if (!resetFrameSequence && frameId < _presentedFrameId) return;
    final changed =
        !identical(_presentedSnapshot, snapshot) ||
        _presentedFrameId != frameId;
    _presentedSnapshot = snapshot;
    _presentedFrameId = frameId;
    if (changed && notify) notifyListeners();
  }
}
