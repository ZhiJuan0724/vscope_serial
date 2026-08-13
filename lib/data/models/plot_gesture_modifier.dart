/// 绘图轴向缩放手势使用的键盘修饰键。
enum PlotGestureModifier {
  shift('shift', 'Shift'),
  control('control', 'Ctrl');

  const PlotGestureModifier(this.value, this.label);

  final String value;
  final String label;

  static PlotGestureModifier fromString(String? value) =>
      value == control.value ? control : shift;
}
