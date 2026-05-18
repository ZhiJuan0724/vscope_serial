import 'dart:async';
import 'dart:typed_data';

import '../models/parse_result.dart';
import '../models/parser_config.dart';

/// 数据解析器抽象接口
abstract class IDataParser {
  /// 解析器配置
  ParserConfig config;

  /// 解析结果输出流
  Stream<ParseResult> get outputStream;

  /// 输入原始字节数据
  void feed(Uint8List data);

  /// 重置解析器状态
  void reset();

  /// 释放资源
  void dispose();

  IDataParser(this.config);
}
