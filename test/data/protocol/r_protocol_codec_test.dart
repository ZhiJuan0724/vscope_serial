import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/protocol/r_protocol_codec.dart';

void main() {
  group('RProtocolCodec', () {
    test('命令保留十进制和0x输入形式并以LF结尾', () {
      final bytes = rSendProtocol.buildCommand(['0', ' 12 ', '0x10', '0X2A']);

      expect(utf8.decode(bytes), 'r 0 12 0x10 0X2A\n');
    });

    test('地址严格区分十进制和带0x前缀的十六进制', () {
      expect(rSendProtocol.parseAddress('16'), 16);
      expect(rSendProtocol.parseAddress('0x10'), 16);
      expect(rSendProtocol.parseAddress('FF'), isNull);
      expect(rSendProtocol.parseAddress('12x3'), isNull);
      expect(rSendProtocol.parseAddress('0xGG'), isNull);
      expect(rSendProtocol.parseAddress('4294967296'), isNull);
    });

    test('地址校验支持0地址、自动连续前缀和固定通道截断', () {
      expect(rSendProtocol.validateAddresses(['0', '0x0', '20', '']), [
        '0',
        '0x0',
        '20',
      ]);
      expect(
        rSendProtocol.validateAddresses(['1', '0x10', '20'], requiredCount: 2),
        ['1', '0x10'],
      );
    });

    test('宽松通道设置会压紧非空地址并保留0地址', () {
      expect(
        rSendProtocol.validateAddresses([
          '',
          '0',
          '',
          '0x10',
          ' 20 ',
        ], loose: true),
        ['0', '0x10', '20'],
      );
      expect(
        rSendProtocol.validateAddresses(
          ['', '0', '', '0x10'],
          requiredCount: 3,
          loose: true,
        ),
        ['0', '0x10'],
      );
      expect(
        () => rSendProtocol.validateAddresses(['', ''], loose: true),
        throwsFormatException,
      );
    });

    test('地址校验拒绝全空、固定通道不足和中间空洞', () {
      expect(
        () => rSendProtocol.validateAddresses(['', '']),
        throwsFormatException,
      );
      expect(
        () => rSendProtocol.validateAddresses(['1'], requiredCount: 2),
        throwsFormatException,
      );
      expect(
        () => rSendProtocol.validateAddresses(['0', '', '2']),
        throwsFormatException,
      );
    });
  });
}
