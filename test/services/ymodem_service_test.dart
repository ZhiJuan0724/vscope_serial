import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/ymodem_service.dart';

void main() {
  group('YmodemService', () {
    Future<void> waitUntilActive(YmodemService service) async {
      for (var i = 0; i < 50; i++) {
        if (service.isActive) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('YMODEM service did not become active');
    }

    test('calculates CRC16-CCITT', () {
      expect(YmodemService.crc16Ccitt('123456789'.codeUnits), 0x31C3);
    });

    test('sends one file using YMODEM handshake', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-send-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/hello.bin')
        ..writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
      final sentPackets = <Uint8List>[];
      var eotCount = 0;
      var headerSeen = false;
      var firstDataBlockAttempts = 0;

      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          sentPackets.add(Uint8List.fromList(data));
          Future.microtask(() {
            if (data.length == 1 && data.single == YmodemService.eot) {
              eotCount++;
              service.addIncomingBytes(
                Uint8List.fromList([
                  eotCount == 1 ? YmodemService.nak : YmodemService.ack,
                  if (eotCount == 2) YmodemService.crcRequest,
                ]),
              );
              return;
            }
            if (data.isNotEmpty &&
                (data.first == YmodemService.soh ||
                    data.first == YmodemService.stx)) {
              final block = data[1];
              if (block == 0 && !headerSeen) {
                headerSeen = true;
                service.addIncomingBytes(
                  Uint8List.fromList([
                    YmodemService.ack,
                    YmodemService.crcRequest,
                  ]),
                );
              } else {
                if (block == 1 && firstDataBlockAttempts++ == 0) {
                  // 模拟数据块 ACK 丢失，发送端应超时后重发同一个块。
                  return;
                }
                service.addIncomingBytes(
                  Uint8List.fromList([YmodemService.ack]),
                );
              }
            }
          });
        },
      );
      final sendFuture = service.sendFile(file);
      await waitUntilActive(service);
      service.addIncomingBytes(Uint8List.fromList([YmodemService.crcRequest]));
      await sendFuture;

      expect(service.status.phase, YmodemPhase.completed);
      expect(service.status.retryCount, greaterThanOrEqualTo(1));
      expect(
        sentPackets.where((packet) => packet.length > 1 && packet[1] == 1),
        hasLength(2),
      );
      expect(
        sentPackets.where(
          (packet) => packet.length == 1 && packet.single == YmodemService.eot,
        ),
        hasLength(2),
      );
    });

    test('sends data blocks with selected 128 byte packet size', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-send-128-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/packet.bin')..writeAsBytesSync(
        Uint8List.fromList(List.generate(300, (i) => i & 0xFF)),
      );
      final sentPackets = <Uint8List>[];
      var eotCount = 0;
      var headerSeen = false;

      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          sentPackets.add(Uint8List.fromList(data));
          Future.microtask(() {
            if (data.length == 1 && data.single == YmodemService.eot) {
              eotCount++;
              service.addIncomingBytes(
                Uint8List.fromList([
                  eotCount == 1 ? YmodemService.nak : YmodemService.ack,
                  if (eotCount == 2) YmodemService.crcRequest,
                ]),
              );
              return;
            }
            if (data.isNotEmpty &&
                (data.first == YmodemService.soh ||
                    data.first == YmodemService.stx)) {
              final block = data[1];
              if (block == 0 && !headerSeen) {
                headerSeen = true;
                service.addIncomingBytes(
                  Uint8List.fromList([
                    YmodemService.ack,
                    YmodemService.crcRequest,
                  ]),
                );
              } else {
                service.addIncomingBytes(
                  Uint8List.fromList([YmodemService.ack]),
                );
              }
            }
          });
        },
      );
      final sendFuture = service.sendFile(
        file,
        packetSizeMode: YmodemPacketSizeMode.bytes128,
      );
      await waitUntilActive(service);
      service.addIncomingBytes(Uint8List.fromList([YmodemService.crcRequest]));
      await sendFuture;

      final dataPackets = sentPackets.where(
        (packet) =>
            packet.length > 1 &&
            packet[0] == YmodemService.soh &&
            packet[1] != 0,
      );
      expect(dataPackets, hasLength(3));
      expect(dataPackets.every((packet) => packet.length == 133), isTrue);
      expect(
        sentPackets.any(
          (packet) => packet.length > 1 && packet[0] == YmodemService.stx,
        ),
        isFalse,
      );
    });

    test('receives one file and saves with a non-conflicting name', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-receive-');
      addTearDown(() => temp.delete(recursive: true));
      File('${temp.path}/hello.bin').writeAsBytesSync([9]);
      final payload = Uint8List(128)..fillRange(0, 128, YmodemService.eof);
      payload.setRange(0, 4, [1, 2, 3, 4]);
      var ackCount = 0;

      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          Future.microtask(() {
            for (final byte in data) {
              if (byte == YmodemService.crcRequest && ackCount == 0) {
                service.addIncomingBytes(
                  YmodemService.buildHeaderPacketForTest('hello.bin', 4),
                );
              } else if (byte == YmodemService.crcRequest && ackCount >= 1) {
                service.addIncomingBytes(
                  YmodemService.buildDataPacketForTest(payload, 1),
                );
              } else if (byte == YmodemService.ack) {
                ackCount++;
                if (ackCount == 2) {
                  service.addIncomingBytes(
                    Uint8List.fromList([YmodemService.eot]),
                  );
                } else if (ackCount == 3) {
                  service.addIncomingBytes(
                    YmodemService.buildHeaderPacketForTest('', 0),
                  );
                }
              } else if (byte == YmodemService.nak) {
                service.addIncomingBytes(
                  Uint8List.fromList([YmodemService.eot]),
                );
              }
            }
          });
        },
      );

      final file = await service.receiveFile(temp);

      expect(file, isNotNull);
      expect(file!.path, isNot(endsWith('hello.bin')));
      expect(file.readAsBytesSync(), [1, 2, 3, 4]);
      expect(service.status.phase, YmodemPhase.completed);
    });

    test('ignores shell text received before YMODEM starts', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-stale-');
      addTearDown(() => temp.delete(recursive: true));
      final payload = Uint8List(128)..fillRange(0, 128, YmodemService.eof);
      payload.setRange(0, 3, [7, 8, 9]);
      var ackCount = 0;

      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          Future.microtask(() {
            for (final byte in data) {
              if (byte == YmodemService.crcRequest && ackCount == 0) {
                service.addIncomingBytes(
                  YmodemService.buildHeaderPacketForTest('fresh.bin', 3),
                );
              } else if (byte == YmodemService.crcRequest && ackCount >= 1) {
                service.addIncomingBytes(
                  YmodemService.buildDataPacketForTest(payload, 1),
                );
              } else if (byte == YmodemService.ack) {
                ackCount++;
                if (ackCount == 2) {
                  service.addIncomingBytes(
                    Uint8List.fromList([YmodemService.eot]),
                  );
                } else if (ackCount == 3) {
                  service.addIncomingBytes(
                    YmodemService.buildHeaderPacketForTest('', 0),
                  );
                }
              } else if (byte == YmodemService.nak) {
                service.addIncomingBytes(
                  Uint8List.fromList([YmodemService.eot]),
                );
              }
            }
          });
        },
      );
      service.addIncomingBytes(Uint8List.fromList('terminal text'.codeUnits));

      final file = await service.receiveFile(temp);

      expect(file, isNotNull);
      expect(file!.readAsBytesSync(), [7, 8, 9]);
      expect(service.status.phase, YmodemPhase.completed);
    });

    test(
      'retries CRC errors and ACKs duplicate blocks without rewriting',
      () async {
        late YmodemService service;
        final temp = await Directory.systemTemp.createTemp('ymodem-retry-');
        addTearDown(() => temp.delete(recursive: true));
        final payload = Uint8List(128)..fillRange(0, 128, YmodemService.eof);
        payload.setRange(0, 4, [1, 2, 3, 4]);
        final validPacket = YmodemService.buildDataPacketForTest(payload, 1);
        final corruptPacket = Uint8List.fromList(validPacket)
          ..[validPacket.length - 1] ^= 0xFF;
        var ackCount = 0;
        var corruptSent = false;
        var validSent = false;

        service = YmodemService(
          packetTimeout: const Duration(milliseconds: 200),
          sendBytes: (data) {
            Future.microtask(() {
              for (final byte in data) {
                if (byte == YmodemService.crcRequest && ackCount == 0) {
                  service.addIncomingBytes(
                    YmodemService.buildHeaderPacketForTest('retry.bin', 4),
                  );
                } else if (byte == YmodemService.crcRequest && ackCount == 1) {
                  corruptSent = true;
                  service.addIncomingBytes(corruptPacket);
                } else if (byte == YmodemService.crcRequest && ackCount >= 4) {
                  service.addIncomingBytes(
                    YmodemService.buildHeaderPacketForTest('', 0),
                  );
                } else if (byte == YmodemService.nak) {
                  if (corruptSent && !validSent) {
                    validSent = true;
                    service.addIncomingBytes(validPacket);
                  } else {
                    service.addIncomingBytes(
                      Uint8List.fromList([YmodemService.eot]),
                    );
                  }
                } else if (byte == YmodemService.ack) {
                  ackCount++;
                  if (ackCount == 2) {
                    // 模拟数据块 ACK 丢失，发送方重发同一个块。
                    service.addIncomingBytes(validPacket);
                  } else if (ackCount == 3) {
                    service.addIncomingBytes(
                      Uint8List.fromList([YmodemService.eot]),
                    );
                  }
                }
              }
            });
          },
        );

        final file = await service.receiveFile(temp);

        expect(file, isNotNull);
        expect(file!.readAsBytesSync(), [1, 2, 3, 4]);
        expect(service.status.retryCount, greaterThanOrEqualTo(1));
        expect(service.status.phase, YmodemPhase.completed);
      },
    );

    test('receives packets split across many input chunks', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-fragmented-');
      addTearDown(() => temp.delete(recursive: true));
      final payload = Uint8List(128)..fillRange(0, 128, YmodemService.eof);
      payload.setRange(0, 3, [7, 8, 9]);
      var crcRequests = 0;
      var ackCount = 0;

      void feedFragmented(Uint8List packet) {
        for (var offset = 0; offset < packet.length; offset += 7) {
          service.addIncomingBytes(
            Uint8List.sublistView(
              packet,
              offset,
              (offset + 7).clamp(0, packet.length),
            ),
          );
        }
      }

      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          Future.microtask(() {
            for (final byte in data) {
              if (byte == YmodemService.crcRequest) {
                crcRequests++;
                if (crcRequests == 1) {
                  feedFragmented(
                    YmodemService.buildHeaderPacketForTest('fragmented.bin', 3),
                  );
                } else if (crcRequests == 2) {
                  feedFragmented(
                    YmodemService.buildDataPacketForTest(payload, 1),
                  );
                } else if (crcRequests == 3) {
                  feedFragmented(YmodemService.buildHeaderPacketForTest('', 0));
                }
              } else if (byte == YmodemService.ack) {
                ackCount++;
                if (ackCount == 2) {
                  service.addIncomingBytes(
                    Uint8List.fromList([YmodemService.eot]),
                  );
                }
              } else if (byte == YmodemService.nak) {
                service.addIncomingBytes(
                  Uint8List.fromList([YmodemService.eot]),
                );
              }
            }
          });
        },
      );

      final file = await service.receiveFile(temp);

      expect(file?.readAsBytesSync(), [7, 8, 9]);
      expect(File('${file!.path}.part').existsSync(), isFalse);
      expect(service.status.phase, YmodemPhase.completed);
    });

    test(
      'input high-water overflow sends CAN and fails the transfer',
      () async {
        final sent = <int>[];
        final temp = await Directory.systemTemp.createTemp('ymodem-overload-');
        addTearDown(() => temp.delete(recursive: true));
        final service = YmodemService(
          inputHighWaterBytes: 16,
          packetTimeout: const Duration(seconds: 1),
          sendBytes: (data) => sent.addAll(data),
        );

        final receiveFuture = service.receiveFile(temp);
        await waitUntilActive(service);
        service.addIncomingBytes(Uint8List(17));

        await expectLater(receiveFuture, throwsA(isA<YmodemException>()));
        expect(sent.where((byte) => byte == YmodemService.can), hasLength(4));
        expect(service.status.phase, YmodemPhase.failed);
        expect(service.status.message, contains('输入过载'));
        expect(await temp.list().toList(), isEmpty);
      },
    );

    test('rejects a receive header larger than 4 GiB', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp('ymodem-size-');
      addTearDown(() => temp.delete(recursive: true));
      var headerSent = false;
      service = YmodemService(
        packetTimeout: const Duration(milliseconds: 200),
        sendBytes: (data) {
          if (!headerSent && data.contains(YmodemService.crcRequest)) {
            headerSent = true;
            Future.microtask(
              () => service.addIncomingBytes(
                YmodemService.buildHeaderPacketForTest(
                  'too-large.bin',
                  YmodemService.maxFileSize + 1,
                ),
              ),
            );
          }
        },
      );

      await expectLater(
        service.receiveFile(temp),
        throwsA(
          isA<YmodemException>().having(
            (error) => error.message,
            'message',
            contains('4 GiB'),
          ),
        ),
      );
      expect(await temp.list().toList(), isEmpty);
    });

    test('cancelled receive removes the part file and final target', () async {
      late YmodemService service;
      final temp = await Directory.systemTemp.createTemp(
        'ymodem-receive-cancel-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final dataRequested = Completer<void>();
      var crcRequests = 0;
      service = YmodemService(
        packetTimeout: const Duration(seconds: 1),
        sendBytes: (data) {
          Future.microtask(() {
            for (final byte in data) {
              if (byte != YmodemService.crcRequest) continue;
              crcRequests++;
              if (crcRequests == 1) {
                service.addIncomingBytes(
                  YmodemService.buildHeaderPacketForTest('partial.bin', 128),
                );
              } else if (!dataRequested.isCompleted) {
                dataRequested.complete();
              }
            }
          });
        },
      );

      final receiveFuture = service.receiveFile(temp);
      await dataRequested.future;
      final target = File('${temp.path}/partial.bin');
      final part = File('${target.path}.part');
      expect(await part.exists(), isTrue);

      await service.cancel();
      await expectLater(receiveFuture, throwsA(isA<YmodemException>()));

      expect(await target.exists(), isFalse);
      expect(await part.exists(), isFalse);
      expect(service.status.phase, YmodemPhase.cancelled);
    });

    test('cancel sends CAN bytes and marks transfer cancelled', () async {
      late YmodemService service;
      final sent = <int>[];
      service = YmodemService(
        packetTimeout: const Duration(seconds: 1),
        sendBytes: (data) => sent.addAll(data),
      );
      final temp = await Directory.systemTemp.createTemp('ymodem-cancel-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/cancel.bin')..writeAsBytesSync([1]);
      final future = service.sendFile(file).catchError((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await service.cancel();
      await future;

      expect(sent.where((byte) => byte == YmodemService.can), hasLength(4));
      expect(service.status.phase, YmodemPhase.cancelled);
    });
  });
}
