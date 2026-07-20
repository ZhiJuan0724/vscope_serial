import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/core/localization/app_strings.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
import 'package:vscope_serial/services/app_settings.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/widgets/status_bar.dart';

void main() {
  testWidgets('随机源状态仅在 FireWater 协议下显示', (tester) async {
    final service = SerialService();
    final plotViewModel = PlotViewModel(service);
    plotViewModel.setParserType(ParserType.fireWater);
    plotViewModel.setUseRandomSource(true);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SerialService>.value(value: service),
          ChangeNotifierProvider<PlotViewModel>.value(value: plotViewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: StatusBar())),
      ),
    );
    await tester.pump();

    expect(find.text('随机源'), findsOneWidget);

    plotViewModel.setParserType(ParserType.justFloat);
    await tester.pump();
    await tester.pump();

    expect(find.text('随机源'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    plotViewModel.dispose();
  });

  testWidgets('应用信息和高级设置使用独立入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = SerialService();
    final plotViewModel = PlotViewModel(service);
    final previousAggregation = AppSettings().plotReceiveAggregationEnabled;
    AppSettings().plotReceiveAggregationEnabled = false;
    addTearDown(
      () => AppSettings().plotReceiveAggregationEnabled = previousAggregation,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SerialService>.value(value: service),
          ChangeNotifierProvider<PlotViewModel>.value(value: plotViewModel),
        ],
        child: const MaterialApp(home: Scaffold(body: StatusBar())),
      ),
    );

    expect(
      find.byKey(const ValueKey('app-advanced-settings-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('app-info-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-info-button')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.appInfo.title), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-build-time')), findsOneWidget);
    expect(
      find.text(AppStrings.appInfo.updateChannelAndSourceTitle),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('update-channel-and-source')),
      findsOneWidget,
    );
    final checkButton = find.byKey(const ValueKey('check-for-update-button'));
    final downloadButton = find.byKey(
      const ValueKey('download-and-install-button'),
    );
    expect(checkButton, findsOneWidget);
    expect(downloadButton, findsOneWidget);
    expect(
      find.ancestor(of: checkButton, matching: find.byType(Scrollable)),
      findsNothing,
    );
    expect(
      find.ancestor(of: downloadButton, matching: find.byType(Scrollable)),
      findsNothing,
    );
    expect(find.text(AppStrings.common.advancedSettings), findsNothing);

    await tester.tap(find.text(AppStrings.common.close));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('app-advanced-settings-button')),
    );
    await tester.pump();
    expect(find.text(AppStrings.common.advancedSettings), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-navigation-view')),
      findsOneWidget,
    );
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('页面'), findsOneWidget);
    expect(find.text(AppStrings.appInfo.receivePerformance), findsOneWidget);
    expect(find.text(AppStrings.appInfo.memoryLimits), findsOneWidget);
    expect(find.text('版本回退'), findsWidgets);
    expect(find.text('重置设置'), findsWidgets);
    expect(find.text(AppStrings.appInfo.disableNotifications), findsOneWidget);
    final aggregationToggle = find.ancestor(
      of: find.text(AppStrings.appInfo.plotReceiveAggregation),
      matching: find.byType(SwitchListTile),
    );
    expect(aggregationToggle, findsOneWidget);
    expect(AppSettings().plotReceiveAggregationEnabled, isFalse);
    await tester.tap(aggregationToggle);
    await tester.pump();
    expect(AppSettings().plotReceiveAggregationEnabled, isTrue);
    final plotMemoryField = find.byKey(
      const ValueKey('app-plot-history-memory-limit'),
    );
    expect(plotMemoryField, findsOneWidget);
    expect(tester.widget<TextField>(plotMemoryField), isA<TextField>());
    expect(
      find.text(AppStrings.appInfo.rawRetentionMemoryLimit),
      findsOneWidget,
    );
    expect(find.text(AppStrings.appInfo.shellQueueMemoryLimit), findsOneWidget);
    expect(
      find.text(AppStrings.appInfo.ymodemQueueMemoryLimit),
      findsOneWidget,
    );
    expect(find.textContaining('当前占用: 0 B / 512 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 128 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 256 MiB'), findsOneWidget);
    expect(find.textContaining('当前占用: 0 B / 4 MiB'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    plotViewModel.dispose();
  });
}
