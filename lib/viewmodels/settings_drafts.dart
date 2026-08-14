import '../services/shell_session.dart';

/// 数据收发显示设置草稿。创建后与运行态完全隔离。
class RawDisplaySettingsDraft {
  RawDisplaySettingsDraft({
    required this.encoding,
    required this.autoLineBreakIntervalMs,
    required this.displayLineLimit,
  });

  String encoding;
  int autoLineBreakIntervalMs;
  int displayLineLimit;
}

/// 普通 Shell 与 SSH 共用的终端显示设置草稿。
class ShellTerminalSettingsDraft {
  ShellTerminalSettingsDraft({
    required this.encoding,
    required this.lineEnding,
    required this.fontSize,
    required this.fontFamily,
    required this.themeMode,
    required this.cursorMode,
    required this.localEcho,
    required this.scrollbackLines,
    required this.sshKeepAliveEnabled,
  });

  String encoding;
  String lineEnding;
  double fontSize;
  String fontFamily;
  RawShellThemeMode themeMode;
  RawShellCursorMode cursorMode;
  bool localEcho;
  int scrollbackLines;
  bool sshKeepAliveEnabled;
}

/// RTT Viewer 文本显示设置草稿。
class RttTerminalSettingsDraft {
  RttTerminalSettingsDraft({
    required this.encoding,
    required this.fontFamily,
    required this.fontSize,
    required this.historyLineLimit,
  });

  String encoding;
  String fontFamily;
  double fontSize;
  int historyLineLimit;
}

/// 串口绘图和探针绘图共享的界面设置草稿。
///
/// 两个 ViewModel 仍分别持有数据、性能和容量状态；此对象只负责弹窗的
/// 一次性编辑事务，不让滑块或开关提前污染外部页面。
class PlotUiSettingsDraft {
  PlotUiSettingsDraft({
    required this.showGrid,
    required this.gridDensity,
    required this.background,
    required this.floatingPanelOpacity,
    required this.fontSizeDelta,
    required this.fontBold,
    required this.followPositionRatio,
    required this.observationClickToPlace,
    required this.quality,
    this.renderEngine,
    required this.windowPointLimit,
    required this.historyLimit,
    this.refreshFps,
    this.yFitDisplayRatio,
    this.keepPlotOnRestart,
    this.discardInitialPacketCount,
    this.previewToolbarEnabled,
    this.triggerToolbarEnabled,
    this.statsToolbarEnabled,
    this.snapHighlightEnabled,
    this.snapHighlightDiameter,
    this.snapHighlightColorMode,
    this.gestureModifier,
    this.showPlotSendDataInRaw,
    this.receiveAggregationEnabled,
  });

  bool showGrid;
  Object gridDensity;
  Object background;
  double floatingPanelOpacity;
  int fontSizeDelta;
  bool fontBold;
  double followPositionRatio;
  bool observationClickToPlace;
  Object? gestureModifier;
  bool? showPlotSendDataInRaw;
  bool? receiveAggregationEnabled;
  Object quality;
  Object? renderEngine;
  int windowPointLimit;
  int historyLimit;
  int? refreshFps;
  double? yFitDisplayRatio;
  bool? keepPlotOnRestart;
  int? discardInitialPacketCount;
  bool? previewToolbarEnabled;
  bool? triggerToolbarEnabled;
  bool? statsToolbarEnabled;
  bool? snapHighlightEnabled;
  double? snapHighlightDiameter;
  String? snapHighlightColorMode;
}

/// 应用高级设置的事务草稿。
///
/// 以稳定设置键保存值，避免设置页状态类再次复制 AppSettings 的全部字段。
/// 保存时由设置页完成类型和业务约束校验后统一应用。
class ApplicationAdvancedSettingsDraft {
  ApplicationAdvancedSettingsDraft(Map<String, Object?> values)
    : _values = Map.of(values);

  final Map<String, Object?> _values;

  T read<T>(String key) => _values[key] as T;
  void write<T>(String key, T value) => _values[key] = value;
  Map<String, Object?> toMap() => Map.unmodifiable(_values);
}
