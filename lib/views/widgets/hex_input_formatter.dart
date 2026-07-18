import 'package:flutter/services.dart';

/// Filters HEX input to hexadecimal characters and spaces only.
class HexInputFormatter extends TextInputFormatter {
  const HexInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final filtered = newValue.text.replaceAll(RegExp(r'[^0-9A-Fa-f ]'), '');
    return TextEditingValue(
      text: filtered,
      selection: TextSelection.collapsed(offset: filtered.length),
    );
  }
}

/// Groups HEX characters as byte pairs separated by spaces.
String formatHexByteGroups(String value) {
  final hexOnly = value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  final formatted = <String>[];
  for (var i = 0; i < hexOnly.length; i += 2) {
    if (i + 2 <= hexOnly.length) {
      formatted.add(hexOnly.substring(i, i + 2));
    } else {
      formatted.add(hexOnly.substring(i));
    }
  }
  return formatted.join(' ');
}
