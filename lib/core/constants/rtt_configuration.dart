/// RTT Viewer 的固定容量与批处理参数。
///
/// 这些值同时约束接收积压、显示重建和单帧工作量，修改时需要配套更新
/// RTT 队列与 ViewModel 的边界测试。
abstract final class RttConfiguration {
  /// OpenOCD 检查 RTT Up 通道的默认、最小和最大轮询间隔。
  static const int defaultPollingIntervalMs = 10;
  static const int minPollingIntervalMs = 1;
  static const int maxPollingIntervalMs = 1000;

  /// Flutter 尚未消费的 RTT 原始数据上限；超限后丢弃最早完整块。
  static const int receiveQueueLimitBytes = 64 * 1024 * 1024;

  /// 用于切换编码、文本/HEX 和导出的原始历史上限。
  static const int rawHistoryLimitBytes = 64 * 1024 * 1024;

  /// 每帧从待处理队列取出的最大数据量。
  static const int maxDrainBytesPerFrame = 64 * 1024;

  /// RTT 文本历史默认、最小和最大行数。
  static const int defaultHistoryLines = 100000;
  static const int minHistoryLines = 1000;
  static const int maxHistoryLines = 1000000;

  /// 16 个 SEGGER RTT 虚拟终端的默认标识色。
  ///
  /// 颜色在浅色背景下保持足够对比度，并尽量让相邻终端具有明显色相差异。
  static const List<int> defaultTerminalColors = [
    0xFFD32F2F,
    0xFF1976D2,
    0xFF388E3C,
    0xFFF57C00,
    0xFF7B1FA2,
    0xFF00796B,
    0xFFC2185B,
    0xFF303F9F,
    0xFF5D4037,
    0xFF00838F,
    0xFFE64A19,
    0xFF558B2F,
    0xFF512DA8,
    0xFF455A64,
    0xFFAF6C00,
    0xFF6D7A00,
  ];

  static const List<String> defaultTerminalLabels = [
    'Terminal 0',
    'Terminal 1',
    'Terminal 2',
    'Terminal 3',
    'Terminal 4',
    'Terminal 5',
    'Terminal 6',
    'Terminal 7',
    'Terminal 8',
    'Terminal 9',
    'Terminal 10',
    'Terminal 11',
    'Terminal 12',
    'Terminal 13',
    'Terminal 14',
    'Terminal 15',
  ];
}
