/// 容量使用状态；warning 为首次预警，limitReached 表示必须停止继续追加。
enum RetentionState { normal, warning, limitReached }

/// 有界采集缓存的容量快照。
class RetentionUsage {
  final int usedBytes;
  final int limitBytes;
  final RetentionState state;

  const RetentionUsage({
    required this.usedBytes,
    required this.limitBytes,
    required this.state,
  });

  double get ratio => limitBytes <= 0 ? 0 : usedBytes / limitBytes;
  int get remainingBytes => (limitBytes - usedBytes).clamp(0, limitBytes);

  RetentionUsage copyWith({
    int? usedBytes,
    int? limitBytes,
    RetentionState? state,
  }) {
    return RetentionUsage(
      usedBytes: usedBytes ?? this.usedBytes,
      limitBytes: limitBytes ?? this.limitBytes,
      state: state ?? this.state,
    );
  }
}
