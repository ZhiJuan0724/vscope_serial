/// 使用二进制单位格式化字节数，供状态栏、设置页和限制提示统一显示。
String formatByteSize(num bytes, {int fractionDigits = 1}) {
  final value = bytes.toDouble();
  if (value.abs() < 1024) return '${value.round()} B';
  const units = ['KiB', 'MiB', 'GiB'];
  var scaled = value;
  var unit = -1;
  do {
    scaled /= 1024;
    unit++;
  } while (scaled.abs() >= 1024 && unit < units.length - 1);
  final digits = scaled.abs() >= 100 ? 0 : fractionDigits;
  return '${scaled.toStringAsFixed(digits)} ${units[unit]}';
}
