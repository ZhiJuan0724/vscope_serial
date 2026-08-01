import 'data_connection_config.dart';

/// 主页面可见性和数据连接兼容性的纯状态规则。
abstract final class MainPagePolicy {
  static const allPages = [
    'rawData',
    'shell',
    'plot',
    'rtt',
    'probePlot',
    'modbus',
  ];

  static bool supportsDataConnection(String pageId, DataConnectionType type) =>
      switch (type) {
        DataConnectionType.serial =>
          pageId == 'rawData' ||
              pageId == 'shell' ||
              pageId == 'plot' ||
              pageId == 'modbus',
        DataConnectionType.tcpClient =>
          pageId == 'rawData' ||
              pageId == 'shell' ||
              pageId == 'plot' ||
              pageId == 'modbus',
        DataConnectionType.udp => pageId == 'rawData' || pageId == 'plot',
        DataConnectionType.tcpServer => pageId == 'rawData',
      };

  static List<String> addPage(List<String> visible, String pageId) {
    if (!allPages.contains(pageId) || visible.contains(pageId)) return visible;
    return [...visible, pageId];
  }

  /// 重新添加页面时将它移到标签顺序末尾，不恢复隐藏前的位置。
  static List<String> appendPageOrder(List<String> order, String pageId) {
    if (!allPages.contains(pageId)) return order;
    return [...order.where((id) => id != pageId), pageId];
  }

  static List<String> closePage(
    List<String> visible,
    String pageId, {
    required bool connectionBusy,
  }) {
    if (connectionBusy || visible.length <= 1 || !visible.contains(pageId)) {
      return visible;
    }
    return visible.where((id) => id != pageId).toList();
  }
}
