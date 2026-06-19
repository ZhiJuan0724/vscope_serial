import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

enum YmodemDirection { send, receive }

enum YmodemPacketSizeMode {
  auto,
  bytes128,
  bytes1024;

  int payloadSizeFor(int remainingBytes) {
    return switch (this) {
      YmodemPacketSizeMode.bytes128 => 128,
      YmodemPacketSizeMode.bytes1024 => 1024,
      YmodemPacketSizeMode.auto => remainingBytes > 128 ? 1024 : 128,
    };
  }
}

enum YmodemPhase {
  idle,
  waiting,
  transferring,
  finishing,
  completed,
  failed,
  cancelled,
}

class YmodemTransferStatus {
  final YmodemDirection? direction;
  final YmodemPhase phase;
  final String? fileName;
  final int totalBytes;
  final int transferredBytes;
  final int retryCount;
  final String message;
  final String? savedPath;

  const YmodemTransferStatus({
    required this.direction,
    required this.phase,
    required this.fileName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.retryCount,
    required this.message,
    this.savedPath,
  });

  const YmodemTransferStatus.idle()
    : direction = null,
      phase = YmodemPhase.idle,
      fileName = null,
      totalBytes = 0,
      transferredBytes = 0,
      retryCount = 0,
      message = '',
      savedPath = null;

  bool get isActive =>
      phase == YmodemPhase.waiting ||
      phase == YmodemPhase.transferring ||
      phase == YmodemPhase.finishing;

  double get progress =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0, 1);

  YmodemTransferStatus copyWith({
    YmodemDirection? direction,
    YmodemPhase? phase,
    String? fileName,
    int? totalBytes,
    int? transferredBytes,
    int? retryCount,
    String? message,
    String? savedPath,
  }) {
    return YmodemTransferStatus(
      direction: direction ?? this.direction,
      phase: phase ?? this.phase,
      fileName: fileName ?? this.fileName,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      retryCount: retryCount ?? this.retryCount,
      message: message ?? this.message,
      savedPath: savedPath ?? this.savedPath,
    );
  }
}

class YmodemException implements Exception {
  final String message;
  const YmodemException(this.message);

  @override
  String toString() => message;
}

class YmodemService {
  YmodemService({
    required FutureOr<void> Function(Uint8List data) sendBytes,
    Duration packetTimeout = const Duration(seconds: 8),
    int maxRetries = 10,
  }) : _sendBytes = sendBytes,
       _packetTimeout = packetTimeout,
       _maxRetries = maxRetries;

  static const int soh = 0x01;
  static const int stx = 0x02;
  static const int eot = 0x04;
  static const int ack = 0x06;
  static const int nak = 0x15;
  static const int can = 0x18;
  static const int crcRequest = 0x43;
  static const int eof = 0x1A;

  final FutureOr<void> Function(Uint8List data) _sendBytes;
  final Duration _packetTimeout;
  final int _maxRetries;
  final _statusController = StreamController<YmodemTransferStatus>.broadcast();
  final Queue<int> _incoming = Queue<int>();

  StreamSubscription<Uint8List>? _subscription;
  YmodemTransferStatus _status = const YmodemTransferStatus.idle();
  bool _cancelRequested = false;
  Completer<int>? _pendingByte;

  Stream<YmodemTransferStatus> get statusStream => _statusController.stream;
  YmodemTransferStatus get status => _status;
  bool get isActive => _status.isActive;

  void attach(Stream<Uint8List> input) {
    _subscription?.cancel();
    _subscription = input.listen(addIncomingBytes);
  }

  void addIncomingBytes(Uint8List data) {
    if (!isActive && _pendingByte == null) return;
    for (final byte in data) {
      final pending = _pendingByte;
      if (pending != null && !pending.isCompleted) {
        _pendingByte = null;
        pending.complete(byte);
      } else {
        _incoming.add(byte);
      }
    }
  }

  Future<void> sendFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) async {
    if (isActive) throw const YmodemException('YMODEM 正在传输中');
    _resetIncomingBuffer();
    _cancelRequested = false;
    try {
      final bytes = await file.readAsBytes();
      final fileName = file.uri.pathSegments.last;
      _setStatus(
        YmodemTransferStatus(
          direction: YmodemDirection.send,
          phase: YmodemPhase.waiting,
          fileName: fileName,
          totalBytes: bytes.length,
          transferredBytes: 0,
          retryCount: 0,
          message: '等待接收方',
        ),
      );
      await _waitForByte(crcRequest, '等待接收方请求 CRC');
      await _sendPacket(_buildHeaderPacket(fileName, bytes.length), 0);
      await _waitForByte(crcRequest, '等待数据请求');

      var block = 1;
      var offset = 0;
      while (offset < bytes.length) {
        _throwIfCancelled();
        final size = packetSizeMode.payloadSizeFor(bytes.length - offset);
        final end = math.min(offset + size, bytes.length);
        final payload = Uint8List(size)..fillRange(0, size, eof);
        payload.setRange(0, end - offset, bytes, offset);
        await _sendPacket(_buildDataPacket(payload, block), block);
        offset = end;
        _setStatus(
          _status.copyWith(
            phase: YmodemPhase.transferring,
            transferredBytes: offset,
            message: '正在发送',
          ),
        );
        block = (block + 1) & 0xFF;
      }

      _setStatus(
        _status.copyWith(phase: YmodemPhase.finishing, message: '结束传输'),
      );
      await _sendEotSequence();
      await _waitForByte(crcRequest, '等待空头请求');
      await _sendPacket(_buildHeaderPacket('', 0), 0);
      _setStatus(
        _status.copyWith(phase: YmodemPhase.completed, message: '发送完成'),
      );
    } catch (error) {
      if (_cancelRequested) {
        _setStatus(
          _status.copyWith(phase: YmodemPhase.cancelled, message: '已取消'),
        );
      } else {
        _setStatus(
          _status.copyWith(
            phase: YmodemPhase.failed,
            message: error.toString(),
          ),
        );
      }
      rethrow;
    }
  }

  Future<File?> receiveFile(Directory directory) async {
    if (isActive) throw const YmodemException('YMODEM 正在传输中');
    await directory.create(recursive: true);
    _resetIncomingBuffer();
    _cancelRequested = false;
    RandomAccessFile? output;
    File? target;
    try {
      _setStatus(
        const YmodemTransferStatus(
          direction: YmodemDirection.receive,
          phase: YmodemPhase.waiting,
          fileName: null,
          totalBytes: 0,
          transferredBytes: 0,
          retryCount: 0,
          message: '等待发送方',
        ),
      );
      final header = await _requestInitialHeaderPacket();
      if (header.blockNumber != 0) {
        throw const YmodemException('YMODEM 文件头无效');
      }
      final metadata = _parseHeader(header.payload);
      if (metadata.fileName.isEmpty) {
        await _sendByte(ack);
        _setStatus(
          const YmodemTransferStatus(
            direction: YmodemDirection.receive,
            phase: YmodemPhase.completed,
            fileName: null,
            totalBytes: 0,
            transferredBytes: 0,
            retryCount: 0,
            message: '未接收文件',
          ),
        );
        return null;
      }
      target = await _resolveReceiveFile(directory, metadata.fileName);
      output = await target.open(mode: FileMode.write);
      _setStatus(
        YmodemTransferStatus(
          direction: YmodemDirection.receive,
          phase: YmodemPhase.transferring,
          fileName: metadata.fileName,
          totalBytes: metadata.fileSize,
          transferredBytes: 0,
          retryCount: _status.retryCount,
          message: '正在接收',
        ),
      );
      await _sendByte(ack);
      await _sendByte(crcRequest);

      var expectedBlock = 1;
      var written = 0;
      while (true) {
        _throwIfCancelled();
        final first = await _readByteWithTimeout();
        if (first == eot) {
          await _sendByte(nak);
          final second = await _readByteWithTimeout();
          if (second != eot) {
            throw const YmodemException('YMODEM EOT 序列无效');
          }
          await _sendByte(ack);
          await _sendByte(crcRequest);
          final endHeader = await _readPacket();
          if (endHeader.blockNumber != 0) {
            throw const YmodemException('YMODEM 结束头无效');
          }
          await _sendByte(ack);
          // 发送最终 ACK 后立即标记完成，确保对端回复数据
          // 不会被 YMODEM 输入缓冲吞掉，而是正确路由到 Shell 终端
          _setStatus(
            _status.copyWith(
              phase: YmodemPhase.completed,
              transferredBytes: metadata.fileSize,
              message: '接收完成',
              savedPath: target.path,
            ),
          );
          break;
        }
        final packet = await _readPacket(firstByte: first);
        if (packet.blockNumber != (expectedBlock & 0xFF)) {
          await _sendByte(nak);
          _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
          continue;
        }
        final remaining = metadata.fileSize - written;
        final toWrite = math.min(packet.payload.length, math.max(remaining, 0));
        if (toWrite > 0) {
          await output.writeFrom(packet.payload, 0, toWrite);
          written += toWrite;
        }
        await _sendByte(ack);
        _setStatus(
          _status.copyWith(
            transferredBytes: written,
            message: '正在接收',
            savedPath: target.path,
          ),
        );
        expectedBlock++;
      }
      await output.close();
      output = null;
      return target;
    } catch (error) {
      await output?.close();
      if (_cancelRequested) {
        _setStatus(
          _status.copyWith(phase: YmodemPhase.cancelled, message: '已取消'),
        );
      } else {
        _setStatus(
          _status.copyWith(
            phase: YmodemPhase.failed,
            message: error.toString(),
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> cancel() async {
    if (!isActive) return;
    _cancelRequested = true;
    final pending = _pendingByte;
    if (pending != null && !pending.isCompleted) {
      _pendingByte = null;
      pending.complete(can);
    }
    await _sendBytes(Uint8List.fromList([can, can, can, can]));
    _setStatus(_status.copyWith(phase: YmodemPhase.cancelled, message: '已取消'));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _statusController.close();
  }

  Future<void> _sendPacket(Uint8List packet, int blockNumber) async {
    Object? lastError;
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      _throwIfCancelled();
      await _sendBytes(packet);
      final response = await _readByteWithTimeout(allowTimeout: true);
      if (response == ack) return;
      if (response == can) throw const YmodemException('对端取消传输');
      lastError = response == null ? '等待 ACK 超时' : '收到 ${_hex(response)}';
      _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
    }
    throw YmodemException('YMODEM 块 $blockNumber 发送失败: $lastError');
  }

  Future<void> _sendEotSequence() async {
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      _throwIfCancelled();
      await _sendByte(eot);
      final first = await _readByteWithTimeout(allowTimeout: true);
      if (first == nak) {
        await _sendByte(eot);
        final second = await _readByteWithTimeout(allowTimeout: true);
        if (second == ack) return;
      } else if (first == ack) {
        return;
      }
      _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
    }
    throw const YmodemException('YMODEM EOT 确认失败');
  }

  Future<void> _waitForByte(int expected, String message) async {
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      _throwIfCancelled();
      _setStatus(_status.copyWith(message: message));
      final byte = await _readByteWithTimeout(allowTimeout: true);
      if (byte == expected) return;
      if (byte == can) throw const YmodemException('对端取消传输');
      _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
    }
    throw YmodemException('$message 超时');
  }

  Future<_YmodemPacket> _requestInitialHeaderPacket() async {
    Object? lastError;
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      _throwIfCancelled();
      await _sendByte(crcRequest);
      _setStatus(
        _status.copyWith(retryCount: attempt, message: '等待 YMODEM 文件头'),
      );

      final start = await _readByteWithTimeout(allowTimeout: true);
      if (start == null) {
        lastError = '等待文件头超时';
        continue;
      }
      if (start == can) throw const YmodemException('对端取消传输');
      if (start != soh && start != stx) {
        lastError = '丢弃非 YMODEM 数据 ${_hex(start)}';
        continue;
      }

      try {
        return await _readPacket(firstByte: start);
      } catch (error) {
        lastError = error;
        await _sendByte(nak);
      }
    }
    throw YmodemException('等待 YMODEM 文件头超时: $lastError');
  }

  Future<_YmodemPacket> _readPacket({int? firstByte}) async {
    final start = firstByte ?? await _readRequiredByte();
    final size = switch (start) {
      soh => 128,
      stx => 1024,
      can => throw const YmodemException('对端取消传输'),
      _ => throw YmodemException('未知 YMODEM 包头: ${_hex(start)}'),
    };
    final block = await _readRequiredByte();
    final complement = await _readRequiredByte();
    if (((block + complement) & 0xFF) != 0xFF) {
      throw const YmodemException('YMODEM 块号校验失败');
    }
    final payload = Uint8List(size);
    for (var i = 0; i < size; i++) {
      payload[i] = await _readRequiredByte();
    }
    final crcHigh = await _readRequiredByte();
    final crcLow = await _readRequiredByte();
    final expectedCrc = (crcHigh << 8) | crcLow;
    final actualCrc = crc16Ccitt(payload);
    if (actualCrc != expectedCrc) {
      throw const YmodemException('YMODEM CRC 校验失败');
    }
    return _YmodemPacket(block, payload);
  }

  Future<int?> _readByteWithTimeout({bool allowTimeout = false}) async {
    try {
      if (_incoming.isNotEmpty) return _incoming.removeFirst();
      final completer = _pendingByte = Completer<int>();
      return await completer.future.timeout(_packetTimeout);
    } on TimeoutException {
      _pendingByte = null;
      if (allowTimeout) return null;
      throw const YmodemException('等待 YMODEM 数据超时');
    }
  }

  Future<int> _readRequiredByte() async {
    final byte = await _readByteWithTimeout();
    if (byte == null) {
      throw const YmodemException('等待 YMODEM 数据超时');
    }
    return byte;
  }

  Future<void> _sendByte(int byte) async {
    await _sendBytes(Uint8List.fromList([byte]));
  }

  void _resetIncomingBuffer() {
    _incoming.clear();
    final pending = _pendingByte;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const YmodemException('YMODEM 输入已重置'));
    }
    _pendingByte = null;
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const YmodemException('YMODEM 已取消');
  }

  void _setStatus(YmodemTransferStatus value) {
    _status = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  static Uint8List buildHeaderPacketForTest(String fileName, int fileSize) {
    return _buildHeaderPacket(fileName, fileSize);
  }

  static Uint8List buildDataPacketForTest(Uint8List payload, int blockNumber) {
    return _buildDataPacket(payload, blockNumber);
  }

  static Uint8List _buildHeaderPacket(String fileName, int fileSize) {
    final payload = Uint8List(128);
    if (fileName.isNotEmpty) {
      final nameBytes = _ascii(fileName);
      final sizeBytes = _ascii(fileSize.toString());
      payload.setRange(0, math.min(nameBytes.length, 100), nameBytes);
      final sizeOffset = math.min(nameBytes.length, 100) + 1;
      payload.setRange(
        sizeOffset,
        math.min(sizeOffset + sizeBytes.length, payload.length),
        sizeBytes,
      );
    }
    return _buildDataPacket(payload, 0);
  }

  static Uint8List _buildDataPacket(Uint8List payload, int blockNumber) {
    final packet = Uint8List(payload.length + 5);
    packet[0] = payload.length == 1024 ? stx : soh;
    packet[1] = blockNumber & 0xFF;
    packet[2] = 0xFF - packet[1];
    packet.setRange(3, 3 + payload.length, payload);
    final crc = crc16Ccitt(payload);
    packet[packet.length - 2] = (crc >> 8) & 0xFF;
    packet[packet.length - 1] = crc & 0xFF;
    return packet;
  }

  static _YmodemHeader _parseHeader(Uint8List payload) {
    final nameEnd = payload.indexOf(0);
    final fileName =
        nameEnd <= 0 ? '' : String.fromCharCodes(payload.take(nameEnd));
    if (fileName.isEmpty) return const _YmodemHeader('', 0);
    final rest = payload.skip(nameEnd + 1).takeWhile((byte) => byte != 0);
    final fields = String.fromCharCodes(rest).trim().split(RegExp(r'\s+'));
    final fileSize =
        fields.isEmpty || fields.first.isEmpty
            ? 0
            : int.tryParse(fields.first) ?? 0;
    return _YmodemHeader(fileName, fileSize);
  }

  static Future<File> _resolveReceiveFile(
    Directory directory,
    String name,
  ) async {
    final safeName = name
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .last
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    var file = File('${directory.path}/$safeName');
    if (!await file.exists()) return file;
    final dot = safeName.lastIndexOf('.');
    final base = dot <= 0 ? safeName : safeName.substring(0, dot);
    final ext = dot <= 0 ? '' : safeName.substring(dot);
    for (var i = 1; i < 10000; i++) {
      file = File('${directory.path}/${base}_$i$ext');
      if (!await file.exists()) return file;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return File('${directory.path}/${base}_$stamp$ext');
  }

  static List<int> _ascii(String value) => value.codeUnits
      .map((code) => code >= 0 && code <= 0x7F ? code : 0x5F)
      .toList(growable: false);

  static int crc16Ccitt(List<int> data) {
    var crc = 0;
    for (final byte in data) {
      crc ^= byte << 8;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static String _hex(int byte) => '0x${byte.toRadixString(16).padLeft(2, '0')}';
}

class _YmodemPacket {
  final int blockNumber;
  final Uint8List payload;
  const _YmodemPacket(this.blockNumber, this.payload);
}

class _YmodemHeader {
  final String fileName;
  final int fileSize;
  const _YmodemHeader(this.fileName, this.fileSize);
}
