import '../data/models/zobow_config_profile.dart';

class AddressProfileCsvImporter {
  AddressProfileCsvImporter._();

  static List<ZobowChannelPreset> parse(
    String source, {
    required AddressProfileProtocolType protocolType,
  }) {
    final rows = _parseCsv(source);
    if (rows.isEmpty) {
      throw const FormatException('CSV 文件为空');
    }

    var startIndex = 0;
    if (_addressFromRow(rows.first, protocolType) == null) {
      startIndex = 1;
    }

    final presets = <ZobowChannelPreset>[];
    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      if (row.length < 2) {
        throw FormatException('第 ${i + 1} 行至少需要名称和地址两列');
      }

      final name = row[0].trim();
      final address = _addressFromRow(row, protocolType);
      if (name.isEmpty) {
        throw FormatException('第 ${i + 1} 行通道名称为空');
      }
      if (address == null) {
        throw FormatException('第 ${i + 1} 行通道地址格式错误');
      }
      presets.add(ZobowChannelPreset(name: name, address: address));
    }

    if (presets.isEmpty) {
      throw const FormatException('CSV 文件没有可导入的地址预设');
    }
    return presets;
  }

  static int? _addressFromRow(
    List<String> row,
    AddressProfileProtocolType protocolType,
  ) {
    if (row.length < 2) return null;
    return _parseAddress(row[1], protocolType: protocolType);
  }

  static int? _parseAddress(
    String text, {
    required AddressProfileProtocolType protocolType,
  }) {
    final value = text.trim();
    if (value.isEmpty) return null;
    final hasHexPrefix = value.startsWith('0x') || value.startsWith('0X');
    final digits = hasHexPrefix ? value.substring(2) : value;
    if (digits.isEmpty) return null;

    final radix =
        protocolType == AddressProfileProtocolType.rProtocol && !hasHexPrefix
            ? 10
            : 16;
    final pattern =
        radix == 10 ? RegExp(r'^[0-9]+$') : RegExp(r'^[0-9a-fA-F]+$');
    if (!pattern.hasMatch(digits)) return null;

    final address = int.tryParse(digits, radix: radix);
    if (address == null || address < 0 || address > 0xFFFFFFFF) return null;
    return address & 0xFFFFFFFF;
  }

  static List<List<String>> _parseCsv(String source) {
    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;

    void endCell() {
      row.add(cell.toString());
      cell.clear();
    }

    void endRow() {
      endCell();
      rows.add(List<String>.from(row));
      row.clear();
    }

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (inQuotes) {
        if (char == '"') {
          final nextIsQuote = i + 1 < source.length && source[i + 1] == '"';
          if (nextIsQuote) {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cell.write(char);
        }
        continue;
      }

      if (char == '"') {
        inQuotes = true;
      } else if (char == ',') {
        endCell();
      } else if (char == '\n') {
        endRow();
      } else if (char == '\r') {
        if (i + 1 < source.length && source[i + 1] == '\n') i++;
        endRow();
      } else {
        cell.write(char);
      }
    }

    if (inQuotes) {
      throw const FormatException('CSV 引号未闭合');
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      endRow();
    }
    return rows;
  }
}
