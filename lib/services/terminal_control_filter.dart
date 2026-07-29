/// 流式移除 ANSI/VT 终端控制序列，保留可显示文本和换行、回车、退格。
///
/// 控制序列可能被任意拆分到相邻数据块中，因此不能用逐块正则表达式处理。
/// 这里覆盖常见 CSI（颜色、光标、清屏）、OSC（窗口标题）以及
/// DCS/PM/APC 字符串，避免 ESC 等控制字节被 Flutter 当作可见方框绘制。
class TerminalControlFilter {
  _TerminalControlState _state = _TerminalControlState.text;

  String add(String input) {
    if (input.isEmpty) return '';
    final output = StringBuffer();
    for (final codePoint in input.runes) {
      switch (_state) {
        case _TerminalControlState.text:
          if (codePoint == 0x1b) {
            _state = _TerminalControlState.escape;
          } else if (codePoint == 0x00 ||
              codePoint == 0x07 ||
              codePoint == 0x0b ||
              codePoint == 0x0c ||
              codePoint == 0x7f) {
            // NUL、BEL、VT、FF 和 DEL 不产生可见字符。
          } else {
            output.writeCharCode(codePoint);
          }
        case _TerminalControlState.escape:
          switch (codePoint) {
            case 0x5b: // CSI: ESC [
              _state = _TerminalControlState.csi;
            case 0x5d: // OSC: ESC ]
              _state = _TerminalControlState.osc;
            case 0x50 || 0x58 || 0x5e || 0x5f: // DCS、SOS、PM、APC
              _state = _TerminalControlState.controlString;
            default:
              // ESC 后的中间字节为 0x20~0x2f，最终字节为 0x30~0x7e。
              if (codePoint >= 0x30 && codePoint <= 0x7e) {
                _state = _TerminalControlState.text;
              } else if (codePoint < 0x20 || codePoint > 0x2f) {
                _state = _TerminalControlState.text;
              }
          }
        case _TerminalControlState.csi:
          // CSI 的最终字节范围为 0x40~0x7e。
          if (codePoint >= 0x40 && codePoint <= 0x7e) {
            _state = _TerminalControlState.text;
          }
        case _TerminalControlState.osc:
        case _TerminalControlState.controlString:
          if (codePoint == 0x07) {
            _state = _TerminalControlState.text;
          } else if (codePoint == 0x1b) {
            _state = _TerminalControlState.controlStringEscape;
          }
        case _TerminalControlState.controlStringEscape:
          if (codePoint == 0x5c) {
            _state = _TerminalControlState.text;
          } else if (codePoint != 0x1b) {
            _state = _TerminalControlState.controlString;
          }
      }
    }
    return output.toString();
  }

  void reset() {
    _state = _TerminalControlState.text;
  }
}

enum _TerminalControlState {
  text,
  escape,
  csi,
  osc,
  controlString,
  controlStringEscape,
}
