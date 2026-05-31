import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/crc.dart';
import 'package:vscope_serial/data/models/channel_config.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/parser/fixed_frame_parser.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

void main() {
  group('FixedFrameParser', () {
    test('CRC16支持位于帧尾前', () async {
      final config = _crcConfig(ChecksumPosition.beforeFrameTail);
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;

      parser.feed(_buildFrame(config, [1, 0, 2, 0]));
      final result = await resultFuture;

      expect(result.success, isTrue);
      expect(result.values, [1, 2]);
    });

    test('CRC16支持位于帧尾后', () async {
      final config = _crcConfig(ChecksumPosition.afterFrameTail);
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;

      parser.feed(_buildFrame(config, [3, 0, 4, 0]));
      final result = await resultFuture;

      expect(result.success, isTrue);
      expect(result.values, [3, 4]);
    });

    test('CRC16支持小端序', () async {
      final config = _crcConfig(ChecksumPosition.afterFrameTail)
        ..checksumEndian = ChecksumEndian.little;
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;

      parser.feed(_buildFrame(config, [5, 0, 6, 0]));
      final result = await resultFuture;

      expect(result.success, isTrue);
      expect(result.values, [5, 6]);
    });

    test('支持CRC8和CRC32多项式', () async {
      for (final config in [
        _crcConfig(ChecksumPosition.beforeFrameTail)
          ..checksumType = ChecksumType.crc8
          ..crcPolynomialName = 'CRC-8',
        _crcConfig(ChecksumPosition.beforeFrameTail)
          ..checksumType = ChecksumType.crc32
          ..crcPolynomialName = 'CRC-32',
      ]) {
        final parser = FixedFrameParser(config);
        addTearDown(parser.dispose);
        final resultFuture = parser.outputStream.first;

        parser.feed(_buildFrame(config, [7, 0, 8, 0]));
        final result = await resultFuture;

        expect(result.success, isTrue);
        expect(result.values, [7, 8]);
      }
    });

    test('支持无帧头且仅使用帧尾', () async {
      final config =
          ParserConfig.fixedFrameDefault()
            ..hasFrameHeader = false
            ..channelCount = 2
            ..hasFrameTail = true
            ..frameTail = [0x0D, 0x0A];
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;

      parser.feed(Uint8List.fromList([1, 0, 2, 0, 0x0D, 0x0A]));
      final result = await resultFuture;

      expect(result.success, isTrue);
      expect(result.values, [1, 2]);
    });

    test('通道类型不一致时按逐通道类型解析', () async {
      final config =
          ParserConfig.fixedFrameDefault()
            ..channelCount = 3
            ..fixedFrameUniformDataType = false
            ..fixedFrameChannelTypes = [
              DataType.uint8,
              DataType.int16,
              DataType.uint32,
            ];
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;

      parser.feed(
        Uint8List.fromList([
          ...config.frameHeader,
          7,
          0xFE,
          0xFF,
          0x78,
          0x56,
          0x34,
          0x12,
        ]),
      );
      final result = await resultFuture;

      expect(config.dataBytesPerFrame, 7);
      expect(result.success, isTrue);
      expect(result.values, [7, -2, 0x12345678]);
    });

    test('错误CRC会解析失败', () async {
      final config = _crcConfig(ChecksumPosition.beforeFrameTail);
      final parser = FixedFrameParser(config);
      addTearDown(parser.dispose);
      final resultFuture = parser.outputStream.first;
      final frame = _buildFrame(config, [1, 0, 2, 0]);
      frame[config.frameHeaderLength + config.dataBytesPerFrame] ^= 0xFF;

      parser.feed(frame);
      final result = await resultFuture;

      expect(result.success, isFalse);
    });

    test('帧头和帧尾不能同时全部为0', () {
      final config =
          ParserConfig.fixedFrameDefault()
            ..frameHeader = [0, 0]
            ..hasFrameTail = true
            ..frameTail = [0, 0];

      expect(config.fixedFrameValidationError, isNotNull);
    });

    test('固定帧通道数不能为0', () {
      final config = ParserConfig.fixedFrameDefault()..channelCount = 0;

      expect(config.fixedFrameValidationError, isNotNull);
    });

    test('固定帧r协议按固定通道数发送并保留0地址', () {
      final addresses = PlotViewModel.validateRProtocolAddresses(
        ['1', '0', '0x10'],
        requiredCount: 3,
        allowZeroValues: true,
      );

      expect(addresses, ['1', '0', '0x10']);
      expect(
        String.fromCharCodes(
          PlotViewModel.buildRProtocolCommand(addresses, allowZeroValues: true),
        ),
        'r 1 0 0x10\n',
      );
    });
  });
}

ParserConfig _crcConfig(ChecksumPosition position) {
  return ParserConfig.fixedFrameDefault()
    ..dataType = DataType.uint16
    ..channelCount = 2
    ..hasChecksum = true
    ..checksumType = ChecksumType.crc16
    ..checksumPosition = position
    ..crcPolynomialName = 'CRC-16/MODBUS'
    ..hasFrameTail = true
    ..frameTail = [0x0D, 0x0A];
}

Uint8List _buildFrame(ParserConfig config, List<int> data) {
  final poly = switch (config.checksumType) {
    ChecksumType.crc8 => crc8Polys[config.crcPolynomialName]!,
    ChecksumType.crc16 => crc16Polys[config.crcPolynomialName]!,
    ChecksumType.crc32 => crc32Polys[config.crcPolynomialName]!,
    _ => throw StateError('CRC required'),
  };
  final calculatedCrc = crcToBytes(
    calculateCrc(Uint8List.fromList(data), poly),
    poly.width,
  );
  final crc =
      config.checksumEndian == ChecksumEndian.little
          ? calculatedCrc.reversed.toList()
          : calculatedCrc;
  final tail = config.frameTail!;
  return Uint8List.fromList([
    if (config.hasFrameHeader) ...config.frameHeader,
    ...data,
    if (config.checksumPosition == ChecksumPosition.beforeFrameTail) ...crc,
    ...tail,
    if (config.checksumPosition == ChecksumPosition.afterFrameTail) ...crc,
  ]);
}
