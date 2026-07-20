import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/plot_data.dart';
import 'package:vscope_serial/viewmodels/plot_window_provider.dart';

void main() {
  group('PlotWindowProvider', () {
    late PlotWindowProvider provider;
    var disposed = false;
    var stateChanges = 0;
    var commits = 0;

    setUp(() {
      disposed = false;
      stateChanges = 0;
      commits = 0;
      provider = PlotWindowProvider(
        isDisposed: () => disposed,
        onStateChanged: () => stateChanges++,
        onCommitted: () => commits++,
      );
    });

    tearDown(() {
      disposed = true;
      provider.dispose();
    });

    test('materializes a bounded window centered on the requested range', () {
      provider.loadViewport(
        xMin: 450,
        xMax: 550,
        total: 1000,
        materializedPointLimit: 200,
        allocatedBytes: 0,
        retentionLimitBytes: 1024 * 1024,
        valuesAt: (index) => [index.toDouble()],
      );

      expect(provider.visibleStartIndex, 400);
      expect(provider.visibleEndIndex, 600);
      expect(provider.points, hasLength(200));
      expect(provider.points.first.values, [400]);
      expect(provider.points.last.values, [599]);
      expect(commits, 1);
    });

    test('keeps the current exact window when a rebuild exceeds budget', () {
      provider.replaceSynchronously(0, <PlotDataPoint>[
        PlotDataPoint(index: 0, timestamp: 0, values: [1]),
      ]);

      provider.rebuild(
        start: 100,
        count: 5000,
        allocatedBytes: 1024,
        retentionLimitBytes: 1024,
        valuesAt: (index) => [index.toDouble()],
      );

      expect(provider.visibleStartIndex, 0);
      expect(provider.points.single.values, [1]);
      expect(provider.isLoading, isFalse);
    });

    test('a newer asynchronous rebuild cancels the older generation', () async {
      provider.rebuild(
        start: 0,
        count: 5000,
        allocatedBytes: 0,
        retentionLimitBytes: 4 * 1024 * 1024,
        valuesAt: (index) => [index.toDouble()],
      );
      provider.rebuild(
        start: 10000,
        count: 5000,
        allocatedBytes: 0,
        retentionLimitBytes: 4 * 1024 * 1024,
        valuesAt: (index) => [index.toDouble()],
      );

      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(provider.visibleStartIndex, 10000);
      expect(provider.points, hasLength(5000));
      expect(provider.points.first.values, [10000]);
      expect(provider.points.last.values, [14999]);
      expect(commits, 1);
      expect(stateChanges, greaterThanOrEqualTo(3));
    });
  });
}
