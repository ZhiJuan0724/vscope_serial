import 'dart:async';
import 'dart:typed_data';

/// 数据源抽象接口
abstract class IDataSource {
  /// 字节流输出
  Stream<Uint8List> get byteStream;

  /// 是否处于活动状态
  bool get isActive;

  /// 启动数据源
  Future<void> start();

  /// 停止数据源
  Future<void> stop();

  /// 数据源名称
  String get name;
}
