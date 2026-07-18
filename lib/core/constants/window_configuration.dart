/// 应用主窗口及其扩展区域共用的尺寸与布局同步配置。
abstract final class WindowConfiguration {
  /// 主窗口允许用户缩放到的最小宽度。
  static const double minWidth = 800;

  /// 主窗口允许用户缩放到的最小高度。
  static const double minHeight = 600;

  /// 应用首次显示时使用的默认宽度。
  static const double defaultWidth = 950;

  /// 应用首次显示时使用的默认高度。
  static const double defaultHeight = 700;

  /// 工作区空间充足时，多条发送扩展面板使用的宽度。
  static const double multiSendPanelWidth = 380;

  /// 工作区空间不足时，多条发送扩展面板保留的最小宽度。
  static const double multiSendPanelMinWidth = 320;
}
