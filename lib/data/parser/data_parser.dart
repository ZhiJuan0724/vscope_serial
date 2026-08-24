import 'dart:async';
import 'dart:typed_data';

import '../models/parse_result.dart';
import '../models/parser_config.dart';

/// 解析器在错误输入下执行有界重同步的累计诊断信息。
class ParserDiagnostics {
  final int droppedBytes;
  final int resyncCount;

  const ParserDiagnostics({
    required this.droppedBytes,
    required this.resyncCount,
  });
}

/// 数据解析器抽象接口
abstract class IDataParser {
  /// 解析器配置
  ParserConfig config;

  /// 解析结果输出流
  Stream<ParseResult> get outputStream;

  /// 错误协议或损坏帧导致的累计丢弃信息。
  ParserDiagnostics get diagnostics =>
      const ParserDiagnostics(droppedBytes: 0, resyncCount: 0);

  /// 输入原始字节数据，并通过 [outputStream] 逐项发送结果。
  ///
  /// 该入口保留给兼容调用和测试；高频生产链路应使用 [feedBatch]，
  /// 避免每个数据包都经过一次 Stream 事件调度。
  void feed(Uint8List data);

  /// 输入一个原始字节块，同步返回其中解析出的全部结果。
  List<ParseResult> feedBatch(Uint8List data);

  /// 重置解析器状态
  void reset();

  /// 释放资源
  void dispose();

  IDataParser(this.config);
}
