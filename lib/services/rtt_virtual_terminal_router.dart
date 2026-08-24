import 'dart:typed_data';

/// 一段已经归属到 SEGGER 虚拟终端的数据。
class RttTerminalSegment {
  const RttTerminalSegment(this.terminal, this.data);

  final int terminal;
  final Uint8List data;
}

/// 增量解析 SEGGER RTT Up 0 虚拟终端切换序列。
///
/// `0xFF` 后跟 ASCII `0-9` 或 `A-F` 会切换后续数据所属终端。控制序列
/// 可以跨原始数据块；非法序列中的 `0xFF` 和后续字节都会作为普通数据保留。
class RttVirtualTerminalRouter {
  int _terminal = 0;
  bool _pendingMarker = false;

  int get currentTerminal => _terminal;

  List<RttTerminalSegment> add(Uint8List input) {
    final result = <RttTerminalSegment>[];
    var buffer = <int>[];
    var bufferTerminal = _terminal;

    void flush() {
      if (buffer.isEmpty) return;
      result.add(
        RttTerminalSegment(bufferTerminal, Uint8List.fromList(buffer)),
      );
      buffer = <int>[];
    }

    void append(int byte) {
      if (buffer.isNotEmpty && bufferTerminal != _terminal) flush();
      bufferTerminal = _terminal;
      buffer.add(byte);
    }

    for (final byte in input) {
      if (_pendingMarker) {
        _pendingMarker = false;
        final selected = _decodeTerminal(byte);
        if (selected != null) {
          flush();
          _terminal = selected;
          bufferTerminal = selected;
          continue;
        }
        append(0xff);
        if (byte == 0xff) {
          _pendingMarker = true;
        } else {
          append(byte);
        }
        continue;
      }
      if (byte == 0xff) {
        _pendingMarker = true;
      } else {
        append(byte);
      }
    }
    flush();
    return result;
  }

  void reset() {
    _terminal = 0;
    _pendingMarker = false;
  }

  int? _decodeTerminal(int byte) {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
    return null;
  }
}
