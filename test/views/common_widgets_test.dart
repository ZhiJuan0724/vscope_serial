import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

class _IconColorProbe extends StatelessWidget {
  const _IconColorProbe({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: IconTheme.of(context).color ?? Colors.transparent,
      child: const SizedBox(width: 8, height: 8),
    );
  }
}

void main() {
  testWidgets('工具栏下拉框与开始按钮使用相同高度并按可见边框对齐', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedToolbar(
            leadingItems: [
              const ToolbarLayoutItem(
                extent: 76,
                child: ToolbarStartStopButton(
                  key: ValueKey('start-button'),
                  onPressed: _noop,
                  running: false,
                  label: '开始',
                ),
              ),
              ToolbarLayoutItem(
                extent: 120,
                child: ToolbarDropdown<String>(
                  key: const ValueKey('toolbar-dropdown'),
                  width: 120,
                  value: 'a',
                  hint: '选择',
                  items: const [
                    DropdownMenuItem(value: 'a', child: Text('选项')),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ],
            trailingItems: const [],
          ),
        ),
      ),
    );

    final start = find.byKey(const ValueKey('start-button'));
    final dropdown = find.byKey(const ValueKey('toolbar-dropdown'));
    final inputDecorator = find.descendant(
      of: dropdown,
      matching: find.byType(InputDecorator),
    );

    expect(tester.getSize(inputDecorator).height, 28);
    expect(tester.getCenter(inputDecorator).dy, tester.getCenter(start).dy + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏图标继承按钮前景色并支持选中状态覆盖', (tester) async {
    const normalColor = Color(0xff2468ac);
    const selectedColor = Color(0xffd08020);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          iconButtonTheme: const IconButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(normalColor),
            ),
          ),
          textButtonTheme: const TextButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(normalColor),
            ),
          ),
        ),
        home: const Scaffold(
          body: Column(
            children: [
              ToolbarIconButton(
                icon: _IconColorProbe(key: ValueKey('plain-icon-probe')),
                tooltip: '普通图标',
                onPressed: _noop,
              ),
              ToolbarToggleTextButton(
                icon: _IconColorProbe(key: ValueKey('normal-icon-probe')),
                label: '普通',
                tooltip: '普通状态',
                selected: false,
                onPressed: _noop,
              ),
              ToolbarToggleTextButton(
                icon: _IconColorProbe(key: ValueKey('selected-icon-probe')),
                label: '选中',
                tooltip: '选中状态',
                selected: true,
                activeColor: selectedColor,
                onPressed: _noop,
              ),
            ],
          ),
        ),
      ),
    );

    Color probeColor(String key) =>
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(ColoredBox),
              ),
            )
            .color;

    expect(probeColor('plain-icon-probe'), normalColor);
    expect(probeColor('normal-icon-probe'), normalColor);
    expect(probeColor('selected-icon-probe'), selectedColor);
  });

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

void _noop() {}
