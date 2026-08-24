/// Shell 与 RTT 文本终端共同支持的字体候选。
///
/// 两个终端页面必须复用同一清单，避免新增字体时出现可选范围不一致。
const List<String> terminalFontFamilies = <String>[
  'Consolas',
  'Cascadia Mono',
  'Cascadia Code',
  'Courier New',
  'JetBrains Mono',
  'Fira Code',
  'Sarasa Mono SC',
  'SarasaUiSC',
];
