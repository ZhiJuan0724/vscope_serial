import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/views/widgets/common_widgets.dart';

void main() {
  group('AppSettingsDialog', () {
    testWidgets('草稿没有修改时保存按钮禁用，修改后启用', (tester) async {
      var dirty = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => StatefulBuilder(
                              builder:
                                  (context, setState) => AppSettingsDialog(
                                    title: const Text('测试设置'),
                                    hasUnsavedChanges: () => dirty,
                                    onSave: () async {},
                                    child: TextButton(
                                      onPressed:
                                          () => setState(() => dirty = true),
                                      child: const Text('修改'),
                                    ),
                                  ),
                            ),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      var saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(saveButton.onPressed, isNull);

      await tester.tap(find.text('修改'));
      await tester.pump();
      saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(saveButton.onPressed, isNotNull);
    });

    testWidgets('文本输入时无需按 Enter 即可启用保存', (tester) async {
      final controller = TextEditingController(text: '60');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => AppSettingsDialog(
                              title: const Text('测试设置'),
                              changeListenables: [controller],
                              hasUnsavedChanges: () => controller.text != '60',
                              onSave: () async {},
                              child: TextField(controller: controller),
                            ),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      var saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(saveButton.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '120');
      await tester.pump();
      saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(saveButton.onPressed, isNotNull);
    });

    testWidgets('未保存修改时取消会显示保存、放弃和取消', (tester) async {
      var dirty = true;
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => AppSettingsDialog(
                              title: const Text('测试设置'),
                              hasUnsavedChanges: () => dirty,
                              onSave: () async {
                                saved = true;
                                dirty = false;
                              },
                              child: const Text('内容'),
                            ),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();

      expect(find.text('设置尚未保存'), findsOneWidget);
      expect(find.text('保存'), findsNWidgets(2));
      expect(find.text('放弃'), findsOneWidget);
      expect(saved, isFalse);

      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('测试设置'), findsOneWidget);
      expect(find.text('设置尚未保存'), findsNothing);

      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(find.text('测试设置'), findsNothing);
    });

    testWidgets('放弃修改不会调用保存', (tester) async {
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => AppSettingsDialog(
                              title: const Text('测试设置'),
                              hasUnsavedChanges: () => true,
                              onSave: () async => saved = true,
                              child: const Text('内容'),
                            ),
                      ),
                  child: const Text('打开'),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(saved, isFalse);
      expect(find.text('测试设置'), findsNothing);
    });
  });

  testWidgets('分段选择器按内容宽度布局且不铺满行', (tester) async {
    var value = 'normal';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder:
                (context, setState) => SizedBox(
                  width: 600,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: AppSegmentedSelector<String>(
                      key: const ValueKey('compact-segmented-selector'),
                      value: value,
                      items: const {
                        'sparse': Text('稀疏'),
                        'normal': Text('普通'),
                        'dense': Text('密集'),
                      },
                      onChanged: (next) => setState(() => value = next),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );

    final selectorSize = tester.getSize(
      find.byKey(const ValueKey('compact-segmented-selector')),
    );
    expect(selectorSize.width, lessThan(300));

    await tester.tap(find.text('密集'));
    await tester.pump();
    expect(value, 'dense');
  });

  testWidgets('开关行只有开关本体可切换', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder:
                (context, setState) => AppSwitchRow(
                  title: const Text('测试开关'),
                  subtitle: const Text('点击说明文字不应切换'),
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                ),
          ),
        ),
      ),
    );

    final titleContext = tester.element(find.text('测试开关'));
    final subtitleContext = tester.element(find.text('点击说明文字不应切换'));
    expect(DefaultTextStyle.of(titleContext).style.fontSize, 14);
    expect(DefaultTextStyle.of(subtitleContext).style.fontSize, 11);
    expect(DefaultTextStyle.of(subtitleContext).style.color, Colors.grey);

    await tester.tap(find.text('测试开关'));
    await tester.pump();
    expect(value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(value, isTrue);
  });

  testWidgets('窄工具栏使用无动画自绘更多菜单', (tester) async {
    var invoked = false;
    var secondaryInvoked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 70,
              child: UnifiedToolbar(
                leadingItems: [
                  ToolbarLayoutItem(
                    extent: 100,
                    child: const SizedBox(width: 100),
                    overflowActions: [
                      ToolbarOverflowAction(
                        icon: const Icon(Icons.tune),
                        label: '自绘操作',
                        onPressed: () => invoked = true,
                        onSecondaryPressed: () => secondaryInvoked = true,
                      ),
                    ],
                  ),
                ],
                trailingItems: const [],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(PopupMenuButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toolbar-more-button')));
    await tester.pump();
    expect(find.text('自绘操作'), findsOneWidget);

    await tester.tap(find.text('自绘操作'));
    await tester.pump();
    expect(invoked, isTrue);
    expect(find.text('自绘操作'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('toolbar-more-button')));
    await tester.pump();
    await tester.tap(find.text('自绘操作'), buttons: kSecondaryMouseButton);
    await tester.pump();
    expect(secondaryInvoked, isTrue);
    expect(find.text('自绘操作'), findsNothing);
  });

  testWidgets('弹窗输入和下拉的标题固定显示在控件外部', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const AppDialogTextField(labelText: '输入标题'),
              AppDialogDropdown<String>(
                value: 'a',
                labelText: '下拉标题',
                items: const [
                  DropdownMenuItem(value: 'a', child: Text('选项 A')),
                ],
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('输入标题'), findsOneWidget);
    expect(find.text('下拉标题'), findsOneWidget);
    final textFieldDecoration =
        tester.widget<TextField>(find.byType(TextField)).decoration!;
    expect(textFieldDecoration.labelText, isNull);
    final dropdown = tester.widget<NoAnimDropdown<String>>(
      find.byType(NoAnimDropdown<String>),
    );
    expect(dropdown.decoration?.labelText, isNull);
  });

  testWidgets('统一下拉支持键盘选择并在关闭后恢复焦点', (tester) async {
    var value = 'a';
    await tester.pumpWidget(
      StatefulBuilder(
        builder:
            (context, setState) => MaterialApp(
              home: Scaffold(
                body: AppDropdown<String>(
                  value: value,
                  hint: '选择',
                  items: const [
                    DropdownMenuItem(value: 'a', child: Text('选项 A')),
                    DropdownMenuItem(value: 'b', child: Text('选项 B')),
                    DropdownMenuItem(
                      value: 'c',
                      enabled: false,
                      child: Text('禁用项'),
                    ),
                  ],
                  onChanged: (next) => setState(() => value = next ?? value),
                ),
              ),
            ),
      ),
    );

    await tester.tap(find.text('选项 A'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value, 'b');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('禁用项'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('禁用项'), findsNothing);
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

  testWidgets('右侧内容滚动时左侧分类跟随选中', (tester) async {
    final controller = ScrollController();
    final firstKey = GlobalKey();
    final secondKey = GlobalKey();
    final thirdKey = GlobalKey();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsNavigationView(
            scrollController: controller,
            items: [
              SettingsNavigationItem(label: '第一类', anchorKey: firstKey),
              SettingsNavigationItem(label: '第二类', anchorKey: secondKey),
              SettingsNavigationItem(label: '第三类', anchorKey: thirdKey),
            ],
            child: Column(
              children: [
                SizedBox(key: firstKey, height: 300),
                SizedBox(key: secondKey, height: 300),
                SizedBox(key: thirdKey, height: 300),
              ],
            ),
          ),
        ),
      ),
    );

    controller.jumpTo(310);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('settings-navigation-selection-1')),
          )
          .properties
          .selected,
      isTrue,
    );

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('settings-navigation-selection-2')),
          )
          .properties
          .selected,
      isTrue,
    );
  });

  testWidgets('工具栏切换按钮可分别响应左键和右键', (tester) async {
    var primaryCount = 0;
    var secondaryCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolbarToggleIconButton(
            icon: const Icon(Icons.crop_free),
            tooltip: '框选',
            selected: false,
            onPressed: () => primaryCount++,
            onSecondaryPressed: () => secondaryCount++,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ToolbarToggleIconButton));
    final position = tester.getCenter(find.byType(ToolbarToggleIconButton));
    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.addPointer(location: position);
    await secondary.down(position);
    await secondary.up();
    await tester.pump();

    expect(primaryCount, 1);
    expect(secondaryCount, 1);
  });

  testWidgets('输入框尾部图标按钮统一使用紧凑点击反馈', (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFieldIconButton(
            tooltip: '清空',
            icon: const Icon(Icons.clear),
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.splashRadius, lessThanOrEqualTo(14));
    expect(
      tester.getSize(find.byType(AppFieldIconButton)),
      const Size.square(kFieldIconButtonExtent),
    );

    await tester.tap(find.byType(AppFieldIconButton));
    expect(pressed, isTrue);
  });
}
