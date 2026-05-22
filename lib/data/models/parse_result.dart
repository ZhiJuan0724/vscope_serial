import 'dart:typed_data';

/// 解析结果模型
class ParseResult {
  /// 是否解析成功
  final bool success;

  /// 解析出的各通道值（成功时有效）
  final List<double>? values;

  /// 通道数
  final int? channelCount;

  /// 错误信息（失败时有效）
  final String? error;

  /// 原始字节数（用于统计）
  final int bytesConsumed;

  /// 成功解析出的原始帧字节。
  ///
  /// 高频绘图会把这里的有效帧按原始字节保存，历史回看时再按窗口解析。
  final Uint8List? rawBytes;

  ParseResult({
    required this.success,
    this.values,
    this.channelCount,
    this.error,
    this.bytesConsumed = 0,
    this.rawBytes,
  });

  /// 成功的快捷构造
  factory ParseResult.ok(
    List<double> values, {
    int bytesConsumed = 0,
    Uint8List? rawBytes,
  }) {
    return ParseResult(
      success: true,
      values: values,
      channelCount: values.length,
      bytesConsumed: bytesConsumed,
      rawBytes: rawBytes,
    );
  }

  /// 失败的快捷构造
  factory ParseResult.fail(String error, {int bytesConsumed = 0}) {
    return ParseResult(
      success: false,
      error: error,
      bytesConsumed: bytesConsumed,
    );
  }

  @override
  String toString() {
    if (success) {
      return 'ParseResult(ok, channels=$channelCount, values=$values)';
    } else {
      return 'ParseResult(fail, error=$error)';
    }
  }
}
