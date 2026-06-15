import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vscope_serial/data/models/parser_config.dart';
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
}
