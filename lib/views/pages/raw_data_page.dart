import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/window_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../core/utils/crc.dart';
import '../../data/models/retention_usage.dart';
import '../../viewmodels/multi_send_viewmodel.dart';
import '../../services/app_notifications.dart';
import '../../services/serial_service.dart';
import '../../viewmodels/raw_data_viewmodel.dart';
import '../widgets/common_widgets.dart';
import '../widgets/hex_input_formatter.dart';
import '../widgets/multi_send_panel.dart';

enum _RawDataExportFormat { text, rawBytes }

/// 扩展面板与原生窗口尺寸同步的过渡状态。
///
/// Flutter 内容只能在窗口宽度已同步后显示，避免用户看到窄窗口中先闪现扩展面板。
enum _MultiSendPanelState { closed, opening, open, closing }

typedef _ReceiveAreaState =
    ({
      int displayRevision,
      bool connected,
      bool receiving,
      bool receiveHex,
      bool showTimestamp,
      bool autoLineBreak,
      bool autoScroll,
      bool hasRawData,
      String textEncoding,
      int retentionUsedBytes,
      int retentionLimitBytes,
      RetentionState retentionState,
    });

typedef _SendAreaState =
    ({
      bool connected,
      bool rawReceiving,
      bool multiSendRunning,
      bool keepText,
      bool appendLineEnding,
      String lineEnding,
      bool sendHex,
      bool enableCrc,
      CrcType crcType,
      String crcPolyName,
      CrcByteOrder crcByteOrder,
    });

/// 数据收发页面
/// 原始数据收发页面，包含显示区、发送区和可选多条发送扩展区。
class RawDataPage extends StatefulWidget {
  const RawDataPage({super.key});

  @override
  State<RawDataPage> createState() => _RawDataPageState();
}

class _RawDataPageState extends State<RawDataPage> {
  /// 等待原生窗口尺寸同步到 Flutter 布局时的轮询间隔。
  static const Duration _windowLayoutSyncInterval = Duration(milliseconds: 16);

  /// 等待原生窗口尺寸同步到 Flutter 布局时的最大轮询次数。
  static const int _windowLayoutSyncMaxAttempts = 60;

  /// 判断 Flutter 布局宽度已同步到目标宽度时允许的像素误差。
  static const double _windowLayoutSyncTolerance = 2;

  /// 发送区必须容纳设置行、输入框和发送按钮，拖动分隔条时不得低于该高度。
  static const double _minimumSendAreaHeight = 200;

  /// 接收区与发送区之间可拖动分隔条的固定高度。
  static const double _splitDividerHeight = 8;

  /// 接收显示选项启用时统一使用橙色，与绘图工具栏的活动状态保持一致。
  static const Color _receiveOptionActiveColor = Colors.orange;

  static const TextStyle _receiveLineStyle = TextStyle(
    fontFamily: 'SarasaUiSC',
    fontSize: 13,
  );

  final TextEditingController _sendController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _autoScrollScheduled = false;
  int _handledDisplayTrimRevision = 0;
  double _splitRatio = 0.65;
  _MultiSendPanelState _multiSendPanelState = _MultiSendPanelState.closed;
  Rect? _multiSendOriginalBounds;
  bool _multiSendWasMaximized = false;
  double _multiSendPanelWidth = WindowConfiguration.multiSendPanelWidth;
  double _multiSendMinimumWindowWidth = WindowConfiguration.minWidth;
  double _multiSendTransitionContentWidth = WindowConfiguration.minWidth;
  double _rawPageLayoutWidth = WindowConfiguration.minWidth;
  MultiSendViewModel? _multiSendVm;

  bool get _multiSendVisible =>
      _multiSendPanelState != _MultiSendPanelState.closed;

  /// 扩展内容只在原生窗口和 Flutter 布局均到位后挂载。
  ///
  /// opening/closing 期间保留空白过渡区，避免面板先在旧宽度内
  /// 挤压主内容，随后又跳到新窗口区域。
  bool get _multiSendPanelMounted =>
      _multiSendPanelState == _MultiSendPanelState.open;

  bool get _multiSendTransitioning =>
      _multiSendPanelState == _MultiSendPanelState.opening ||
      _multiSendPanelState == _MultiSendPanelState.closing;

  @override
  void dispose() {
    if (_multiSendVisible || _multiSendOriginalBounds != null) {
      unawaited(_closeMultiSendBeforePageLeave(updateUi: false));
    }
    _sendController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openMultiSendPanel(MultiSendViewModel multiSendVm) async {
    // 先扩大原生窗口，再把 Flutter 面板切为可见，防止窄布局瞬间溢出。
    if (_multiSendPanelState != _MultiSendPanelState.closed) return;
    _multiSendVm = multiSendVm;
    _multiSendTransitionContentWidth = _rawPageLayoutWidth;
    if (mounted) {
      setState(() {
        _multiSendPanelState = _MultiSendPanelState.opening;
      });
    } else {
      _multiSendPanelState = _MultiSendPanelState.opening;
    }
    var opened = false;
    try {
      await _multiSendVm!.initialize();
      _multiSendWasMaximized = await windowManager.isMaximized();
      if (_multiSendWasMaximized) {
        await windowManager.unmaximize();
        await WidgetsBinding.instance.endOfFrame;
      }
      _multiSendOriginalBounds = await windowManager.getBounds();
      final bounds = _multiSendOriginalBounds!;
      final expanded = await _multiSendExpandedBounds(bounds);
      _multiSendTransitionContentWidth = _rawPageLayoutWidth;
      if (mounted) {
        setState(() {});
        await WidgetsBinding.instance.endOfFrame;
      }
      final targetLayoutWidth =
          _windowLayoutWidth + expanded.width - bounds.width;
      await windowManager.setBounds(expanded, animate: false);
      await _waitForWindowLayoutWidth(targetLayoutWidth, expanding: true);
      await windowManager.setMinimumSize(
        Size(_multiSendMinimumWindowWidth, WindowConfiguration.minHeight),
      );
      opened = true;
    } catch (_) {
      try {
        await windowManager.setMinimumSize(
          const Size(
            WindowConfiguration.minWidth,
            WindowConfiguration.minHeight,
          ),
        );
        final originalBounds = _multiSendOriginalBounds;
        if (originalBounds != null) {
          await windowManager.setBounds(originalBounds, animate: false);
        }
      } catch (_) {
        // 回滚失败时仍需结束过渡状态。
      }
    } finally {
      final nextState =
          opened ? _MultiSendPanelState.open : _MultiSendPanelState.closed;
      if (mounted) {
        setState(() => _multiSendPanelState = nextState);
      } else {
        _multiSendPanelState = nextState;
      }
    }
  }

  Future<void> _closeMultiSendBeforePageLeave({bool updateUi = true}) async {
    while (_multiSendTransitioning) {
      await Future<void>.delayed(_windowLayoutSyncInterval);
    }
    await _closeMultiSendPanel(updateUi: updateUi);
  }

  Future<void> _closeMultiSendPanel({bool updateUi = true}) async {
    // 关闭时只恢复打开前的宽度；用户在面板打开后修改的高度必须保留。
    if (_multiSendPanelState != _MultiSendPanelState.open &&
        _multiSendOriginalBounds == null) {
      return;
    }
    final currentLayoutWidth = _windowLayoutWidth;
    _multiSendTransitionContentWidth = math.max(
      0.0,
      _rawPageLayoutWidth - _multiSendPanelWidth,
    );
    if (updateUi && mounted) {
      setState(() {
        _multiSendPanelState = _MultiSendPanelState.closing;
      });
      await WidgetsBinding.instance.endOfFrame;
    } else {
      _multiSendPanelState = _MultiSendPanelState.closing;
    }
    _multiSendVm?.stop();
    final restoreMaximized = _multiSendWasMaximized;
    Rect? currentBounds;
    try {
      currentBounds = await windowManager.getBounds();
    } catch (_) {
      // 即使边界读取失败，也必须继续恢复普通窗口最小宽度。
    }
    try {
      await windowManager.setMinimumSize(
        const Size(WindowConfiguration.minWidth, WindowConfiguration.minHeight),
      );
    } catch (_) {
      // 后续仍尝试恢复窗口几何。
    }
    try {
      if (restoreMaximized) {
        await windowManager.maximize();
        await WidgetsBinding.instance.endOfFrame;
      } else if (currentBounds != null) {
        final collapsedBounds = Rect.fromLTWH(
          currentBounds.left,
          currentBounds.top,
          math.max(
            WindowConfiguration.minWidth,
            currentBounds.width - _multiSendPanelWidth,
          ),
          currentBounds.height,
        );
        await windowManager.setBounds(collapsedBounds, animate: false);
        await _waitForWindowLayoutWidth(
          currentLayoutWidth - _multiSendPanelWidth,
          expanding: false,
        );
      }
    } catch (_) {
      // 面板仍需正常关闭，窗口管理失败不阻止用户继续收发。
    } finally {
      _multiSendOriginalBounds = null;
      _multiSendWasMaximized = false;
      _multiSendPanelWidth = WindowConfiguration.multiSendPanelWidth;
      _multiSendMinimumWindowWidth = WindowConfiguration.minWidth;
      if (updateUi && mounted) {
        setState(() {
          _multiSendPanelState = _MultiSendPanelState.closed;
        });
      } else {
        _multiSendPanelState = _MultiSendPanelState.closed;
      }
    }
  }

  Future<void> _waitForWindowLayoutWidth(
    double targetWidth, {
    required bool expanding,
  }) async {
    for (
      var attempt = 0;
      attempt < _windowLayoutSyncMaxAttempts && mounted;
      attempt++
    ) {
      final width = _windowLayoutWidth;
      if (expanding
          ? width >= targetWidth - _windowLayoutSyncTolerance
          : width <= targetWidth + _windowLayoutSyncTolerance) {
        return;
      }
      await Future<void>.delayed(_windowLayoutSyncInterval);
    }
  }

  double get _windowLayoutWidth {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  Future<Rect> _multiSendExpandedBounds(Rect bounds) async {
    final displays = await screenRetriever.getAllDisplays();
    final center = bounds.center;
    final display = displays.firstWhere((item) {
      final position = item.visiblePosition ?? Offset.zero;
      final size = item.visibleSize ?? item.size;
      return Rect.fromLTWH(
        position.dx,
        position.dy,
        size.width,
        size.height,
      ).contains(center);
    }, orElse: () => displays.first);
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    final workArea = Rect.fromLTWH(
      position.dx,
      position.dy,
      size.width,
      size.height,
    );
    final leftContentWidth = math.max(
      WindowConfiguration.minWidth,
      bounds.width,
    );
    _multiSendPanelWidth =
        leftContentWidth + WindowConfiguration.multiSendPanelWidth <=
                workArea.width
            ? WindowConfiguration.multiSendPanelWidth
            : WindowConfiguration.multiSendPanelMinWidth;
    _multiSendMinimumWindowWidth = math.min(
      leftContentWidth + _multiSendPanelWidth,
      workArea.width,
    );
    final width = _multiSendMinimumWindowWidth.clamp(
      _multiSendPanelWidth,
      workArea.width,
    );
    final height = bounds.height.clamp(
      WindowConfiguration.minHeight,
      workArea.height,
    );
    final left = (bounds.left + width > workArea.right
            ? workArea.right - width
            : bounds.left)
        .clamp(workArea.left, workArea.right - width);
    final top = bounds.top.clamp(workArea.top, workArea.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  void _scrollToBottom(RawDataViewModel vm) {
    if (!vm.autoScroll || _autoScrollScheduled) return;

    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !vm.autoScroll || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _preserveScrollAfterTrim(
    BuildContext context,
    RawDataViewModel vm,
    double lineWidth,
  ) {
    if (_handledDisplayTrimRevision == vm.displayTrimRevision) return;
    _handledDisplayTrimRevision = vm.displayTrimRevision;
    if (vm.autoScroll ||
        vm.lastTrimmedDisplayLines.isEmpty ||
        !_scrollController.hasClients) {
      return;
    }

    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    // 多行合并为一次文本布局。串口突发数据可能在一帧内淘汰大量旧行，
    // 逐行创建 TextPainter 会把滚动保持本身变成 UI 卡顿源。
    final removedText = vm.lastTrimmedDisplayLines
        .map((line) => line.isEmpty ? ' ' : line)
        .join('\n');
    final painter = TextPainter(
      text: TextSpan(text: removedText, style: _receiveLineStyle),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: lineWidth);
    final removedHeight = painter.height;

    final previousOffset = _scrollController.offset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || vm.autoScroll || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = (previousOffset - removedHeight).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      position.jumpTo(target);
    });
  }

  int _getHexByteCount(String text) {
    final hexString = text.replaceAll(' ', '');
    if (hexString.isEmpty) return 0;
    return (hexString.length / 2).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final service = Provider.of<SerialService>(context, listen: false);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RawDataViewModel(service)),
        ChangeNotifierProvider(create: (_) => MultiSendViewModel(service)),
      ],
      child: Builder(
        builder: (context) {
          final vm = context.read<RawDataViewModel>();
          _scrollToBottom(vm);
          return LayoutBuilder(
            builder: (context, constraints) {
              _rawPageLayoutWidth = constraints.maxWidth;
              final contentWidth = switch (_multiSendPanelState) {
                _MultiSendPanelState.closed => constraints.maxWidth,
                _MultiSendPanelState.opening || _MultiSendPanelState.closing =>
                  _multiSendTransitionContentWidth,
                _MultiSendPanelState.open => math.max(
                  0.0,
                  constraints.maxWidth - _multiSendPanelWidth,
                ),
              };
              final pageHeight = constraints.maxHeight;
              final maximumReceiveHeight = math.max(
                0.0,
                pageHeight - _splitDividerHeight - _minimumSendAreaHeight,
              );
              final minimumReceiveHeight = math.min(
                pageHeight * 0.2,
                maximumReceiveHeight,
              );
              final receiveHeight = (pageHeight * _splitRatio).clamp(
                minimumReceiveHeight,
                maximumReceiveHeight,
              );
              return ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: contentWidth,
                      child: SizedBox(
                        key: const ValueKey('raw-data-main-content'),
                        child: Column(
                          children: [
                            SizedBox(
                              key: const ValueKey('raw-receive-area'),
                              height: receiveHeight,
                              child: Selector<
                                RawDataViewModel,
                                _ReceiveAreaState
                              >(
                                selector:
                                    (_, value) => (
                                      displayRevision: value.displayRevision,
                                      connected: value.isConnected,
                                      receiving: value.isRawReceiving,
                                      receiveHex: value.receiveHex,
                                      showTimestamp: value.showTimestamp,
                                      autoLineBreak: value.autoLineBreak,
                                      autoScroll: value.autoScroll,
                                      hasRawData: value.hasRawData,
                                      textEncoding: value.textEncoding,
                                      retentionUsedBytes:
                                          value.rawRetentionUsage.usedBytes,
                                      retentionLimitBytes:
                                          value.rawRetentionUsage.limitBytes,
                                      retentionState:
                                          value.rawRetentionUsage.state,
                                    ),
                                builder: (context, _, _) {
                                  final receiveVm =
                                      context.read<RawDataViewModel>();
                                  _scrollToBottom(receiveVm);
                                  return _buildReceiveArea(
                                    receiveVm,
                                    context.read<MultiSendViewModel>(),
                                  );
                                },
                              ),
                            ),
                            GestureDetector(
                              key: const ValueKey('raw-split-divider'),
                              behavior: HitTestBehavior.translucent,
                              onVerticalDragUpdate: (details) {
                                setState(() {
                                  final delta = details.delta.dy / pageHeight;
                                  final maximumSplitRatio =
                                      maximumReceiveHeight / pageHeight;
                                  _splitRatio = (_splitRatio + delta).clamp(
                                    minimumReceiveHeight / pageHeight,
                                    maximumSplitRatio,
                                  );
                                });
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeRow,
                                child: Container(
                                  height: _splitDividerHeight,
                                  color: Theme.of(
                                    context,
                                  ).dividerColor.withValues(alpha: 0.5),
                                  child: Center(
                                    child: Container(
                                      width: 40,
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              key: const ValueKey('raw-send-area'),
                              child: Selector2<
                                RawDataViewModel,
                                MultiSendViewModel,
                                _SendAreaState
                              >(
                                selector:
                                    (_, rawVm, multiSendVm) => (
                                      connected: rawVm.isConnected,
                                      rawReceiving: rawVm.isRawReceiving,
                                      multiSendRunning: multiSendVm.isRunning,
                                      keepText: rawVm.keepSendText,
                                      appendLineEnding: rawVm.appendLineEnding,
                                      lineEnding: rawVm.lineEnding,
                                      sendHex: rawVm.sendHex,
                                      enableCrc: rawVm.enableCrc,
                                      crcType: rawVm.crcType,
                                      crcPolyName: rawVm.crcPolyName,
                                      crcByteOrder: rawVm.crcByteOrder,
                                    ),
                                builder:
                                    (context, _, _) => _buildSendArea(
                                      context.read<RawDataViewModel>(),
                                      context.read<MultiSendViewModel>(),
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_multiSendPanelMounted)
                      Positioned(
                        left: contentWidth,
                        top: 0,
                        bottom: 0,
                        width: _multiSendPanelWidth,
                        child: Container(
                          key: const ValueKey('multi-send-panel'),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: Theme.of(context).dividerColor,
                              ),
                            ),
                          ),
                          child: MultiSendPanel(
                            onClose: () => unawaited(_closeMultiSendPanel()),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildReceiveArea(
    RawDataViewModel vm,
    MultiSendViewModel multiSendVm,
  ) {
    final retention = vm.rawRetentionUsage;
    final retentionStatus = switch (retention.state) {
      RetentionState.normal => '',
      RetentionState.warning => ' [容量预警]',
      RetentionState.limitReached => ' [容量上限停止，请导出并清空]',
    };
    final retentionColor = switch (retention.state) {
      RetentionState.normal => Theme.of(context).colorScheme.onSurfaceVariant,
      RetentionState.warning => Colors.orange.shade800,
      RetentionState.limitReached => Theme.of(context).colorScheme.error,
    };
    return Column(
      children: [
        UnifiedToolbar(
          leadingItems: [
            ToolbarLayoutItem(
              extent: 76,
              child: ToolbarStartStopButton(
                key: const ValueKey('raw-start-stop-button'),
                onPressed:
                    vm.isRawReceiving
                        ? () {
                          // 停止接收时同步取消多条发送，当前写入完成后不再调度下一条。
                          multiSendVm.stop();
                          vm.stopReceiving();
                          multiSendVm.refreshSendAvailability();
                        }
                        : vm.isConnected &&
                            retention.state != RetentionState.limitReached
                        ? () {
                          vm.startReceiving();
                          multiSendVm.refreshSendAvailability();
                        }
                        : null,
                running: vm.isRawReceiving,
                label: vm.isRawReceiving ? '停止' : '开始',
              ),
            ),
            ToolbarLayoutItem(
              extent: 76,
              child: ToolbarToggleTextButton(
                icon: const Icon(Icons.schedule),
                label: AppStrings.raw.timestamp,
                tooltip: AppStrings.raw.timestamp,
                selected: vm.showTimestamp,
                activeColor: _receiveOptionActiveColor,
                onPressed: () => vm.setShowTimestamp(!vm.showTimestamp),
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.schedule),
                  label: AppStrings.raw.timestamp,
                  selected: vm.showTimestamp,
                  onPressed: () => vm.setShowTimestamp(!vm.showTimestamp),
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: 88,
              child: ToolbarToggleTextButton(
                icon: const Icon(Icons.wrap_text),
                label: AppStrings.raw.autoLineBreak,
                tooltip: AppStrings.raw.autoLineBreak,
                selected: vm.autoLineBreak,
                activeColor: _receiveOptionActiveColor,
                onPressed: () => vm.setAutoLineBreak(!vm.autoLineBreak),
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.wrap_text),
                  label: AppStrings.raw.autoLineBreak,
                  selected: vm.autoLineBreak,
                  onPressed: () => vm.setAutoLineBreak(!vm.autoLineBreak),
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: 82,
              child: ToolbarToggleTextButton(
                icon: const Icon(Icons.numbers),
                label: AppStrings.raw.hexDisplay,
                tooltip: AppStrings.raw.hexDisplay,
                selected: vm.receiveHex,
                activeColor: _receiveOptionActiveColor,
                onPressed: () => vm.setReceiveHex(!vm.receiveHex),
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.numbers),
                  label: AppStrings.raw.hexDisplay,
                  selected: vm.receiveHex,
                  onPressed: () => vm.setReceiveHex(!vm.receiveHex),
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: 88,
              child: ToolbarToggleTextButton(
                icon: const Icon(Icons.vertical_align_bottom),
                label: AppStrings.raw.autoScroll,
                tooltip: AppStrings.raw.autoScroll,
                selected: vm.autoScroll,
                activeColor: _receiveOptionActiveColor,
                onPressed: () => vm.setAutoScroll(!vm.autoScroll),
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.vertical_align_bottom),
                  label: AppStrings.raw.autoScroll,
                  selected: vm.autoScroll,
                  onPressed: () => vm.setAutoScroll(!vm.autoScroll),
                ),
              ],
            ),
          ],
          trailingItems: [
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                icon: const Icon(Icons.clear),
                tooltip: AppStrings.raw.clear,
                onPressed: vm.clearData,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.clear),
                  label: AppStrings.raw.clear,
                  onPressed: vm.clearData,
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarIconButton(
                key: const ValueKey('raw-data-export-button'),
                icon: const Icon(Icons.save),
                tooltip: AppStrings.common.save,
                onPressed:
                    vm.hasRawData ? () => _showExportDialog(context, vm) : null,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  key: const ValueKey('raw-data-export-menu-item'),
                  icon: const Icon(Icons.save),
                  label: AppStrings.common.save,
                  onPressed:
                      vm.hasRawData
                          ? () => _showExportDialog(context, vm)
                          : null,
                ),
              ],
            ),
            ToolbarLayoutItem(
              extent: kToolbarControlExtent,
              child: ToolbarAdvancedSettingsButton(
                onPressed: () => _showRawAdvancedSettingsDialog(context, vm),
                tooltip: AppStrings.raw.rawSettingsTitle,
              ),
              overflowActions: [
                ToolbarOverflowAction(
                  icon: const Icon(Icons.tune),
                  label: AppStrings.raw.rawSettingsTitle,
                  onPressed: () => _showRawAdvancedSettingsDialog(context, vm),
                ),
              ],
            ),
          ],
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(4.0),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 数据列表或提示文字
                vm.receivedLines.isNotEmpty
                    ? LayoutBuilder(
                      builder: (context, constraints) {
                        _preserveScrollAfterTrim(
                          context,
                          vm,
                          constraints.maxWidth,
                        );
                        return SelectionArea(
                          key: const Key('rawDataReceiveTextField'),
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.only(bottom: 28),
                            itemCount: vm.receivedLines.length,
                            itemBuilder:
                                (context, index) => Text(
                                  vm.receivedLines[index],
                                  softWrap: true,
                                  style: _receiveLineStyle,
                                ),
                          ),
                        );
                      },
                    )
                    : const Center(
                      child: Text(
                        '点击"开始"按钮开始接收/发送数据',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ),
                if (vm.hasRawData)
                  // 右下角统计信息
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      key: const ValueKey('raw-data-stats-overlay'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        vm.receiveHex
                            ? '接收: ${vm.dataStats['完整原始数据']} | 容量: ${vm.dataStats['原始数据容量']}$retentionStatus | 行数: ${vm.dataStats['显示行数']} | 缓存: ${vm.dataStats['显示文本缓存']}'
                            : '编码: ${vm.textEncoding} | 原始容量: ${vm.dataStats['原始数据容量']}$retentionStatus | 行数: ${vm.dataStats['显示行数']} | 缓存: ${vm.dataStats['显示文本缓存']}',
                        style: TextStyle(fontSize: 11, color: retentionColor),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendArea(RawDataViewModel vm, MultiSendViewModel multiSendVm) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // 左侧标题固定左对齐，右侧选项在空间不足时独立换行。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.raw.sendData,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 10),
                  Checkbox(
                    key: const ValueKey('multi-send-toggle'),
                    value: _multiSendVisible,
                    onChanged:
                        _multiSendTransitioning
                            ? null
                            : (value) {
                              if (value ?? false) {
                                unawaited(_openMultiSendPanel(multiSendVm));
                              } else {
                                unawaited(_closeMultiSendPanel());
                              }
                            },
                  ),
                  const Text('扩展'),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: vm.keepSendText,
                          onChanged: (value) => vm.setKeepSendText(value!),
                        ),
                        Text(AppStrings.raw.keepAfterSend),
                      ],
                    ),
                    const SizedBox(width: 8),
                    if (!vm.sendHex) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: vm.appendLineEnding,
                            onChanged:
                                (value) => vm.setAppendLineEnding(value!),
                          ),
                          Text(AppStrings.raw.appendLineEnding),
                        ],
                      ),
                      const SizedBox(width: 8),
                      ToolbarDropdown<String>(
                        width: 90,
                        value: vm.lineEnding,
                        hint: AppStrings.raw.lineEndingHint,
                        items: const [
                          DropdownMenuItem(value: '\r', child: Text(r'\r')),
                          DropdownMenuItem(value: '\n', child: Text(r'\n')),
                          DropdownMenuItem(value: '\r\n', child: Text(r'\r\n')),
                        ],
                        onChanged:
                            vm.appendLineEnding
                                ? (value) {
                                  if (value != null) vm.setLineEnding(value);
                                }
                                : null,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: vm.sendHex,
                          onChanged: (value) => vm.setSendHex(value!),
                        ),
                        Text(AppStrings.raw.sendHex),
                      ],
                    ),
                    if (vm.sendHex) ...[
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: vm.enableCrc,
                            onChanged: (value) => vm.setEnableCrc(value!),
                          ),
                          const Text('CRC'),
                        ],
                      ),
                      if (vm.enableCrc) ...[
                        const SizedBox(width: 4),
                        ToolbarDropdown<CrcType>(
                          width: 90,
                          value: vm.crcType,
                          hint: AppStrings.raw.crcTypeHint,
                          items: const [
                            DropdownMenuItem(
                              value: CrcType.crc8,
                              child: Text('CRC-8'),
                            ),
                            DropdownMenuItem(
                              value: CrcType.crc16,
                              child: Text('CRC-16'),
                            ),
                            DropdownMenuItem(
                              value: CrcType.crc32,
                              child: Text('CRC-32'),
                            ),
                          ],
                          onChanged: (value) => vm.setCrcType(value!),
                        ),
                        const SizedBox(width: 4),
                        ToolbarDropdown<String>(
                          width: 140,
                          value: vm.crcPolyName,
                          hint: AppStrings.raw.crcPolynomialHint,
                          items:
                              getPolysByType(vm.crcType).keys.map((name) {
                                return DropdownMenuItem(
                                  value: name,
                                  child: Tooltip(
                                    message: name,
                                    child: Text(
                                      name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                );
                              }).toList(),
                          onChanged: (value) => vm.setCrcPolyName(value!),
                        ),
                        const SizedBox(width: 4),
                        ToolbarDropdown<CrcByteOrder>(
                          width: 92,
                          value: vm.crcByteOrder,
                          hint: AppStrings.raw.byteOrderHint,
                          items:
                              CrcByteOrder.values.map((order) {
                                return DropdownMenuItem(
                                  value: order,
                                  child: Text(order.label),
                                );
                              }).toList(),
                          onChanged: (value) => vm.setCrcByteOrder(value!),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 输入区域
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      TextField(
                        controller: _sendController,
                        decoration: InputDecoration(
                          hintText:
                              vm.sendHex
                                  ? AppStrings.raw.sendHexHint
                                  : AppStrings.raw.sendTextHint,
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        maxLines: null,
                        expands: true,
                        enabled: true,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        inputFormatters:
                            vm.sendHex ? const [HexInputFormatter()] : null,
                        onChanged: (value) {
                          if (vm.sendHex) {
                            _formatHexInput(value);
                          }
                          setState(() {});
                        },
                      ),
                      // 右下角长度显示
                      Positioned(
                        right: 8,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            vm.sendHex
                                ? '${_getHexByteCount(_sendController.text)} bytes'
                                : '${_sendController.text.length} chars',
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  key: const ValueKey('raw-send-button'),
                  onPressed:
                      vm.isConnected &&
                              vm.isRawReceiving &&
                              !multiSendVm.isRunning
                          ? () async {
                            // 自动发送开始后立即拒绝手动入口，避免状态切换帧内重复发送。
                            if (!vm.isRawReceiving || multiSendVm.isRunning) {
                              return;
                            }
                            final data = vm.prepareSendData(
                              _sendController.text,
                            );
                            if (data != null) {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await vm.send(data);
                                if (!mounted) return;
                                if (!vm.keepSendText) {
                                  _sendController.clear();
                                  setState(() {});
                                }
                              } catch (e) {
                                if (!mounted) return;
                                AppNotifications.show(
                                  e.toString(),
                                  messenger: messenger,
                                );
                              }
                            }
                          }
                          : null,
                  icon: const Icon(Icons.send),
                  label: Text(AppStrings.raw.send),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, RawDataViewModel vm) {
    if (!vm.hasRawData) return;
    showDialog(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.raw.saveDataTitle),
            content: Text(AppStrings.raw.chooseSaveFormat),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton.icon(
                key: const ValueKey('raw-data-export-text-option'),
                onPressed:
                    () => _startRawDataExport(
                      context,
                      dialogContext,
                      vm,
                      _RawDataExportFormat.text,
                    ),
                icon: const Icon(Icons.description),
                label: Text(AppStrings.raw.textFileFormat),
              ),
              ElevatedButton.icon(
                key: const ValueKey('raw-data-export-bin-option'),
                onPressed:
                    () => _startRawDataExport(
                      context,
                      dialogContext,
                      vm,
                      _RawDataExportFormat.rawBytes,
                    ),
                icon: const Icon(Icons.memory),
                label: Text(AppStrings.raw.rawBytesFormat),
              ),
            ],
          ),
    );
  }

  Future<void> _startRawDataExport(
    BuildContext pageContext,
    BuildContext formatDialogContext,
    RawDataViewModel vm,
    _RawDataExportFormat format,
  ) async {
    Navigator.of(formatDialogContext).pop();
    final outputPath = await file_picker.FilePicker.getDirectoryPath(
      dialogTitle: AppStrings.raw.chooseExportDirectory,
    );
    if (!pageContext.mounted || !vm.hasRawData) return;
    if (outputPath == null || !pageContext.mounted || !vm.hasRawData) return;

    final progress = ValueNotifier<double>(0);
    final progressDialog = showDialog<void>(
      context: pageContext,
      barrierDismissible: false,
      builder:
          (dialogContext) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.raw.exportingData),
            content: SizedBox(
              width: 360,
              child: ValueListenableBuilder<double>(
                valueListenable: progress,
                builder:
                    (context, value, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LinearProgressIndicator(value: value),
                        const SizedBox(height: 12),
                        Text(
                          value < 0.05
                              ? AppStrings.raw.preparingExport
                              : value < 0.2
                              ? format == _RawDataExportFormat.text
                                  ? AppStrings.raw.decodingExportText
                                  : AppStrings.raw.buildingRawExport
                              : AppStrings.raw.writingExportFile,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.raw.exportProgressPercent(value),
                          textAlign: TextAlign.right,
                        ),
                      ],
                    ),
              ),
            ),
          ),
    );

    try {
      final directory = Directory(outputPath);
      final path =
          format == _RawDataExportFormat.text
              ? await vm.exportAsText(
                outputDirectory: directory,
                onProgress: (value) => progress.value = value,
              )
              : await vm.exportAsRawBytes(
                outputDirectory: directory,
                onProgress: (value) => progress.value = value,
              );
      if (!pageContext.mounted) return;
      if (path != null) {
        _showSnackBar(
          pageContext,
          format == _RawDataExportFormat.text
              ? '${AppStrings.raw.savedTextPrefix}: $path'
              : '${AppStrings.raw.savedRawPrefix}: $path',
        );
      }
    } catch (error) {
      if (pageContext.mounted) {
        _showSnackBar(pageContext, error.toString());
      }
    } finally {
      progress.dispose();
      if (pageContext.mounted) {
        Navigator.of(pageContext, rootNavigator: true).pop();
      }
      await progressDialog;
    }
  }

  void _showSnackBar(BuildContext context, String message) {
    AppNotifications.show(message, messenger: ScaffoldMessenger.of(context));
  }

  void _formatHexInput(String value) {
    final newText = formatHexByteGroups(value);
    if (newText != value) {
      _sendController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _showRawAdvancedSettingsDialog(
    BuildContext context,
    RawDataViewModel vm,
  ) {
    final autoLineBreakTimeController = TextEditingController(
      text: vm.autoLineBreakIntervalMs.toString(),
    );
    final displayLineLimitController = TextEditingController(
      text: vm.displayLineLimit.toString(),
    );
    final scrollController = ScrollController();
    final encodingSectionKey = GlobalKey();
    final autoLineBreakTimingSectionKey = GlobalKey();
    final displayLimitSectionKey = GlobalKey();
    var selectedEncoding = vm.textEncoding;
    showDialog<void>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  shape: kAdvancedSettingsDialogShape,
                  title: Text(AppStrings.raw.rawSettingsTitle),
                  content: SettingsNavigationView(
                    scrollController: scrollController,
                    items: [
                      SettingsNavigationItem(
                        label: '文本编码',
                        anchorKey: encodingSectionKey,
                      ),
                      SettingsNavigationItem(
                        label: '自动换行时间',
                        anchorKey: autoLineBreakTimingSectionKey,
                      ),
                      SettingsNavigationItem(
                        label: '显示行数',
                        anchorKey: displayLimitSectionKey,
                      ),
                    ],
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          key: encodingSectionKey,
                          AppStrings.raw.textEncoding,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: kSecondaryDialogWideFieldWidth,
                          child: NoAnimDropdown<String>(
                            value: selectedEncoding,
                            hint: AppStrings.raw.encodingHint,
                            decoration: secondaryDialogFieldDecoration(),
                            items:
                                RawDataViewModel.availableEncodings.map((e) {
                                  return DropdownMenuItem(
                                    value: e['id'],
                                    child: Text(e['name']!),
                                  );
                                }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => selectedEncoding = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.raw.textEncodingHelp,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Divider(height: 24),
                        Text(
                          key: autoLineBreakTimingSectionKey,
                          AppStrings.raw.autoLineBreakTime,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: kSecondaryDialogWideFieldWidth,
                          child: TextField(
                            controller: autoLineBreakTimeController,
                            decoration: secondaryDialogFieldDecoration(
                              hintText: '1 ~ 10000',
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.raw.autoLineBreakTimeHelp,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Divider(height: 24),
                        Text(
                          key: displayLimitSectionKey,
                          AppStrings.raw.displayLineLimit,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: kSecondaryDialogWideFieldWidth,
                          child: TextField(
                            controller: displayLineLimitController,
                            decoration: secondaryDialogFieldDecoration(
                              hintText: '100 ~ 100000',
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.raw.displayLineLimitHelp,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(AppStrings.common.cancel),
                    ),
                    DialogPrimaryActionButton(
                      onPressed: () {
                        final autoLineBreakIntervalMs = int.tryParse(
                          autoLineBreakTimeController.text,
                        );
                        final displayLineLimit = int.tryParse(
                          displayLineLimitController.text,
                        );
                        if (autoLineBreakIntervalMs == null ||
                            autoLineBreakIntervalMs <
                                SerialService.minAutoLineBreakIntervalMs ||
                            autoLineBreakIntervalMs >
                                SerialService.maxAutoLineBreakIntervalMs) {
                          _showSnackBar(
                            context,
                            AppStrings.raw.autoLineBreakTimeInvalid,
                          );
                          return;
                        }
                        if (displayLineLimit == null ||
                            displayLineLimit <
                                SerialService.minDisplayLineLimit ||
                            displayLineLimit >
                                SerialService.maxDisplayLineLimit) {
                          _showSnackBar(
                            context,
                            AppStrings.raw.displayLineLimitInvalid,
                          );
                          return;
                        }

                        final changed =
                            autoLineBreakIntervalMs !=
                                vm.autoLineBreakIntervalMs ||
                            displayLineLimit != vm.displayLineLimit ||
                            selectedEncoding != vm.textEncoding;
                        if (changed) {
                          vm.setTextEncoding(selectedEncoding);
                          vm.setAutoLineBreakIntervalMs(
                            autoLineBreakIntervalMs,
                          );
                          vm.setDisplayLineLimit(displayLineLimit);
                        }
                        Navigator.of(context).pop();
                        if (changed) {
                          _showSnackBar(
                            context,
                            AppStrings.raw.advancedSettingsSaved(
                              displayLineLimit,
                            ),
                          );
                        }
                      },
                      label: AppStrings.common.confirm,
                    ),
                  ],
                ),
          ),
    ).whenComplete(() {
      autoLineBreakTimeController.dispose();
      displayLineLimitController.dispose();
      scrollController.dispose();
    });
  }
}
