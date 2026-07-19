import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/data/parser/firewater_parser.dart';
import 'package:vscope_serial/data/parser/just_float_parser.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';

const _runParserSoak = bool.fromEnvironment('RUN_P1_PARSER_SOAK');
const _noiseBytes = int.fromEnvironment(
  'P1_NOISE_BYTES',
  defaultValue: 1024 * 1024 * 1024,
);
const _importFile = String.fromEnvironment('P1_IMPORT_FILE');
const _importPoints = int.fromEnvironment('P1_IMPORT_POINTS');

void main() {
  test(
    'P1 parsers recover after a large stream without delimiters',
    () {
      const chunkBytes = 64 * 1024;
      final noise = Uint8List(chunkBytes)..fillRange(0, chunkBytes, 0x55);
      final fireWater = FireWaterParser();
      final justFloat = JustFloatParser(
        ParserConfig.justFloatDefault()..channelCount = 2,
      );
      addTearDown(fireWater.dispose);
      addTearDown(justFloat.dispose);

      var written = 0;
      while (written < _noiseBytes) {
        final count = (_noiseBytes - written).clamp(0, chunkBytes);
        final chunk =
            count == chunkBytes
                ? noise
                : Uint8List.sublistView(noise, 0, count);
        fireWater.feedBatch(chunk);
        justFloat.feedBatch(chunk);
        written += count;
      }

      final fireResult = fireWater.feedBatch(
        Uint8List.fromList('\n1,2,3,4\n'.codeUnits),
      );
      justFloat.feedBatch(Uint8List.fromList(JustFloatParser.tail));
      final justResult = justFloat.feedBatch(_justFloatFrame([3, 4]));

      expect(fireWater.diagnostics.droppedBytes, greaterThan(0));
      expect(fireResult.single.values, [1, 2, 3, 4]);
      expect(justFloat.diagnostics.droppedBytes, greaterThan(0));
      expect(justResult.single.values, [3, 4]);
    },
    skip:
        !_runParserSoak
            ? 'Run with test_tools/run_p1_stability_soak.ps1'
            : false,
    timeout: const Timeout(Duration(hours: 1)),
  );

  test(
    'P1 large BIN import stays within the configured history transaction',
    () async {
      expect(await File(_importFile).exists(), isTrue);
      AppSettings().plotHistoryMemoryLimitGiB = 8;
      final serialService = SerialService();
      final viewModel = PlotViewModel(serialService);
      addTearDown(viewModel.dispose);
      addTearDown(serialService.dispose);

      final error = await viewModel.importFromBin(_importFile);

      expect(error, isNull);
      if (_importPoints > 0) expect(viewModel.pointCount, _importPoints);
    },
    skip:
        _importFile.isEmpty
            ? 'Run with test_tools/run_p1_stability_soak.ps1'
            : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}

Uint8List _justFloatFrame(List<double> values) {
  final data = ByteData(values.length * 4 + JustFloatParser.tail.length);
  for (var index = 0; index < values.length; index++) {
    data.setFloat32(index * 4, values[index], Endian.little);
  }
  final bytes = data.buffer.asUint8List();
  bytes.setRange(values.length * 4, bytes.length, JustFloatParser.tail);
  return bytes;
}
