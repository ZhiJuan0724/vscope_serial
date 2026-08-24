import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/viewmodels/plot_trigger_runtime.dart';

void main() {
  test('触发状态机累计命中并在限次后请求停止', () {
    final runtime = PlotTriggerRuntime<int>();

    final first = runtime.process(
      item: 1,
      value: 11,
      enabled: true,
      hitThreshold: 2,
      triggerLimit: 1,
      stopAtLimit: true,
      postStopItemCount: 0,
      matches: (value, _) => value > 10,
    );
    final second = runtime.process(
      item: 2,
      value: 12,
      enabled: true,
      hitThreshold: 2,
      triggerLimit: 1,
      stopAtLimit: true,
      postStopItemCount: 0,
      matches: (value, _) => value > 10,
    );

    expect(first.thresholdReached, isFalse);
    expect(second.hitItems, [1, 2]);
    expect(second.limitReached, isTrue);
    expect(second.stopRequested, isTrue);
    expect(runtime.triggeredCount, 1);
  });

  test('延迟停止不把触发点计入后续包数', () {
    final runtime = PlotTriggerRuntime<int>();
    final hit = runtime.process(
      item: 1,
      value: 1,
      enabled: true,
      hitThreshold: 1,
      triggerLimit: 1,
      stopAtLimit: true,
      postStopItemCount: 2,
      matches: (_, _) => true,
    );

    expect(hit.stopRequested, isFalse);
    expect(runtime.stopItemsRemaining, 2);
    expect(
      runtime
          .process(
            item: 2,
            value: 0,
            enabled: false,
            hitThreshold: 1,
            triggerLimit: 1,
            stopAtLimit: true,
            postStopItemCount: 2,
            matches: (_, _) => false,
          )
          .stopRequested,
      isFalse,
    );
    expect(
      runtime
          .process(
            item: 3,
            value: 0,
            enabled: false,
            hitThreshold: 1,
            triggerLimit: 1,
            stopAtLimit: true,
            postStopItemCount: 2,
            matches: (_, _) => false,
          )
          .stopRequested,
      isTrue,
    );
  });
}
