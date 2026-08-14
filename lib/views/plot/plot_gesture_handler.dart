import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/constants/plot_configuration.dart';
import 'package:flutter/services.dart';

import '../../core/utils/app_logger.dart';
import '../../data/models/plot_gesture_modifier.dart';
import '../../data/models/channel_config.dart';
import '../../data/models/plot_data.dart';
import 'plot_painter.dart';
import 'plot_presentation_coordinator.dart';
import 'plot_viewport.dart';

/// 绘图手势处理器
///
/// 负责处理绘图区域的所有用户交互：
/// - **鼠标滚轮缩放**：普通滚轮缩放 X 轴，修饰键+滚轮按位置缩放 X/Y 轴
/// - **触控板导航**：双指移动平移视口，捏合手势以指针位置为中心缩放
/// - **拖拽平移**：普通模式下鼠标左键拖动；框选模式下鼠标右键拖动
/// - **框选放大**：开启框选模式后，鼠标左键拖拽框选区域并放大
/// - **垂直光标悬停**：鼠标移动时更新垂直光标位置
/// - **测量线拖动**：点击并拖动 X-X/Y-Y 测量线标签或统计范围标签
///
/// 拖动使用 [Listener] 的原始指针事件（onPointerDown/Move/Up）而非 [GestureDetector] 的 pan，
/// 避免 GestureDetector 在快速移动时合并/丢帧导致拖动距离丢失的问题。
/// 绘图区指针手势协调器。
///
/// 平移、缩放、测量、观察、定位条和偏置轴共享同一命中测试顺序；拖动过程只更新
/// 内存视口并按帧通知，松手后才写设置和记录视口历史。
class PlotGestureHandler extends StatefulWidget {
  /// 当前绘图视口
  final PlotViewport viewport;

  /// D3D11异步呈现时，坐标命中使用真正显示在屏幕上的视口。
  final PlotPresentationCoordinator? presentationCoordinator;

  /// 视口变化回调（缩放、平移、框选放大）
  ///
  /// [fromDrag] 为 true 时表示来自用户拖动，回调方可据此优化通知策略。
  final void Function(PlotViewport viewport, {bool fromDrag}) onViewportChanged;

  /// 拖动结束回调
  ///
  /// 平移拖动结束时调用，用于保存视口配置和历史记录。
  final VoidCallback? onDragEnd;

  /// 连续视口交互开始/结束回调，用于切换有界 LOD 预览。
  final ValueChanged<bool>? onInteractionChanged;

  /// 光标变化回调（悬停、测量线拖动）
  final void Function(CursorState? cursor) onCursorChanged;

  /// 单垂直光标开关
  final bool vCursorEnabled;

  /// 框选放大模式开关
  final bool boxZoomEnabled;

  /// 完成一次有效框选后的回调
  final VoidCallback? onBoxZoomCompleted;

  /// 子组件（通常是 CustomPaint）
  final Widget child;

  /// 当前绘图数据（用于 Y-Y 测量线吸附到最近绘图点）
  final List<PlotDataPoint> data;

  /// X-X 测量第一条线位置（用于拖动检测）
  final double? xCursor1;

  /// X-X 测量第二条线位置
  final double? xCursor2;

  /// Y-Y 测量第一条线位置
  final double? yCursor1;

  /// Y-Y 测量第二条线位置
  final double? yCursor2;
  final List<PlotMeasurementGroup> xMeasurementGroups;
  final List<PlotMeasurementGroup> yMeasurementGroups;

  /// Y1/Y2 拖动时是否吸附到最近可见波形点。
  final bool yMeasurementSnapEnabled;

  /// 统计范围左边界
  final double? statsX1;

  /// 统计范围右边界
  final double? statsX2;

  /// X1 测量线拖动回调
  final void Function(double x)? onXCursor1Drag;

  /// X2 测量线拖动回调
  final void Function(double x)? onXCursor2Drag;

  /// Y1 测量线拖动回调
  final void Function(double y)? onYCursor1Drag;

  /// Y2 测量线拖动回调
  final void Function(double y)? onYCursor2Drag;
  final void Function(int groupIndex, int lineIndex, double value)?
  onXMeasurementDrag;
  final void Function(int groupIndex, int lineIndex, double value)?
  onYMeasurementDrag;
  final void Function(int groupIndex)? onXMeasurementDelete;
  final void Function(int groupIndex)? onYMeasurementDelete;

  /// S1 统计范围拖动回调
  final void Function(double x)? onStatsX1Drag;

  /// S2 统计范围拖动回调
  final void Function(double x)? onStatsX2Drag;
  final List<PlotObservation> observations;
  final void Function(int index, double x)? onObservationDrag;
  final void Function(int index)? onObservationDelete;
  final bool observationPlacementActive;
  final void Function(double x)? onObservationPlacementHover;
  final void Function(double x)? onObservationPlacementCommit;

  /// 通道配置列表（用于偏移标签拖动检测）
  final List<ChannelConfig> channels;

  /// 当前数据实际包含的活动通道数
  final int activeChannelCount;

  /// 通道偏移拖动回调
  final void Function(int channelIndex, double yOffset)? onChannelOffsetDrag;

  /// 通道 Y 轴缩放回调（修饰键+滚轮在偏置Y轴区域时触发）
  final void Function(int channelIndex, double scaleDelta)? onChannelYScaleZoom;

  /// 轴向缩放手势使用的修饰键，默认保持原有 Shift 行为。
  final PlotGestureModifier gestureModifier;

  /// 目标刷新帧率（fps），与高级设置中的绘图刷新帧率同步
  final int refreshFps;

  /// 绘图文本字体大小偏移，基于默认字号调整，范围 -3~6
  final int plotFontSizeDelta;

  PlotGestureHandler({
    super.key,
    required this.viewport,
    this.presentationCoordinator,
    required this.onViewportChanged,
    required this.onCursorChanged,
    this.vCursorEnabled = false,
    this.boxZoomEnabled = false,
    this.onBoxZoomCompleted,
    this.onDragEnd,
    this.onInteractionChanged,
    required this.child,
    this.data = const [],
    this.xCursor1,
    this.xCursor2,
    this.yCursor1,
    this.yCursor2,
    this.xMeasurementGroups = const [],
    this.yMeasurementGroups = const [],
    this.yMeasurementSnapEnabled = true,
    this.statsX1,
    this.statsX2,
    this.onXCursor1Drag,
    this.onXCursor2Drag,
    this.onYCursor1Drag,
    this.onYCursor2Drag,
    this.onXMeasurementDrag,
    this.onYMeasurementDrag,
    this.onXMeasurementDelete,
    this.onYMeasurementDelete,
    this.onStatsX1Drag,
    this.onStatsX2Drag,
    this.observations = const [],
    this.onObservationDrag,
    this.onObservationDelete,
    this.observationPlacementActive = false,
    this.onObservationPlacementHover,
    this.onObservationPlacementCommit,
    required this.channels,
    int? activeChannelCount,
    this.onChannelOffsetDrag,
    this.onChannelYScaleZoom,
    this.gestureModifier = PlotGestureModifier.shift,
    this.refreshFps = 60,
    this.plotFontSizeDelta = 0,
  }) : activeChannelCount = (activeChannelCount ?? channels.length).clamp(
         0,
         channels.length,
       );

  @override
  State<PlotGestureHandler> createState() => _PlotGestureHandlerState();
}

/// 测量线拖动目标枚举
///
/// 标识当前正在拖动的测量线、统计范围边界或通道偏移标签。
enum _DragTarget {
  none,
  xCursor1,
  xCursor2,
  yCursor1,
  yCursor2,
  statsX1,
  statsX2,
  channelOffset,
  observation,
}

enum _ShiftZoomAxis { none, pending, x, y, channelY }

/// [PlotGestureHandler] 的状态类
///
/// 管理拖动状态、框选状态、测量线拖动目标等。
class _PlotGestureHandlerState extends State<PlotGestureHandler> {
  static const int _maxSnapScanPoints = 4096;
  static const double _minimumBoxZoomExtent = 4;
  int _measurementGroupIndex = 0;

  PlotViewport get _presentedViewport =>
      widget.presentationCoordinator?.presentedSnapshot?.viewport ??
      widget.viewport;

  bool get _isZoomModifierPressed => switch (widget.gestureModifier) {
    PlotGestureModifier.shift => HardwareKeyboard.instance.isShiftPressed,
    PlotGestureModifier.control => HardwareKeyboard.instance.isControlPressed,
  };

  /// 当前帧内最后一次垂直光标位置。
  ///
  /// 鼠标的 hover 事件频率可能明显高于绘图帧率；逐个注册
  /// post-frame callback 会在绘图繁忙时形成积压，最终表现为光标短暂
  /// 跟随后停住。这里只保留下一帧真正需要显示的最后一个位置。
  CursorState? _pendingHoverCursor;
  bool _hoverCallbackScheduled = false;

  /// 是否正在拖拽平移
  bool _isDragging = false;

  /// 是否正在框选
  bool _isBoxSelecting = false;

  /// 修饰键 + 拖动时锁定的缩放轴。
  ///
  /// 按下时根据鼠标所在区域识别一次，后续即使斜向拖动也只缩放该轴。
  _ShiftZoomAxis _shiftZoomAxis = _ShiftZoomAxis.none;

  /// 上次指针位置（用于计算拖拽 delta）
  Offset? _lastPosition;

  /// 框选起始位置
  Offset? _boxStart;

  /// 框选结束位置
  Offset? _boxEnd;

  /// 当前拖动的测量线目标
  _DragTarget _dragTarget = _DragTarget.none;

  /// 拖动期间的本地视口副本
  ///
  /// 避免在快速拖动时依赖 widget.viewport 的实时更新。
  PlotViewport? _dragViewport;

  /// 修饰键拖动开始时鼠标对应的 X 轴数据坐标
  double? _shiftZoomCenterX;

  /// 修饰键拖动开始时鼠标对应的 Y 轴数据坐标
  double? _shiftZoomCenterY;

  /// 修饰键拖动偏置 Y 轴时命中的通道。
  int? _shiftZoomChannelIndex;

  /// 右侧偏置 Y 轴列拖动时使用相对位移，不把鼠标位置直接当作 0 点。
  bool _offsetDragUsesDelta = false;
  double? _offsetDragStartDataY;
  double _offsetDragStartYOffset = 0;

  /// 上次通知 UI 重绘的视口（用于节流）
  PlotViewport? _lastNotifiedViewport;

  /// 上次通知时间戳
  int _lastNotifyTime = 0;

  /// 目标刷新帧率（fps），由外部传入，与高级设置同步
  int _targetFps = 30;

  /// 触控板手势期间累积的视口。
  ///
  /// PointerPanZoomUpdateEvent 同时携带双指平移增量和累计缩放比例；
  /// 使用本地副本可避免高频事件依赖父组件重建后的 widget.viewport。
  PlotViewport? _trackpadViewport;
  double _trackpadLastScale = 1;
  bool _trackpadDidPan = false;
  bool _trackpadDidChange = false;
  bool _viewportInteractionActive = false;

  void _setViewportInteractionActive(bool value) {
    if (_viewportInteractionActive == value) return;
    _viewportInteractionActive = value;
    widget.onInteractionChanged?.call(value);
  }

  double _fontSize(double base) {
    return (base + 1 + widget.plotFontSizeDelta).clamp(6.0, 24.0).toDouble();
  }

  double _snapXToNearestVisiblePoint(double x) {
    if (widget.data.isEmpty) return x;

    final index = _nearestPointListIndexByX(x);
    return index == null
        ? x.clamp(_presentedViewport.xMin, _presentedViewport.xMax).toDouble()
        : widget.data[index].index.toDouble();
  }

  int? _nearestPointListIndexByX(double x) {
    if (widget.data.isEmpty) return null;
    final range = _visibleDataRange();
    if (range == null) return null;

    int left = range.start;
    int right = range.end - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final midX = widget.data[mid].index.toDouble();
      if (midX < x) {
        left = mid + 1;
      } else if (midX > x) {
        right = mid - 1;
      } else {
        return mid;
      }
    }

    final candidates = <int>[
      if (right >= range.start && right < range.end) right,
      if (left >= range.start && left < range.end) left,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final da = (widget.data[a].index.toDouble() - x).abs();
      final db = (widget.data[b].index.toDouble() - x).abs();
      return da.compareTo(db);
    });
    return candidates.first;
  }

  ({int start, int end})? _visibleDataRange() {
    if (widget.data.isEmpty) return null;
    final viewport = _presentedViewport;

    int start = 0;
    int end = widget.data.length;
    var left = 0;
    var right = widget.data.length;
    while (left < right) {
      final mid = (left + right) ~/ 2;
      if (widget.data[mid].index < viewport.xMin) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    start = left;

    left = start;
    right = widget.data.length;
    while (left < right) {
      final mid = (left + right) ~/ 2;
      if (widget.data[mid].index <= viewport.xMax) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    end = left;

    if (start >= end) return null;
    return (start: start, end: end);
  }

  double _snapYToNearestVisiblePoint(Offset pos, Size size) {
    final viewport = _presentedViewport;
    final targetScreenY =
        pos.dy
            .clamp(
              PlotViewport().marginTop,
              size.height - PlotViewport().marginBottom,
            )
            .toDouble();
    var bestY = viewport.screenToDataY(targetScreenY, size.height);
    if (widget.data.isEmpty) return bestY;

    final range = _visibleDataRange();
    if (range == null) return bestY;

    final visibleCount = range.end - range.start;
    final step = (visibleCount / _maxSnapScanPoints).ceil().clamp(
      1,
      visibleCount,
    );
    var bestDistance = double.infinity;

    for (int index = range.start; index < range.end; index += step) {
      _visitSnapYPoint(index, targetScreenY, size, (distance, y) {
        if (distance < bestDistance) {
          bestDistance = distance;
          bestY = y;
        }
      });
    }
    if (step > 1) {
      _visitSnapYPoint(range.end - 1, targetScreenY, size, (distance, y) {
        if (distance < bestDistance) {
          bestDistance = distance;
          bestY = y;
        }
      });
    }

    return bestY;
  }

  void _visitSnapYPoint(
    int pointIndex,
    double targetScreenY,
    Size size,
    void Function(double distance, double y) visit,
  ) {
    final point = widget.data[pointIndex];
    for (
      int i = 0;
      i < point.values.length && i < widget.channels.length;
      i++
    ) {
      final channel = widget.channels[i];
      if (!channel.visible) continue;

      final pointY = point.values[i] * channel.yScale + channel.yOffset;
      final pointScreenY = _presentedViewport.dataToScreenY(
        pointY,
        size.height,
      );
      visit((pointScreenY - targetScreenY).abs(), pointY);
    }
  }

  /// 标签尺寸（与 PlotLayerPainter 中一致，用于命中检测）
  static const double _labelWidth = 28;
  static const double _labelHeight = 20;

  /// 当前拖动的通道偏移索引
  int _offsetChannelIndex = -1;
  int _observationIndex = -1;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: _handleHover,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        onPointerPanZoomStart: _handlePointerPanZoomStart,
        onPointerPanZoomUpdate: _handlePointerPanZoomUpdate,
        onPointerPanZoomEnd: _handlePointerPanZoomEnd,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_isBoxSelecting && _boxStart != null && _boxEnd != null)
              CustomPaint(
                painter: _BoxSelectionPainter(start: _boxStart!, end: _boxEnd!),
                size: Size.infinite,
              ),
          ],
        ),
      ),
    );
  }

  /// 处理指针信号（鼠标滚轮缩放）
  ///
  /// - 普通滚轮：以鼠标位置为中心缩放 X 轴
  /// - 修饰键+滚轮：根据鼠标所在区域（Y轴区/X轴区/绘图区）缩放对应轴
  void _handlePointerSignal(PointerSignalEvent event) {
    // 鼠标滚轮与工具栏 X/Y 缩放共享视口限制，缩放中心固定在指针所在数据位置。
    if (event is PointerScrollEvent) {
      final isZoomModifierPressed = _isZoomModifierPressed;

      final size = context.size ?? Size.zero;
      if (size.isEmpty) return;

      final localPosition = event.localPosition;
      final zoomFactor = event.scrollDelta.dy > 0 ? 1.1 : 0.9;

      // 判断鼠标位置：在 Y 轴区域（左侧边距）还是 X 轴区域（底部边距）或绘图区
      final inYAxisArea = localPosition.dx < widget.viewport.marginLeft;
      final inXAxisArea =
          localPosition.dy > size.height - widget.viewport.marginBottom;

      // 判断是否在某个偏置 Y 轴列上
      final offsetChannelIndex = _hitTestOffsetAxisColumn(localPosition, size);

      var newViewport = widget.viewport;

      // 修饰键 + 滚轮：根据鼠标位置决定缩放轴
      if (isZoomModifierPressed) {
        if (offsetChannelIndex != null && widget.onChannelYScaleZoom != null) {
          // 鼠标在偏置 Y 轴列上 -> 单独缩放该通道的 yScale
          final scaleDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
          widget.onChannelYScaleZoom!(offsetChannelIndex, scaleDelta);
          return;
        } else if (inYAxisArea) {
          // 鼠标在默认 Y 轴区域 -> 缩放全局 Y 轴
          final centerY = widget.viewport.screenToDataY(
            localPosition.dy,
            size.height,
          );
          newViewport = newViewport.zoomY(zoomFactor, centerY);
        } else if (inXAxisArea) {
          // 鼠标在 X 轴区域 -> 缩放 X 轴
          final centerX = widget.viewport.screenToDataX(
            localPosition.dx,
            size.width,
          );
          newViewport = newViewport.zoomX(zoomFactor, centerX);
        } else {
          // 鼠标在绘图区 -> 同时缩放 X 和 Y
          final centerX = widget.viewport.screenToDataX(
            localPosition.dx,
            size.width,
          );
          final centerY = widget.viewport.screenToDataY(
            localPosition.dy,
            size.height,
          );
          newViewport = newViewport.zoomX(zoomFactor, centerX);
          newViewport = newViewport.zoomY(zoomFactor, centerY);
        }
      }
      // 普通滚轮 = X 轴缩放
      else {
        final centerX = widget.viewport.screenToDataX(
          localPosition.dx,
          size.width,
        );
        newViewport = newViewport.zoomX(zoomFactor, centerX);
      }

      widget.onViewportChanged(newViewport, fromDrag: false);
    }
  }

  /// 开始 Windows/macOS 精密触控板的双指平移或捏合手势。
  void _handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    _trackpadViewport = widget.viewport.copy();
    _trackpadLastScale = 1;
    _trackpadDidPan = false;
    _trackpadDidChange = false;
  }

  /// 处理触控板双指移动和捏合。
  ///
  /// - 双指移动复用鼠标拖动的 X/Y 平移方向。
  /// - 捏合在绘图区同时缩放 X/Y；指针位于坐标轴时只缩放对应轴。
  /// - 纯捏合按普通缩放上报，不会关闭“跟随”；实际产生平移后才按拖动上报。
  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final size = context.size ?? Size.zero;
    var viewport = _trackpadViewport;
    if (size.isEmpty || viewport == null) return;

    const panThresholdSquared = 0.25;
    final panDelta = event.localPanDelta;
    final hasPan = panDelta.distanceSquared > panThresholdSquared;
    if (hasPan) {
      _setViewportInteractionActive(true);
      viewport = viewport.panX(panDelta.dx, size.width);
      viewport = viewport.panY(panDelta.dy, size.height);
      _trackpadDidPan = true;
      _trackpadDidChange = true;
    }

    final currentScale =
        event.scale.isFinite && event.scale > 0
            ? event.scale
            : _trackpadLastScale;
    final scaleRatio = currentScale / _trackpadLastScale;
    final hasScale = (scaleRatio - 1).abs() > 0.0001;
    if (hasScale) {
      // PointerPanZoom 的 scale > 1 表示双指张开；PlotViewport 的 factor < 1
      // 表示放大，因此这里取倒数，并限制单个事件的异常跳变。
      final zoomFactor = (1 / scaleRatio).clamp(0.5, 2.0).toDouble();
      final focalPosition = event.localPosition + event.localPan;
      viewport = _zoomTrackpadViewport(
        viewport,
        zoomFactor,
        focalPosition,
        size,
      );
      _trackpadDidChange = true;
    }

    _trackpadLastScale = currentScale;
    _trackpadViewport = viewport;
    if (_trackpadDidChange) {
      widget.onViewportChanged(viewport, fromDrag: _trackpadDidPan);
    }
  }

  PlotViewport _zoomTrackpadViewport(
    PlotViewport viewport,
    double zoomFactor,
    Offset focalPosition,
    Size size,
  ) {
    final centerX = viewport.screenToDataX(
      focalPosition.dx.clamp(
        viewport.marginLeft,
        size.width - viewport.marginRight,
      ),
      size.width,
    );
    final centerY = viewport.screenToDataY(
      focalPosition.dy.clamp(
        viewport.marginTop,
        size.height - viewport.marginBottom,
      ),
      size.height,
    );
    final inYAxisArea = focalPosition.dx < viewport.marginLeft;
    final inXAxisArea = focalPosition.dy > size.height - viewport.marginBottom;

    if (inYAxisArea && !inXAxisArea) {
      return viewport.zoomY(zoomFactor, centerY);
    }
    if (inXAxisArea) {
      return viewport.zoomX(zoomFactor, centerX);
    }
    return viewport.zoomX(zoomFactor, centerX).zoomY(zoomFactor, centerY);
  }

  /// 触控板平移结束时提交最终视口并持久化；纯捏合沿用滚轮缩放逻辑。
  void _handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    final viewport = _trackpadViewport;
    if (viewport != null && _trackpadDidChange) {
      widget.onViewportChanged(viewport, fromDrag: _trackpadDidPan);
      if (_trackpadDidPan) {
        _setViewportInteractionActive(false);
        widget.onDragEnd?.call();
      }
    }

    _trackpadViewport = null;
    _trackpadLastScale = 1;
    _trackpadDidPan = false;
    _trackpadDidChange = false;
  }

  /// 处理鼠标悬停（更新垂直光标）
  ///
  /// 当 [vCursorEnabled] 开启时，将鼠标位置转换为数据坐标并回调。
  void _handleHover(PointerHoverEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    final viewport = _presentedViewport;
    final x = viewport.screenToDataX(event.localPosition.dx, size.width);
    final y = viewport.screenToDataY(event.localPosition.dy, size.height);

    if (widget.observationPlacementActive) {
      widget.onObservationPlacementHover?.call(x);
      return;
    }

    // 单垂直光标优先（通过开关控制）
    if (widget.vCursorEnabled) {
      _pendingHoverCursor = CursorState(
        x: x,
        y: y,
        screenPosition: event.localPosition,
      );
      if (_hoverCallbackScheduled) return;

      _hoverCallbackScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _hoverCallbackScheduled = false;
        if (!mounted || !widget.vCursorEnabled) {
          _pendingHoverCursor = null;
          return;
        }
        final cursor = _pendingHoverCursor;
        _pendingHoverCursor = null;
        if (cursor != null) widget.onCursorChanged(cursor);
      });
      // addPostFrameCallback 本身不会主动请求新帧；采样暂停或低频时若没有
      // 其他重绘来源，光标会一直等待，看起来像停止跟随。
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
  }

  // ===== 原始指针事件处理拖动 =====
  // 使用 Listener 而非 GestureDetector，避免 pan 事件在快速移动时被合并/丢帧

  /// 处理指针按下（开始拖动或框选）
  ///
  /// 优先检测是否点击在测量标签上（开始测量线拖动），
  /// 否则根据框选模式开始框选或平移。
  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryButton) {
      if (widget.boxZoomEnabled) {
        final size = context.size ?? Size.zero;
        if (size.isEmpty) return;
        _isDragging = true;
        _lastPosition = event.localPosition;
        _initializeDragViewport();
        AppLogger().trace(
          '框选模式右键平移开始: pos=${event.localPosition}',
          category: 'GESTURE',
        );
        return;
      }
      final observationHit = _hitTestObservation(
        event.localPosition,
        includeLocked: false,
      );
      if (observationHit != null) {
        widget.onObservationDelete?.call(observationHit);
        return;
      }
      final measurementHit = _hitTestMeasurementLabel(event.localPosition);
      if (measurementHit == _DragTarget.xCursor1 ||
          measurementHit == _DragTarget.xCursor2) {
        widget.onXMeasurementDelete?.call(_measurementGroupIndex);
      } else if (measurementHit == _DragTarget.yCursor1 ||
          measurementHit == _DragTarget.yCursor2) {
        widget.onYMeasurementDelete?.call(_measurementGroupIndex);
      }
      return;
    }

    // 只处理鼠标左键（kPrimaryButton）
    if (event.buttons != kPrimaryButton) return;

    if (widget.observationPlacementActive) {
      final size = context.size ?? Size.zero;
      if (size.isEmpty) return;
      final x = _presentedViewport.screenToDataX(
        event.localPosition.dx,
        size.width,
      );
      widget.onObservationPlacementCommit?.call(x);
      return;
    }

    final observationHit = _hitTestObservation(
      event.localPosition,
      includeLocked: false,
    );
    if (observationHit != null) {
      _dragTarget = _DragTarget.observation;
      _observationIndex = observationHit;
      _isDragging = true;
      _lastPosition = event.localPosition;
      AppLogger().trace(
        '观察线拖动开始: index=$_observationIndex, pos=${event.localPosition}',
        category: 'GESTURE',
      );
      return;
    }

    // 检测是否点击在通道偏移标签上
    final offsetHit = _hitTestOffsetLabel(event.localPosition);
    if (offsetHit != null) {
      _dragTarget = _DragTarget.channelOffset;
      _offsetChannelIndex = offsetHit;
      _offsetDragUsesDelta = false;
      _isDragging = true;
      _lastPosition = event.localPosition;
      AppLogger().trace(
        '偏移拖动开始: channel=$_offsetChannelIndex, pos=${event.localPosition}',
        category: 'GESTURE',
      );
      return;
    }

    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    // 右侧偏置 Y 轴列也可直接上下拖动 offset。
    final offsetAxisHit = _hitTestOffsetAxisColumn(event.localPosition, size);
    if (offsetAxisHit != null && !_isZoomModifierPressed) {
      _dragTarget = _DragTarget.channelOffset;
      _offsetChannelIndex = offsetAxisHit;
      _offsetDragUsesDelta = true;
      _offsetDragStartDataY = _presentedViewport.screenToDataY(
        event.localPosition.dy.clamp(
          PlotViewport().marginTop,
          size.height - PlotViewport().marginBottom,
        ),
        size.height,
      );
      _offsetDragStartYOffset = _channelYOffset(offsetAxisHit);
      _isDragging = true;
      _lastPosition = event.localPosition;
      AppLogger().trace(
        '偏置Y轴拖动开始: channel=$_offsetChannelIndex, pos=${event.localPosition}',
        category: 'GESTURE',
      );
      return;
    }

    // 检测是否点击在测量标签上
    final dragTarget = _hitTestMeasurementLabel(event.localPosition);
    if (dragTarget != _DragTarget.none) {
      _dragTarget = dragTarget;
      _isDragging = true;
      _lastPosition = event.localPosition;
      AppLogger().trace(
        '测量拖动开始: target=$_dragTarget, pos=${event.localPosition}',
        category: 'GESTURE',
      );
      return;
    }

    if (_isZoomModifierPressed) {
      _isDragging = true;
      _lastPosition = event.localPosition;
      _initializeShiftZoom(event.localPosition, size, offsetAxisHit);
      _initializeDragViewport();
    } else if (widget.boxZoomEnabled) {
      _isBoxSelecting = true;
      _boxStart = event.localPosition;
      _boxEnd = event.localPosition;
      AppLogger().trace(
        '框选开始: pos=${event.localPosition}',
        category: 'GESTURE',
      );
    } else {
      _isDragging = true;
      _lastPosition = event.localPosition;
      _initializeDragViewport();
      AppLogger().trace(
        '平移拖动开始: pos=${event.localPosition}, viewport xMin=${_dragViewport!.xMin}, targetFps=$_targetFps',
        category: 'GESTURE',
      );
    }
  }

  void _initializeShiftZoom(Offset position, Size size, int? offsetAxisHit) {
    final centerScreenX = position.dx.clamp(
      widget.viewport.marginLeft,
      size.width - widget.viewport.marginRight,
    );
    final centerScreenY = position.dy.clamp(
      PlotViewport().marginTop,
      size.height - PlotViewport().marginBottom,
    );
    _shiftZoomCenterX = widget.viewport.screenToDataX(
      centerScreenX,
      size.width,
    );
    _shiftZoomCenterY = widget.viewport.screenToDataY(
      centerScreenY,
      size.height,
    );

    final inYAxisArea = position.dx < widget.viewport.marginLeft;
    final inXAxisArea =
        position.dy > size.height - widget.viewport.marginBottom;
    if (offsetAxisHit != null && widget.onChannelYScaleZoom != null) {
      _shiftZoomAxis = _ShiftZoomAxis.channelY;
      _shiftZoomChannelIndex = offsetAxisHit;
    } else if (inYAxisArea && !inXAxisArea) {
      _shiftZoomAxis = _ShiftZoomAxis.y;
    } else if (inXAxisArea) {
      _shiftZoomAxis = _ShiftZoomAxis.x;
    } else {
      _shiftZoomAxis = _ShiftZoomAxis.pending;
    }
    AppLogger().trace(
      '${widget.gestureModifier.label}缩放开始: axis=$_shiftZoomAxis, channel=$_shiftZoomChannelIndex, pos=$position',
      category: 'GESTURE',
    );
  }

  void _initializeDragViewport() {
    // 开始平移立即退出跟随，但延迟精确窗口加载，连续拖动期间由 LOD 保持响应。
    _dragViewport = widget.viewport.copy();
    _lastNotifiedViewport = _dragViewport!.copy();
    _lastNotifyTime = DateTime.now().millisecondsSinceEpoch;
    _targetFps = widget.refreshFps.clamp(
      PlotConfiguration.minRefreshFps,
      PlotConfiguration.maxRefreshFps,
    );
    _setViewportInteractionActive(true);
  }

  /// 检测点击位置是否在测量标签上
  ///
  /// 直接检查各测量线位置是否存在，不再依赖 cursorMode，
  /// 支持 X-X 和 Y-Y 同时开启的情况。
  /// 检测顺序：X-X 标签（顶部）→ Y-Y 标签（左侧）→ 统计范围标签（底部）。
  _DragTarget _hitTestMeasurementLabel(Offset pos) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return _DragTarget.none;
    final viewport = _presentedViewport;

    // X-X 测量：检测 X1/X2 标签（标签在绘图区顶部内侧）
    final xGroups =
        widget.xMeasurementGroups.isNotEmpty
            ? widget.xMeasurementGroups
            : [
              if (widget.xCursor1 != null && widget.xCursor2 != null)
                PlotMeasurementGroup(
                  cursor1: widget.xCursor1!,
                  cursor2: widget.xCursor2!,
                ),
            ];
    if (xGroups.isNotEmpty) {
      final topY = PlotViewport().marginTop + 12;
      if ((pos.dy - topY).abs() < _labelHeight / 2 + 6) {
        for (var i = xGroups.length - 1; i >= 0; i--) {
          final group = xGroups[i];
          final sx1 = viewport.dataToScreenX(group.cursor1, size.width);
          if ((pos.dx - sx1).abs() < _labelWidth / 2 + 6) {
            _measurementGroupIndex = i;
            return _DragTarget.xCursor1;
          }
          final sx2 = viewport.dataToScreenX(group.cursor2, size.width);
          if ((pos.dx - sx2).abs() < _labelWidth / 2 + 6) {
            _measurementGroupIndex = i;
            return _DragTarget.xCursor2;
          }
        }
      }
    } else {
      final topY = PlotViewport().marginTop + 12;
      if ((pos.dy - topY).abs() < _labelHeight / 2 + 6) {
        if (widget.xCursor1 != null &&
            (pos.dx - viewport.dataToScreenX(widget.xCursor1!, size.width))
                    .abs() <
                _labelWidth / 2 + 6) {
          _measurementGroupIndex = 0;
          return _DragTarget.xCursor1;
        }
        if (widget.xCursor2 != null &&
            (pos.dx - viewport.dataToScreenX(widget.xCursor2!, size.width))
                    .abs() <
                _labelWidth / 2 + 6) {
          _measurementGroupIndex = 0;
          return _DragTarget.xCursor2;
        }
      }
    }

    // Y-Y 测量：检测 Y1/Y2 标签（标签在测量线左侧）
    final yGroups =
        widget.yMeasurementGroups.isNotEmpty
            ? widget.yMeasurementGroups
            : [
              if (widget.yCursor1 != null && widget.yCursor2 != null)
                PlotMeasurementGroup(
                  cursor1: widget.yCursor1!,
                  cursor2: widget.yCursor2!,
                ),
            ];
    if (yGroups.isNotEmpty) {
      final leftX = viewport.marginLeft - 18;
      if ((pos.dx - leftX).abs() < _labelWidth / 2 + 6) {
        for (var i = yGroups.length - 1; i >= 0; i--) {
          final group = yGroups[i];
          final sy1 = viewport.dataToScreenY(group.cursor1, size.height);
          if ((pos.dy - sy1).abs() < _labelHeight / 2 + 6) {
            _measurementGroupIndex = i;
            return _DragTarget.yCursor1;
          }
          final sy2 = viewport.dataToScreenY(group.cursor2, size.height);
          if ((pos.dy - sy2).abs() < _labelHeight / 2 + 6) {
            _measurementGroupIndex = i;
            return _DragTarget.yCursor2;
          }
        }
      }
    } else {
      final leftX = viewport.marginLeft - 18;
      if ((pos.dx - leftX).abs() < _labelWidth / 2 + 6) {
        if (widget.yCursor1 != null &&
            (pos.dy - viewport.dataToScreenY(widget.yCursor1!, size.height))
                    .abs() <
                _labelHeight / 2 + 6) {
          _measurementGroupIndex = 0;
          return _DragTarget.yCursor1;
        }
        if (widget.yCursor2 != null &&
            (pos.dy - viewport.dataToScreenY(widget.yCursor2!, size.height))
                    .abs() <
                _labelHeight / 2 + 6) {
          _measurementGroupIndex = 0;
          return _DragTarget.yCursor2;
        }
      }
    }

    // 统计范围：检测 S1/S2 标签（标签在底部）
    if (widget.statsX1 != null || widget.statsX2 != null) {
      final bottomY = size.height - PlotViewport().marginBottom - 10;
      if ((pos.dy - bottomY).abs() < _labelHeight / 2 + 6) {
        if (widget.statsX1 != null) {
          final sx1 = viewport.dataToScreenX(widget.statsX1!, size.width);
          if ((pos.dx - sx1).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.statsX1;
          }
        }
        if (widget.statsX2 != null) {
          final sx2 = viewport.dataToScreenX(widget.statsX2!, size.width);
          if ((pos.dx - sx2).abs() < _labelWidth / 2 + 6) {
            return _DragTarget.statsX2;
          }
        }
      }
    }

    return _DragTarget.none;
  }

  /// 检测点击位置是否在通道偏移标签上
  ///
  /// 返回命中的通道索引，未命中返回 null。
  int? _hitTestObservation(Offset pos, {bool includeLocked = true}) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return null;
    final viewport = _presentedViewport;

    final plotTop = PlotViewport().marginTop;
    final plotBottom = size.height - PlotViewport().marginBottom;
    final plotLeft = viewport.marginLeft;
    final plotRight = size.width - viewport.marginRight;
    if (pos.dx < plotLeft || pos.dx > plotRight) return null;

    for (int i = widget.observations.length - 1; i >= 0; i--) {
      if (!includeLocked && widget.observations[i].locked) continue;
      final sx = viewport.dataToScreenX(widget.observations[i].x, size.width);
      final onHandle =
          pos.dy >= plotTop - 24 &&
          pos.dy <= plotTop &&
          (pos.dx - sx).abs() <= 22;
      final onLine =
          pos.dy >= plotTop && pos.dy <= plotBottom && (pos.dx - sx).abs() <= 6;
      if (onHandle || onLine) return i;
    }

    return null;
  }

  int? _hitTestOffsetLabel(Offset pos) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return null;

    final left = widget.viewport.marginLeft;

    for (final ch in _visibleOffsetAxisChannels()) {
      // 计算标签位置（与 PlotLayerPainter 中一致）
      final zeroDataY = 0.0 * ch.yScale + ch.yOffset;
      final zeroY = widget.viewport.dataToScreenY(zeroDataY, size.height);
      final plotH = widget.viewport.plotHeight(size.height);

      if (zeroY < PlotViewport().marginTop ||
          zeroY > PlotViewport().marginTop + plotH) {
        continue;
      }

      final displayName = _offsetAxisLabel(ch);
      final textPainter = TextPainter(
        text: TextSpan(
          text: displayName,
          style: TextStyle(
            fontSize: _fontSize(9),
            fontWeight: FontWeight.bold,
            fontFamily: 'SarasaUiSC',
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      const labelPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 1);
      final labelW = textPainter.width + labelPadding.horizontal;
      final labelH = textPainter.height + labelPadding.vertical;
      final labelX = left - labelW - 2;
      final labelY = zeroY - labelH / 2;

      // 扩大命中区域，方便拖动
      const hitPadding = 4.0;
      if (pos.dx >= labelX - hitPadding &&
          pos.dx <= labelX + labelW + hitPadding &&
          pos.dy >= labelY - hitPadding &&
          pos.dy <= labelY + labelH + hitPadding) {
        return ch.index;
      }
    }

    return null;
  }

  /// 检测鼠标位置是否在偏置 Y 轴列上
  ///
  /// 返回命中的通道索引，未命中返回 null。
  /// 偏置 Y 轴列位于绘图区右侧，每列宽度为 [PlotViewport.offsetAxisColumnWidth]。
  int? _hitTestOffsetAxisColumn(Offset pos, Size size) {
    final plotW = widget.viewport.plotWidth(size.width);
    final left = widget.viewport.marginLeft;
    final right = left + plotW;

    // 收集可见且开启偏移的通道。绑定组只命中一列。
    final offsetChannels = _visibleOffsetAxisChannels();

    var axisX = right;
    final widths = widget.viewport.offsetAxisColumnWidths;
    for (int colIndex = 0; colIndex < offsetChannels.length; colIndex++) {
      final width =
          colIndex < widths.length
              ? widths[colIndex]
              : PlotViewport.minOffsetAxisColumnWidth;
      final colLeft = axisX - 2;
      final colRight = axisX + width - 2;

      if (pos.dx >= colLeft &&
          pos.dx <= colRight &&
          pos.dy >= PlotViewport().marginTop &&
          pos.dy <= size.height - PlotViewport().marginBottom) {
        return offsetChannels[colIndex].index;
      }
      axisX += width;
    }

    return null;
  }

  List<ChannelConfig> _visibleOffsetAxisChannels() {
    final result = <ChannelConfig>[];
    final seenGroups = <int>{};
    for (final channel in widget.channels.take(widget.activeChannelCount)) {
      if (!channel.visible || !channel.offsetEnabled) continue;
      final groupId = channel.offsetBindingGroupId;
      if (groupId != null && !seenGroups.add(groupId)) continue;
      result.add(channel);
    }
    return result;
  }

  String _offsetAxisLabel(ChannelConfig channel) {
    final groupId = channel.offsetBindingGroupId;
    if (groupId == null) return _shortChannelName(channel);
    final names = widget.channels
        .take(widget.activeChannelCount)
        .where(
          (member) =>
              member.visible &&
              member.offsetEnabled &&
              member.offsetBindingGroupId == groupId,
        )
        .map(_shortChannelName)
        .toList(growable: false);
    if (names.isEmpty) return _shortChannelName(channel);
    return names.join('+');
  }

  String _shortChannelName(ChannelConfig channel) {
    return channel.index >= PlotConfiguration.rawChannelCount
        ? 'Math${channel.index - PlotConfiguration.rawChannelCount + 1}'
        : 'Ch${channel.index}';
  }

  /// 处理指针移动（拖拽平移、框选、测量线拖动）
  void _handlePointerMove(PointerMoveEvent event) {
    final size = context.size ?? Size.zero;
    if (size.isEmpty) return;

    if (_isBoxSelecting) {
      _boxEnd = event.localPosition;
      if (mounted) setState(() {});
    } else if (_isDragging && _lastPosition != null) {
      // 拖动测量标签
      if (_dragTarget != _DragTarget.none) {
        _handleMeasurementDrag(event.localPosition, size);
        _lastPosition = event.localPosition;
        return;
      }

      final dx = event.localPosition.dx - _lastPosition!.dx;
      final dy = event.localPosition.dy - _lastPosition!.dy;
      _lastPosition = event.localPosition;

      if (_shiftZoomAxis != _ShiftZoomAxis.none) {
        _handleShiftZoomDrag(dx, dy);
        if (_shiftZoomAxis == _ShiftZoomAxis.channelY) {
          return;
        }
      } else {
        // 使用本地视口副本进行累积平移，避免依赖 widget.viewport 的实时更新
        _dragViewport = _dragViewport!.panX(dx, size.width);
        _dragViewport = _dragViewport!.panY(dy, size.height);
      }

      // 节流：根据目标帧率计算间隔，与高级设置同步
      final notifyIntervalMs = (1000 / _targetFps).round();
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - _lastNotifyTime;
      final viewportChanged =
          _lastNotifiedViewport == null ||
          (_lastNotifiedViewport!.xMin - _dragViewport!.xMin).abs() > 1.0 ||
          (_lastNotifiedViewport!.yMin - _dragViewport!.yMin).abs() > 1.0;

      if (elapsed >= notifyIntervalMs && viewportChanged) {
        _lastNotifiedViewport = _dragViewport!.copy();
        _lastNotifyTime = now;
        widget.onViewportChanged(_dragViewport!, fromDrag: true);
      }
    }
  }

  void _handleShiftZoomDrag(double dx, double dy) {
    const zoomSensitivity = 240.0;
    if (_shiftZoomAxis == _ShiftZoomAxis.pending) {
      if (dx.abs() < 2 && dy.abs() < 2) return;
      _shiftZoomAxis =
          dy.abs() > dx.abs() ? _ShiftZoomAxis.y : _ShiftZoomAxis.x;
      AppLogger().trace(
        '${widget.gestureModifier.label}缩放锁定: axis=$_shiftZoomAxis',
        category: 'GESTURE',
      );
    }
    switch (_shiftZoomAxis) {
      case _ShiftZoomAxis.x:
        // 右拖时 factor < 1（放大），左拖时 factor > 1（缩小）。
        final factor = math.exp(-dx / zoomSensitivity);
        _dragViewport = _dragViewport!.zoomX(factor, _shiftZoomCenterX!);
        break;
      case _ShiftZoomAxis.y:
        // 上拖时 factor < 1（放大），下拖时 factor > 1（缩小）。
        final factor = math.exp(dy / zoomSensitivity);
        _dragViewport = _dragViewport!.zoomY(factor, _shiftZoomCenterY!);
        break;
      case _ShiftZoomAxis.channelY:
        final channelIndex = _shiftZoomChannelIndex;
        if (channelIndex == null || widget.onChannelYScaleZoom == null) return;
        // 上拖增大通道比例，下拖减小通道比例。
        final scaleDelta = math.exp(-dy / zoomSensitivity);
        widget.onChannelYScaleZoom!(channelIndex, scaleDelta);
        break;
      case _ShiftZoomAxis.none:
      case _ShiftZoomAxis.pending:
        break;
    }
  }

  double _channelYOffset(int channelIndex) {
    for (final channel in widget.channels) {
      if (channel.index == channelIndex) return channel.yOffset;
    }
    return 0;
  }

  /// 处理测量线拖动，根据 [_dragTarget] 将屏幕坐标转换为数据坐标并回调
  ///
  /// X 轴测量线、统计范围线和 Y-Y 测量线都吸附到当前显示窗口内的可见数据点。
  void _handleMeasurementDrag(Offset pos, Size size) {
    final viewport = _presentedViewport;
    switch (_dragTarget) {
      case _DragTarget.xCursor1:
        if (widget.onXMeasurementDrag != null ||
            widget.onXCursor1Drag != null) {
          final x = viewport.screenToDataX(
            pos.dx.clamp(
              viewport.marginLeft,
              size.width - viewport.marginRight,
            ),
            size.width,
          );
          final value = _snapXToNearestVisiblePoint(x);
          if (widget.onXMeasurementDrag != null) {
            widget.onXMeasurementDrag!(_measurementGroupIndex, 0, value);
          } else {
            widget.onXCursor1Drag!(value);
          }
        }
        break;
      case _DragTarget.xCursor2:
        if (widget.onXMeasurementDrag != null ||
            widget.onXCursor2Drag != null) {
          final x = viewport.screenToDataX(
            pos.dx.clamp(
              viewport.marginLeft,
              size.width - viewport.marginRight,
            ),
            size.width,
          );
          final value = _snapXToNearestVisiblePoint(x);
          if (widget.onXMeasurementDrag != null) {
            widget.onXMeasurementDrag!(_measurementGroupIndex, 1, value);
          } else {
            widget.onXCursor2Drag!(value);
          }
        }
        break;
      case _DragTarget.yCursor1:
        if (widget.onYMeasurementDrag != null ||
            widget.onYCursor1Drag != null) {
          final value =
              widget.yMeasurementSnapEnabled
                  ? _snapYToNearestVisiblePoint(pos, size)
                  : viewport.screenToDataY(
                    pos.dy
                        .clamp(
                          viewport.marginTop,
                          size.height - viewport.marginBottom,
                        )
                        .toDouble(),
                    size.height,
                  );
          if (widget.onYMeasurementDrag != null) {
            widget.onYMeasurementDrag!(_measurementGroupIndex, 0, value);
          } else {
            widget.onYCursor1Drag!(value);
          }
        }
        break;
      case _DragTarget.yCursor2:
        if (widget.onYMeasurementDrag != null ||
            widget.onYCursor2Drag != null) {
          final value =
              widget.yMeasurementSnapEnabled
                  ? _snapYToNearestVisiblePoint(pos, size)
                  : viewport.screenToDataY(
                    pos.dy
                        .clamp(
                          viewport.marginTop,
                          size.height - viewport.marginBottom,
                        )
                        .toDouble(),
                    size.height,
                  );
          if (widget.onYMeasurementDrag != null) {
            widget.onYMeasurementDrag!(_measurementGroupIndex, 1, value);
          } else {
            widget.onYCursor2Drag!(value);
          }
        }
        break;
      case _DragTarget.statsX1:
        if (widget.onStatsX1Drag != null && widget.statsX1 != null) {
          final x = viewport.screenToDataX(
            pos.dx.clamp(
              viewport.marginLeft,
              size.width - viewport.marginRight,
            ),
            size.width,
          );
          widget.onStatsX1Drag!(_snapXToNearestVisiblePoint(x));
        }
        break;
      case _DragTarget.statsX2:
        if (widget.onStatsX2Drag != null && widget.statsX2 != null) {
          final x = viewport.screenToDataX(
            pos.dx.clamp(
              viewport.marginLeft,
              size.width - viewport.marginRight,
            ),
            size.width,
          );
          widget.onStatsX2Drag!(_snapXToNearestVisiblePoint(x));
        }
        break;
      case _DragTarget.channelOffset:
        if (widget.onChannelOffsetDrag != null && _offsetChannelIndex >= 0) {
          final y = viewport.screenToDataY(
            pos.dy.clamp(
              PlotViewport().marginTop,
              size.height - PlotViewport().marginBottom,
            ),
            size.height,
          );
          final yOffset =
              _offsetDragUsesDelta && _offsetDragStartDataY != null
                  ? _offsetDragStartYOffset + (y - _offsetDragStartDataY!)
                  : y;
          widget.onChannelOffsetDrag!(_offsetChannelIndex, yOffset);
        }
        break;
      case _DragTarget.observation:
        if (widget.onObservationDrag != null && _observationIndex >= 0) {
          final x = viewport.screenToDataX(
            pos.dx.clamp(
              viewport.marginLeft,
              size.width - viewport.marginRight,
            ),
            size.width,
          );
          widget.onObservationDrag!(
            _observationIndex,
            _snapXToNearestVisiblePoint(x),
          );
        }
        break;
      case _DragTarget.none:
        break;
    }
  }

  /// 处理指针抬起（结束框选并应用放大，或结束拖动）
  ///
  /// 框选结束时，将框选区域转换为数据坐标并回调 [onViewportChanged]。
  void _handlePointerUp(PointerUpEvent event) {
    // 仅在拖动结束时提交视口历史和持久化，避免每个指针事件触发磁盘写入。
    AppLogger().trace(
      '拖动结束: box=$_isBoxSelecting, drag=$_isDragging, target=$_dragTarget',
      category: 'GESTURE',
    );

    // 偏移拖动结束，清空状态
    if (_dragTarget == _DragTarget.channelOffset) {
      _offsetChannelIndex = -1;
      _offsetDragUsesDelta = false;
      _offsetDragStartDataY = null;
      _offsetDragStartYOffset = 0;
    }
    if (_dragTarget == _DragTarget.observation) {
      _observationIndex = -1;
    }

    if (_isBoxSelecting && _boxStart != null && _boxEnd != null) {
      final size = context.size ?? Size.zero;
      if (size.isEmpty) return;

      final selectionDelta = _boxEnd! - _boxStart!;
      if (selectionDelta.dx.abs() < _minimumBoxZoomExtent ||
          selectionDelta.dy.abs() < _minimumBoxZoomExtent) {
        _resetDragState();
        return;
      }

      // 计算框选区域的数据坐标
      final x1 = widget.viewport.screenToDataX(
        _boxStart!.dx.clamp(
          widget.viewport.marginLeft,
          size.width - widget.viewport.marginRight,
        ),
        size.width,
      );
      final x2 = widget.viewport.screenToDataX(
        _boxEnd!.dx.clamp(
          widget.viewport.marginLeft,
          size.width - widget.viewport.marginRight,
        ),
        size.width,
      );
      final y1 = widget.viewport.screenToDataY(
        _boxStart!.dy.clamp(
          PlotViewport().marginTop,
          size.height - PlotViewport().marginBottom,
        ),
        size.height,
      );
      final y2 = widget.viewport.screenToDataY(
        _boxEnd!.dy.clamp(
          PlotViewport().marginTop,
          size.height - PlotViewport().marginBottom,
        ),
        size.height,
      );

      // 放大到框选区域
      final newViewport = widget.viewport.zoomTo(
        x1 < x2 ? x1 : x2,
        x1 < x2 ? x2 : x1,
        y1 < y2 ? y1 : y2,
        y1 < y2 ? y2 : y1,
      );

      widget.onViewportChanged(newViewport, fromDrag: false);
      widget.onBoxZoomCompleted?.call();
    }

    if (_isDragging &&
        _dragTarget == _DragTarget.none &&
        _dragViewport != null &&
        _shiftZoomAxis != _ShiftZoomAxis.channelY) {
      // 平移拖动结束，确保最终视口被应用并保存
      widget.onViewportChanged(_dragViewport!, fromDrag: true);
      _setViewportInteractionActive(false);
      widget.onDragEnd?.call();
    }
    _resetDragState();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _resetDragState();
  }

  void _resetDragState() {
    _setViewportInteractionActive(false);
    _isDragging = false;
    _isBoxSelecting = false;
    _shiftZoomAxis = _ShiftZoomAxis.none;
    _lastPosition = null;
    _boxStart = null;
    _boxEnd = null;
    _dragTarget = _DragTarget.none;
    _dragViewport = null;
    _shiftZoomCenterX = null;
    _shiftZoomCenterY = null;
    _shiftZoomChannelIndex = null;
    _lastNotifiedViewport = null;
    if (mounted) setState(() {});
  }
}

/// 框选区域绘制器
///
/// 在框选过程中实时绘制半透明蓝色矩形，显示当前框选范围。
class _BoxSelectionPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  _BoxSelectionPainter({required this.start, required this.end});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);

    // 填充
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill,
    );

    // 边框
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
