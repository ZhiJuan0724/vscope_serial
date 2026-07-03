import '../data/models/address_config_profile.dart';

class AddressProfileCsvImporter {
  AddressProfileCsvImporter._();

  static List<AddressChannelPreset> parse(
    String source, {
    required AddressProfileProtocolType protocolType,
  }) {
    final rows = _parseCsv(source);
    if (rows.isEmpty) {
      throw const FormatException('CSV 文件为空');
    }

    var startIndex = 0;
    if (_presetFromRow(rows.first, protocolType) == null) {
      startIndex = 1;
    }

    final presets = <AddressChannelPreset>[];
    for (var i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      if (row.length < 2) {
        throw FormatException('第 ${i + 1} 行至少需要名称和地址两列');
      }

      final name = row[0].trim();
      final preset = _presetFromRow(row, protocolType);
      if (name.isEmpty) {
        throw FormatException('第 ${i + 1} 行通道名称为空');
      }
      if (preset == null) {
        throw FormatException('第 ${i + 1} 行通道地址格式错误');
      }
      presets.add(preset);
    }

    if (presets.isEmpty) {
      throw const FormatException('CSV 文件没有可导入的地址预设');
    }
    return presets;
  }

  static AddressChannelPreset? _presetFromRow(
    List<String> row,
    AddressProfileProtocolType protocolType,
  ) {
    if (row.length < 2) return null;
    return AddressChannelPreset.tryParseAddress(
      name: row[0].trim(),
      text: row[1],
      protocolType: protocolType,
    );
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
