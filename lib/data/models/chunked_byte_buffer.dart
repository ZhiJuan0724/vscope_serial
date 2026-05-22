import 'dart:typed_data';

/// Append-only byte buffer backed by fixed-size chunks.
///
/// This keeps long captures out of one huge growable `List<int>` and avoids
/// head-removal costs. It is intentionally simple: captures are cleared as a
/// whole between sessions, not trimmed from the front.
class ChunkedByteBuffer {
  final int chunkSize;
  final List<Uint8List> _chunks = [];
  int _length = 0;

  ChunkedByteBuffer({this.chunkSize = 1024 * 1024}) : assert(chunkSize > 0);

  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length > 0;

  void clear() {
    _chunks.clear();
    _length = 0;
  }

  void append(Uint8List bytes) {
    if (bytes.isEmpty) return;

    var sourceOffset = 0;
    while (sourceOffset < bytes.length) {
      final chunkIndex = _length ~/ chunkSize;
      final chunkOffset = _length % chunkSize;
      if (chunkIndex == _chunks.length) {
        _chunks.add(Uint8List(chunkSize));
      }

      final writable = chunkSize - chunkOffset;
      final count = (bytes.length - sourceOffset).clamp(0, writable).toInt();
      _chunks[chunkIndex].setRange(
        chunkOffset,
        chunkOffset + count,
        bytes,
        sourceOffset,
      );
      sourceOffset += count;
      _length += count;
    }
  }

  Uint8List readRange(int offset, int length) {
    RangeError.checkValueInInterval(offset, 0, _length, 'offset');
    if (length < 0 || offset + length > _length) {
      throw RangeError.range(length, 0, _length - offset, 'length');
    }

    final output = Uint8List(length);
    var remaining = length;
    var sourceOffset = offset;
    var targetOffset = 0;
    while (remaining > 0) {
      final chunkIndex = sourceOffset ~/ chunkSize;
      final chunkOffset = sourceOffset % chunkSize;
      final count = remaining.clamp(0, chunkSize - chunkOffset).toInt();
      output.setRange(
        targetOffset,
        targetOffset + count,
        _chunks[chunkIndex],
        chunkOffset,
      );
      sourceOffset += count;
      targetOffset += count;
      remaining -= count;
    }
    return output;
  }

  Uint8List toBytes() => readRange(0, _length);
}

/// Packet-oriented view over [ChunkedByteBuffer].
class FixedPacketByteBuffer {
  final int packetSize;
  final ChunkedByteBuffer _bytes;

  FixedPacketByteBuffer({required this.packetSize, int chunkSize = 1024 * 1024})
    : assert(packetSize > 0),
      _bytes = ChunkedByteBuffer(chunkSize: chunkSize);

  int get byteLength => _bytes.length;
  int get packetCount => _bytes.length ~/ packetSize;
  bool get isEmpty => _bytes.isEmpty;
  bool get isNotEmpty => _bytes.isNotEmpty;

  void clear() => _bytes.clear();

  void appendPackets(Uint8List bytes) {
    if (bytes.length % packetSize != 0) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'must be a multiple of packetSize=$packetSize',
      );
    }
    _bytes.append(bytes);
  }

  void appendPacket(Uint8List bytes) {
    if (bytes.length != packetSize) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'must equal packetSize=$packetSize',
      );
    }
    _bytes.append(bytes);
  }

  Uint8List readPacket(int packetIndex) {
    RangeError.checkValueInInterval(
      packetIndex,
      0,
      packetCount - 1,
      'packetIndex',
    );
    return _bytes.readRange(packetIndex * packetSize, packetSize);
  }

  Uint8List readPackets(int startPacket, int count) {
    RangeError.checkValueInInterval(startPacket, 0, packetCount, 'startPacket');
    if (count < 0 || startPacket + count > packetCount) {
      throw RangeError.range(count, 0, packetCount - startPacket, 'count');
    }
    // Fixed-size frames allow direct index -> byte offset lookup, which keeps
    // historical window loading independent of total capture length.
    return _bytes.readRange(startPacket * packetSize, count * packetSize);
  }

  Uint8List toBytes() => _bytes.toBytes();
}
