import 'dart:convert';
import 'dart:typed_data';

import '../models/address_config_profile.dart';
import '../models/parser_config.dart';
import 'send_protocol.dart';

const rSendProtocol = RProtocolCodec();

/// r 发送协议的地址校验和启动命令编码规则。
///
/// 接收数据由用户选择的 `IDataParser` 实现处理，本类只负责发送侧。
final class RProtocolCodec
    implements SendProtocol<RProtocolInitializationConfig> {
  const RProtocolCodec();

  @override
  SendProtocolType get type => SendProtocolType.rProtocol;

  @override
  String get initializationName => 'r协议';

  @override
  bool get displayAsHex => false;

  @override
  String get configurationErrorLabel => '通道地址配置错误';

  @override
  String get configurationErrorHelp =>
      '请检查地址是否从 Ch0 开始连续填写；空地址会中断发送，0 会按有效地址发送。';

  @override
  Uint8List buildInitializationData(RProtocolInitializationConfig config) {
    return buildCommand(
      validateAddresses(
        config.addresses,
        requiredCount: config.requiredChannelCount,
        loose: config.loose,
      ),
    );
  }

  @override
  String formatForLog(Uint8List data) => utf8.decode(data).trim();

  int? parseAddress(String text) {
    return AddressChannelPreset.tryParseAddress(
      name: '',
      text: text,
      protocolType: AddressProfileProtocolType.rProtocol,
    )?.address;
  }

  List<String> validateAddresses(
    List<String> addresses, {
    int? requiredCount,
    bool loose = false,
  }) {
    if (loose) {
      // 宽松模式按用户实际填写的地址发送，不用固定接收通道数补足。
      return validateAddresses(compactAddresses(addresses));
    }
    if (requiredCount != null) {
      final requiredAddresses =
          addresses.take(requiredCount).map((address) {
            final text = address.trim();
            final value = parseAddress(text);
            if (value == null || value < 0) {
              throw FormatException('r协议地址无效或未填写: $address');
            }
            return text;
          }).toList();
      if (requiredAddresses.length < requiredCount) {
        throw FormatException(
          'r协议地址数量不足：接收协议需要 $requiredCount 个通道，'
          '当前仅填写 ${requiredAddresses.length} 个',
        );
      }
      return requiredAddresses;
    }

    final continuousAddresses = <String>[];
    var foundEmpty = false;
    for (final rawAddress in addresses) {
      final address = rawAddress.trim();
      final value = parseAddress(address);
      if (address.isEmpty) {
        foundEmpty = true;
        continue;
      }
      if (value == null || value < 0) {
        throw FormatException('r协议地址无效: $rawAddress');
      }
      if (foundEmpty) {
        throw const FormatException('r协议地址必须从 Ch0 开始连续填写，中间不能留空');
      }
      continuousAddresses.add(address);
    }
    if (continuousAddresses.isEmpty) {
      throw const FormatException('r协议至少需要填写一个通道地址');
    }
    return continuousAddresses;
  }

  List<String> compactAddresses(List<String> addresses) {
    final compacted = <String>[];
    for (final rawAddress in addresses) {
      final address = rawAddress.trim();
      if (address.isEmpty) continue;
      final value = parseAddress(address);
      if (value == null || value < 0) {
        throw FormatException('r协议地址无效: $rawAddress');
      }
      compacted.add(address);
    }
    if (compacted.isEmpty) {
      throw const FormatException('r协议至少需要填写一个通道地址');
    }
    final limited = compacted.take(SendProtocolConfig.maxChannelCount).toList();
    return [
      ...limited,
      ...List.filled(SendProtocolConfig.maxChannelCount - limited.length, ''),
    ];
  }

  int continuousAddressCount(List<String> addresses, {bool throwOnGap = true}) {
    var count = 0;
    var foundEmpty = false;
    for (final text in addresses) {
      final address = text.trim();
      if (address.isEmpty) {
        foundEmpty = true;
        continue;
      }
      final value = parseAddress(address);
      if (value == null || value < 0) {
        if (throwOnGap) throw FormatException('r协议地址无效: $text');
        break;
      }
      if (foundEmpty) {
        if (throwOnGap) {
          throw const FormatException('r协议地址必须从 Ch0 开始连续填写，中间不能留空');
        }
        break;
      }
      count++;
    }
    return count;
  }

  int configuredAddressCount(List<String> addresses) {
    var count = 0;
    for (final text in addresses) {
      final address = text.trim();
      if (address.isEmpty) continue;
      final value = parseAddress(address);
      if (value != null && value >= 0) count++;
    }
    return count;
  }

  Uint8List buildCommand(List<String> addresses) {
    if (addresses.isEmpty) {
      throw ArgumentError.value(addresses, 'addresses', 'must not be empty');
    }
    final normalized = <String>[];
    for (final address in addresses) {
      final text = address.trim();
      final value = parseAddress(text);
      if (value == null || value < 0) {
        throw FormatException('无效的 r 协议地址: $address');
      }
      normalized.add(text);
    }
    return Uint8List.fromList(utf8.encode('r ${normalized.join(' ')}\n'));
  }
}
