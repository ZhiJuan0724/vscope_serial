import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/app_strings.dart';
import 'common_widgets.dart';

/// 自定义通道/探针颜色选择器，供绘图页、探针页和 Modbus 两页共享。
///
/// 弹出 HSV 饱和度/明度选择、色相条、RGB 数值与十六进制输入，确认后返回
/// 选中的颜色；取消返回 `null`。
Future<Color?> showPlotCustomColorPicker(
  BuildContext context,
  Color initialColor,
) async {
  var selectedColor = _opaqueColor(initialColor);
  var selectedHsv = HSVColor.fromColor(selectedColor);
  var hasError = false;
  final redController = TextEditingController();
  final greenController = TextEditingController();
  final blueController = TextEditingController();
  final hexController = TextEditingController();

  void syncControllersFromColor(
    Color color, {
    TextEditingController? editingController,
  }) {
    final value = color.toARGB32();
    if (editingController != redController) {
      redController.text = ((value >> 16) & 0xFF).toString();
    }
    if (editingController != greenController) {
      greenController.text = ((value >> 8) & 0xFF).toString();
    }
    if (editingController != blueController) {
      blueController.text = (value & 0xFF).toString();
    }
    if (editingController != hexController) {
      hexController.text = _formatHexColor(color);
    }
  }

  syncControllersFromColor(selectedColor);
  final result = await showDialog<Color>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          void setColor(
            Color color, {
            TextEditingController? editingController,
          }) {
            selectedColor = _opaqueColor(color);
            selectedHsv = HSVColor.fromColor(selectedColor);
            hasError = false;
            syncControllersFromColor(
              selectedColor,
              editingController: editingController,
            );
          }

          void updateFromRgb(TextEditingController editingController) {
            final r = int.tryParse(redController.text);
            final g = int.tryParse(greenController.text);
            final b = int.tryParse(blueController.text);
            if (!_isRgbByte(r) || !_isRgbByte(g) || !_isRgbByte(b)) {
              setDialogState(() => hasError = true);
              return;
            }
            setDialogState(() {
              setColor(
                Color.fromARGB(255, r!, g!, b!),
                editingController: editingController,
              );
            });
          }

          void updateFromHex(String value) {
            final parsed = _parseHexColor(value);
            if (parsed == null) {
              setDialogState(() => hasError = value.trim().isNotEmpty);
              return;
            }
            setDialogState(() {
              setColor(parsed, editingController: hexController);
            });
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(AppStrings.plot.customColor),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.plot.customColorPreview,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SaturationValuePalette(
                    hsvColor: selectedHsv,
                    onChanged: (saturation, value) {
                      setDialogState(() {
                        setColor(
                          selectedHsv
                              .withSaturation(saturation)
                              .withValue(value)
                              .toColor(),
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  _HuePalette(
                    hue: selectedHsv.hue,
                    onChanged: (hue) {
                      setDialogState(() {
                        setColor(selectedHsv.withHue(hue).toColor());
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.redChannel,
                          controller: redController,
                          onChanged: () => updateFromRgb(redController),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.greenChannel,
                          controller: greenController,
                          onChanged: () => updateFromRgb(greenController),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ColorNumberField(
                          label: AppStrings.plot.blueChannel,
                          controller: blueController,
                          onChanged: () => updateFromRgb(blueController),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AppDialogTextField(
                    controller: hexController,
                    labelText: AppStrings.plot.hexColor,
                    hintText: AppStrings.plot.hexColorHint,
                    errorText:
                        hasError ? AppStrings.plot.colorInputInvalid : null,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[#0-9a-fA-F]'),
                      ),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    textCapitalization: TextCapitalization.characters,
                    onChanged: updateFromHex,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.common.cancel),
              ),
              ElevatedButton(
                onPressed:
                    hasError
                        ? null
                        : () => Navigator.pop(context, selectedColor),
                child: Text(AppStrings.common.confirm),
              ),
            ],
          );
        },
      );
    },
  );

  redController.dispose();
  greenController.dispose();
  blueController.dispose();
  hexController.dispose();
  return result;
}

class _SaturationValuePalette extends StatelessWidget {
  final HSVColor hsvColor;
  final void Function(double saturation, double value) onChanged;

  const _SaturationValuePalette({
    required this.hsvColor,
    required this.onChanged,
  });

  void _update(Offset position, Size size) {
    final saturation = (position.dx / size.width).clamp(0.0, 1.0);
    final value = 1 - (position.dy / size.height).clamp(0.0, 1.0);
    onChanged(saturation, value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 150);
        return GestureDetector(
          key: const ValueKey('channel-color-palette'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _update(details.localPosition, size),
          onPanStart: (details) => _update(details.localPosition, size),
          onPanUpdate: (details) => _update(details.localPosition, size),
          child: CustomPaint(
            size: size,
            painter: _SaturationValuePainter(hsvColor),
          ),
        );
      },
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  final HSVColor hsvColor;

  const _SaturationValuePainter(this.hsvColor);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = const Radius.circular(4);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white,
            HSVColor.fromAHSV(1, hsvColor.hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.grey.shade500,
    );

    final center = Offset(
      hsvColor.saturation * size.width,
      (1 - hsvColor.value) * size.height,
    );
    canvas.drawCircle(
      center,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) =>
      oldDelegate.hsvColor != hsvColor;
}

class _HuePalette extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HuePalette({required this.hue, required this.onChanged});

  void _update(double dx, double width) {
    onChanged((dx / width).clamp(0.0, 1.0) * 360);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 18);
        return GestureDetector(
          key: const ValueKey('channel-color-hue'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _update(details.localPosition.dx, size.width),
          onPanStart:
              (details) => _update(details.localPosition.dx, size.width),
          onPanUpdate:
              (details) => _update(details.localPosition.dx, size.width),
          child: CustomPaint(size: size, painter: _HuePainter(hue)),
        );
      },
    );
  }
}

class _HuePainter extends CustomPainter {
  final double hue;

  const _HuePainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = const Radius.circular(4);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    canvas.restore();

    final x = (hue / 360) * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height / 2),
          width: 5,
          height: 22,
        ),
        const Radius.circular(2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height / 2),
          width: 7,
          height: 24,
        ),
        const Radius.circular(3),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => oldDelegate.hue != hue;
}

class _ColorNumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;

  const _ColorNumberField({
    required this.label,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppLabeledField(
      label: label,
      child: TextField(
        controller: controller,
        decoration: secondaryDialogFieldDecoration(),
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

bool _isRgbByte(int? value) => value != null && value >= 0 && value <= 255;

Color _opaqueColor(Color color) {
  final value = color.toARGB32();
  return Color.fromARGB(
    255,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  );
}

String _formatHexColor(Color color) {
  final value = color.toARGB32() & 0xFFFFFF;
  return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? _parseHexColor(String text) {
  final raw = text.trim();
  final hex = raw.startsWith('#') ? raw.substring(1) : raw;
  if (hex.length != 6 || !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
    return null;
  }
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}
