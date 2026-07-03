String formatPlotValue(double value) {
  if (!value.isFinite) return value.toString();

  final rounded = value.roundToDouble();
  if ((value - rounded).abs() < 1e-9) return rounded.toInt().toString();

  final text = value.toStringAsPrecision(12);
  if (!text.contains('.') || text.contains('e') || text.contains('E')) {
    return text;
  }
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
