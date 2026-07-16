import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

void main() {
  testWidgets('设置分类仅滚动右侧连续内容到对应锚点', (tester) async {
    final controller = ScrollController();
    final firstKey = GlobalKey();
    final secondKey = GlobalKey();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsNavigationView(
            scrollController: controller,
            items: [
              SettingsNavigationItem(label: '第一类', anchorKey: firstKey),
              SettingsNavigationItem(label: '第二类', anchorKey: secondKey),
            ],
            child: Column(
              children: [
                SizedBox(key: firstKey, height: 420),
                SizedBox(key: secondKey, height: 420),
              ],
            ),
          ),
        ),
      ),
    );

    expect(controller.offset, 0);
    await tester.tap(find.text('第二类'));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(find.byKey(firstKey), findsOneWidget);
    expect(find.byKey(secondKey), findsOneWidget);
  });
}
