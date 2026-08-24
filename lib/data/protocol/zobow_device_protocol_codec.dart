import 'dart:typed_data';

import '../../core/utils/crc.dart';
import '../models/parser_config.dart';
import 'send_protocol.dart';

const zobowDeviceSendProtocol = ZobowDeviceProtocolCodec();

/// ZobowDevice 发送协议的纯字节编码规则。
///
/// 接收帧仍由 `ZobowParser` 解析；本类不持有串口或页面状态。
final class ZobowDeviceProtocolCodec
    implements SendProtocol<ZobowDeviceProtocolInitializationConfig> {
  const ZobowDeviceProtocolCodec();

  @override
  SendProtocolType get type => SendProtocolType.zobowBuiltIn;

  @override
  String get initializationName => '众邦设备';

  @override
  bool get displayAsHex => true;

  @override
  String get configurationErrorLabel => '配置错误';

  @override
  String get configurationErrorHelp => '';

  @override
  Uint8List buildInitializationData(
    ZobowDeviceProtocolInitializationConfig config,
  ) => buildInitFrame(config.channelIds);

  @override
  String formatForLog(Uint8List data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  /// 构造众邦设备初始化帧。
  ///
  /// 通道号使用 uint32 little-endian 编码，CRC16/MODBUS 覆盖全部
  /// 通道号字节并以 little-endian 附加到帧尾。
  Uint8List buildInitFrame(List<int> channelIds) {
    if (channelIds.length != 4 && channelIds.length != 8) {
      throw ArgumentError.value(
        channelIds,
        'channelIds',
        'must contain 4 or 8 ids',
      );
    }

    final dataLength = channelIds.length * 4;
    final bytes = Uint8List(dataLength + 2);
    final buffer = ByteData.sublistView(bytes);
    for (var index = 0; index < channelIds.length; index++) {
      buffer.setUint32(
        index * 4,
        channelIds[index] & 0xFFFFFFFF,
        Endian.little,
      );
    }

    final dataBytes = Uint8List.sublistView(bytes, 0, dataLength);
    final crc = calculateCrc(dataBytes, crc16Polys['CRC-16/MODBUS']!);
    bytes[dataLength] = crc & 0xFF;
    bytes[dataLength + 1] = (crc >> 8) & 0xFF;
    return bytes;
  }
}
