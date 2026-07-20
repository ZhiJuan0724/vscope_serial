import 'dart:typed_data';

import '../models/parser_config.dart';

/// 发送协议初始化配置的共同类型。
sealed class SendProtocolInitializationConfig {
  const SendProtocolInitializationConfig();
}

/// ZobowDevice 初始化帧的通道号快照。
final class ZobowDeviceProtocolInitializationConfig
    extends SendProtocolInitializationConfig {
  ZobowDeviceProtocolInitializationConfig(List<int> channelIds)
    : channelIds = List<int>.unmodifiable(channelIds);

  final List<int> channelIds;
}

/// r 协议初始化命令的地址与通道校验快照。
final class RProtocolInitializationConfig
    extends SendProtocolInitializationConfig {
  RProtocolInitializationConfig({
    required List<String> addresses,
    this.requiredChannelCount,
    this.loose = false,
  }) : addresses = List<String>.unmodifiable(addresses);

  final List<String> addresses;
  final int? requiredChannelCount;
  final bool loose;
}

/// 绘图启动前使用的发送协议。
///
/// 接收数据由 `IDataParser` 负责解析；本抽象只描述发送侧如何校验配置、
/// 构造初始化字节以及记录可读日志，不持有串口或页面状态。
abstract interface class SendProtocol<
  TConfig extends SendProtocolInitializationConfig
> {
  SendProtocolType get type;
  String get initializationName;
  bool get displayAsHex;
  String get configurationErrorLabel;
  String get configurationErrorHelp;

  Uint8List buildInitializationData(TConfig config);
  String formatForLog(Uint8List data);
}
