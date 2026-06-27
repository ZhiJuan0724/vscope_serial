/// 将用户可见名称转换为适合作为文件名的文本。
String sanitizeFileName(String value, {String fallback = 'export'}) {
  final sanitized = value.trim().replaceAll(
    RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
    '_',
  );
  final withoutTrailingDots = sanitized.replaceAll(RegExp(r'[. ]+$'), '');
  return withoutTrailingDots.isEmpty ? fallback : withoutTrailingDots;
}
