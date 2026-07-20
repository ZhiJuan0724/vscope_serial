import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/viewmodels/plot_history_store.dart';

void main() {
  group('PlotHistoryStore', () {
    test('owns parsed history and LOD as one consistent resource', () {
      final store = PlotHistoryStore();

      for (var index = 0; index < 128; index++) {
        store.appendImportedParsedPoint(index, [
          index.toDouble(),
          index * 10.0,
        ]);
      }

      expect(store.pointCount(ParserType.fireWater), 128);
      expect(
        store.valuesAt(
          1,
          ParserType.fireWater,
          ParserConfig.fireWaterDefault(),
        ),
        [1, 10],
      );
      expect(
        store.valueAt(
          0,
          1,
          ParserType.fireWater,
          ParserConfig.fireWaterDefault(),
        ),
        0,
      );
      expect(store.isCompatible(ParserType.fireWater, 128), isTrue);
      expect(store.isCompatible(ParserType.zobow, 128), isFalse);

      final lod = store.queryLod(
        channelIndex: 0,
        xMin: 0,
        xMax: 127,
        plotWidth: 1,
      );
      expect(lod, isNotNull);
      expect(lod!.values, containsAll(<double>[0, 127]));
    });

    test('clear releases every history representation', () {
      final store = PlotHistoryStore();
      store.appendImportedParsedPoint(0, [1]);

      store.clear();

      expect(store.parsedLength, 0);
      expect(store.zobowFrameCount, 0);
      expect(store.fixedFrameCount, 0);
      expect(store.estimatedAllocatedBytes, 0);
      expect(store.lodSource.isEmpty, isTrue);
    });
  });
}
