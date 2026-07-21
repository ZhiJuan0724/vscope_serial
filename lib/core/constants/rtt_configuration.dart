/// RTT Viewer 的固定容量与批处理参数。
///
/// 这些值同时约束接收积压、显示重建和单帧工作量，修改时需要配套更新
/// RTT 队列与 ViewModel 的边界测试。
abstract final class RttConfiguration {
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
}
