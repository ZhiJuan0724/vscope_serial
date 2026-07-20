import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/utils/atomic_file.dart';

/// YMODEM 会话的本地角色。
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

/// 传输过程的不可变状态快照，供 Shell 页面单独订阅而不重建终端。
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

/// 基于统一串口写入链路的 YMODEM 单文件传输服务。
///
/// 接收输入按块缓冲而非逐字节 Future；超过高水位时发送 CAN 并失败，确保
/// 文件协议不会因静默丢包而生成看似成功的损坏文件。
class YmodemService {
  YmodemService({
    required FutureOr<void> Function(Uint8List data) sendBytes,
    Duration packetTimeout = const Duration(seconds: 8),
    int maxRetries = 10,
    int inputHighWaterBytes = defaultInputHighWaterBytes,
  }) : _sendBytes = sendBytes,
       _packetTimeout = packetTimeout,
       _maxRetries = maxRetries,
       _inputHighWaterBytes = inputHighWaterBytes,
       assert(inputHighWaterBytes > 0);

  static const int soh = 0x01;
  static const int stx = 0x02;
  static const int eot = 0x04;
  static const int ack = 0x06;
  static const int nak = 0x15;
  static const int can = 0x18;
  static const int crcRequest = 0x43;
  static const int eof = 0x1A;

  /// YMODEM 尚未处理的串口输入队列上限。
  static const int defaultInputHighWaterBytes = 4 * 1024 * 1024;
  static const int maxFileSize = 4 * 1024 * 1024 * 1024;

  final FutureOr<void> Function(Uint8List data) _sendBytes;
  final Duration _packetTimeout;
  final int _maxRetries;
  final int _inputHighWaterBytes;
  final _statusController = StreamController<YmodemTransferStatus>.broadcast();
  final Queue<Uint8List> _incoming = Queue<Uint8List>();

  int get incomingBytes => _incomingBytes;

  StreamSubscription<Uint8List>? _subscription;
  YmodemTransferStatus _status = const YmodemTransferStatus.idle();
  bool _cancelRequested = false;
  bool _inputOverloaded = false;
  bool _overloadCanSent = false;
  int _incomingOffset = 0;
  int _incomingBytes = 0;
  Completer<void>? _incomingSignal;

  Stream<YmodemTransferStatus> get statusStream => _statusController.stream;
  YmodemTransferStatus get status => _status;
  bool get isActive => _status.isActive;

  void attach(Stream<Uint8List> input) {
    _subscription?.cancel();
    _subscription = input.listen(addIncomingBytes);
  }

  void addIncomingBytes(Uint8List data) {
    // 空闲时忽略 Shell 文本流，避免命令提示符被后续误读为文件头。
    if (data.isEmpty || (!isActive && _incomingSignal == null)) return;
    if (_inputOverloaded) return;
    // YMODEM 不能像终端输出一样丢弃旧字节，积压即表示协议已无法可靠恢复。
    if (_incomingBytes + data.length > _inputHighWaterBytes) {
      _inputOverloaded = true;
      _incoming.clear();
      _incomingOffset = 0;
      _incomingBytes = 0;
      _notifyIncomingWaiter();
      unawaited(_sendInputOverloadCan());
      return;
    }
    _incoming.add(data);
    _incomingBytes += data.length;
    _notifyIncomingWaiter();
  }

  Future<void> sendFile(
    File file, {
    YmodemPacketSizeMode packetSizeMode = YmodemPacketSizeMode.auto,
  }) async {
    if (isActive) throw const YmodemException('YMODEM 正在传输中');
    _resetIncomingBuffer();
    _cancelRequested = false;
    RandomAccessFile? input;
    try {
      // 发送前固定文件长度；协议头和进度都依赖这个不可变值。
      final fileSize = await file.length();
      final fileName = file.uri.pathSegments.last;
      _setStatus(
        YmodemTransferStatus(
          direction: YmodemDirection.send,
          phase: YmodemPhase.waiting,
          fileName: fileName,
          totalBytes: fileSize,
          transferredBytes: 0,
          retryCount: 0,
          message: '等待接收方',
        ),
      );
      if (fileSize < 0 || fileSize > maxFileSize) {
        throw const YmodemException('YMODEM 文件大小必须在 0 到 4 GiB 之间');
      }
      input = await file.open();
      await _waitForByte(crcRequest, '等待接收方请求 CRC');
      await _sendPacket(_buildHeaderPacket(fileName, fileSize), 0);
      await _waitForByte(crcRequest, '等待数据请求');

      var block = 1;
      var offset = 0;
      while (offset < fileSize) {
        _throwIfCancelled();
        final size = packetSizeMode.payloadSizeFor(fileSize - offset);
        final bytes = await input.read(size);
        if (bytes.isEmpty) {
          throw const YmodemException('发送文件读取提前结束');
        }
        final payload = Uint8List(size)..fillRange(0, size, eof);
        payload.setRange(0, bytes.length, bytes);
        await _sendPacket(_buildDataPacket(payload, block), block);
        offset += bytes.length;
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
    } finally {
      await input?.close();
    }
  }

  Future<File?> receiveFile(Directory directory) async {
    if (isActive) throw const YmodemException('YMODEM 正在传输中');
    await directory.create(recursive: true);
    _resetIncomingBuffer();
    _cancelRequested = false;
    // 接收成功前只写 .part，完整 EOT 和结束头握手后才提升为用户文件。
    RandomAccessFile? output;
    File? target;
    File? partFile;
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
      partFile = File('${target.path}.part');
      if (await partFile.exists()) await partFile.delete();
      output = await partFile.open(mode: FileMode.write);
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
          await output!.flush();
          await output.close();
          output = null;
          await const AtomicFileCommitter().commitPart(target.path);
          partFile = null;
          _setStatus(
            _status.copyWith(
              phase: YmodemPhase.completed,
              transferredBytes: metadata.fileSize,
              message: '接收完成',
              savedPath: target.path,
            ),
          );
          return target;
        }
        late final _YmodemPacket packet;
        try {
          packet = await _readPacket(firstByte: first);
        } on YmodemException {
          await _sendByte(nak);
          _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
          if (_status.retryCount >= _maxRetries) {
            throw const YmodemException('YMODEM 数据块连续校验失败');
          }
          continue;
        }
        final expected = expectedBlock & 0xFF;
        final previous = (expectedBlock - 1) & 0xFF;
        if (packet.blockNumber == previous) {
          // ACK 丢失时发送方会重发上一块；只重新 ACK，不能重复写入文件。
          await _sendByte(ack);
          continue;
        }
        if (packet.blockNumber != expected) {
          await _sendByte(nak);
          _setStatus(_status.copyWith(retryCount: _status.retryCount + 1));
          continue;
        }
        final remaining = metadata.fileSize - written;
        final toWrite = math.min(packet.payload.length, math.max(remaining, 0));
        if (toWrite > 0) {
          await output!.writeFrom(packet.payload, 0, toWrite);
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
    } catch (error) {
      try {
        await output?.close();
      } catch (_) {}
      if (partFile != null && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
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
    // 取消必须主动通知对端；仅清除本地状态会让对端继续等待 ACK。
    if (!isActive) return;
    _cancelRequested = true;
    _notifyIncomingWaiter();
    try {
      await _sendBytes(Uint8List.fromList([can, can, can, can]));
    } catch (_) {
      // 断线过程中无法通知对端，但本地等待仍必须可靠结束。
    }
    _setStatus(_status.copyWith(phase: YmodemPhase.cancelled, message: '已取消'));
  }

  /// 串口断开时只终止本地状态，不再尝试向已失效的句柄发送 CAN。
  void abort(String message) {
    if (!isActive) return;
    _cancelRequested = true;
    _incoming.clear();
    _incomingOffset = 0;
    _incomingBytes = 0;
    _notifyIncomingWaiter();
    _setStatus(
      _status.copyWith(phase: YmodemPhase.cancelled, message: message),
    );
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
    // 一次等待并读取完整包，避免每字节创建 Future 导致高波特率下调度放大。
    final start = firstByte ?? await _readRequiredByte();
    final size = switch (start) {
      soh => 128,
      stx => 1024,
      can => throw const YmodemException('对端取消传输'),
      _ => throw YmodemException('未知 YMODEM 包头: ${_hex(start)}'),
    };
    // 一次等待并取出块号、负块号、完整 payload 和 CRC，避免每字节创建 Future。
    final body = await _readRequiredBytes(size + 4);
    final block = body[0];
    final complement = body[1];
    if (((block + complement) & 0xFF) != 0xFF) {
      throw const YmodemException('YMODEM 块号校验失败');
    }
    final payload = Uint8List.sublistView(body, 2, size + 2);
    final crcHigh = body[size + 2];
    final crcLow = body[size + 3];
    final expectedCrc = (crcHigh << 8) | crcLow;
    final actualCrc = crc16Ccitt(payload);
    if (actualCrc != expectedCrc) {
      throw const YmodemException('YMODEM CRC 校验失败');
    }
    return _YmodemPacket(block, payload);
  }

  Future<int?> _readByteWithTimeout({bool allowTimeout = false}) async {
    final ready = await _waitForIncoming(1, allowTimeout: allowTimeout);
    if (!ready) return null;
    return _removeIncomingByte();
  }

  Future<int> _readRequiredByte() async {
    final byte = await _readByteWithTimeout();
    if (byte == null) {
      throw const YmodemException('等待 YMODEM 数据超时');
    }
    return byte;
  }

  Future<Uint8List> _readRequiredBytes(int length) async {
    await _waitForIncoming(length);
    return _removeIncomingBytes(length);
  }

  Future<bool> _waitForIncoming(int length, {bool allowTimeout = false}) async {
    while (_incomingBytes < length) {
      _throwIfCancelled();
      _throwIfInputOverloaded();
      final signal = _incomingSignal ??= Completer<void>();
      try {
        await signal.future.timeout(_packetTimeout);
      } on TimeoutException {
        if (identical(_incomingSignal, signal)) _incomingSignal = null;
        if (allowTimeout) return false;
        throw const YmodemException('等待 YMODEM 数据超时');
      }
    }
    _throwIfInputOverloaded();
    return true;
  }

  int _removeIncomingByte() {
    final chunk = _incoming.first;
    final byte = chunk[_incomingOffset++];
    _incomingBytes--;
    if (_incomingOffset == chunk.length) {
      _incoming.removeFirst();
      _incomingOffset = 0;
    }
    return byte;
  }

  Uint8List _removeIncomingBytes(int length) {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = _incoming.first;
      final available = chunk.length - _incomingOffset;
      final count = math.min(available, length - written);
      result.setRange(written, written + count, chunk, _incomingOffset);
      written += count;
      _incomingOffset += count;
      _incomingBytes -= count;
      if (_incomingOffset == chunk.length) {
        _incoming.removeFirst();
        _incomingOffset = 0;
      }
    }
    return result;
  }

  Future<void> _sendByte(int byte) async {
    await _sendBytes(Uint8List.fromList([byte]));
  }

  void _resetIncomingBuffer() {
    _incoming.clear();
    _incomingOffset = 0;
    _incomingBytes = 0;
    _inputOverloaded = false;
    _overloadCanSent = false;
    _notifyIncomingWaiter();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const YmodemException('YMODEM 已取消');
  }

  void _throwIfInputOverloaded() {
    if (_inputOverloaded) {
      throw const YmodemException('YMODEM 输入过载，传输已终止');
    }
  }

  void _notifyIncomingWaiter() {
    final signal = _incomingSignal;
    _incomingSignal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> _sendInputOverloadCan() async {
    if (_overloadCanSent) return;
    _overloadCanSent = true;
    try {
      await _sendBytes(Uint8List.fromList([can, can, can, can]));
    } catch (_) {
      // 输入已不可恢复；即使串口同时断开，也必须保留本地过载失败状态。
    }
    if (isActive) {
      _setStatus(
        _status.copyWith(
          phase: YmodemPhase.failed,
          message: 'YMODEM 输入过载，传输已终止',
        ),
      );
    }
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
            ? null
            : int.tryParse(fields.first);
    if (fileSize == null || fileSize < 0 || fileSize > maxFileSize) {
      throw const YmodemException('YMODEM 文件大小无效或超过 4 GiB');
    }
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
