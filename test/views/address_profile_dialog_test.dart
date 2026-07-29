import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/address_config_profile.dart';
import 'package:vscope_serial/services/serial_service.dart';
import 'package:vscope_serial/viewmodels/plot_viewmodel.dart';
import 'package:vscope_serial/views/dialogs/address_profile_dialog.dart';

void main() {
  final serialService = SerialService();
  late PlotViewModel viewModel;

  setUp(() {
    viewModel = PlotViewModel(serialService);
  });

  tearDown(() {
    viewModel.dispose();
  });

  testWidgets('多项搜索结果点击后跳到原列表的正确行', (tester) async {
    final profile = AddressConfigProfile(
      id: 'search',
      name: '搜索测试',
      presets: [
        for (var index = 0; index < 30; index++)
          AddressChannelPreset(
            name:
                index == 4 || index == 20 || index == 27
                    ? '匹配 $index'
                    : '普通 $index',
            address: index,
          ),
      ],
    );
    await _pumpDialog(
      tester,
      ZobowProfileDialog(vm: viewModel, profile: profile),
    );

    await tester.enterText(
      find.byKey(const ValueKey('address-profile-search')),
      '匹配',
    );
    await tester.pump();
    expect(find.text('匹配 4'), findsOneWidget);
    expect(find.text('匹配 20'), findsOneWidget);
    expect(find.text('匹配 27'), findsOneWidget);

    await tester.tap(find.text('匹配 20'));
    await tester.pumpAndSettle();

    final search = tester.widget<TextField>(
      find.byKey(const ValueKey('address-profile-search')),
    );
    expect(search.controller!.text, isEmpty);
    expect(
      find.byKey(const ValueKey('address-profile-row-name-20')),
      findsOneWidget,
    );
  });

  testWidgets('名称删空后仍保持名称输入焦点', (tester) async {
    final profile = _profile(
      AddressProfileProtocolType.zobow,
      AddressValueFormat.hexadecimal,
    );
    await _pumpDialog(
      tester,
      ZobowProfileDialog(vm: viewModel, profile: profile),
    );
    final nameField = find.byKey(const ValueKey('address-profile-row-name-0'));

    await tester.tap(nameField);
    await tester.enterText(nameField, '');
    await tester.pump();

    final editable = tester.state<EditableTextState>(
      find.descendant(of: nameField, matching: find.byType(EditableText)),
    );
    expect(editable.widget.focusNode.hasFocus, isTrue);

    await tester.enterText(nameField, '新名称');
    await tester.pump();
    expect(tester.widget<TextField>(nameField).controller!.text, '新名称');
  });

  testWidgets('Zobow 地址失焦补全为八位十六进制', (tester) async {
    final profile = _profile(
      AddressProfileProtocolType.zobow,
      AddressValueFormat.hexadecimal,
    );
    await _pumpDialog(
      tester,
      ZobowProfileDialog(vm: viewModel, profile: profile),
    );
    final address = find.byKey(const ValueKey('address-profile-row-address-0'));

    await tester.tap(address);
    await tester.enterText(address, '10');
    await tester.tap(find.byKey(const ValueKey('address-profile-search')));
    await tester.pump();

    expect(tester.widget<TextField>(address).controller!.text, '0x00000010');
  });

  testWidgets('r 协议地址失焦后保留十进制或十六进制原文', (tester) async {
    final profile = _profile(
      AddressProfileProtocolType.rProtocol,
      AddressValueFormat.decimal,
    );
    await _pumpDialog(
      tester,
      RProtocolProfileDialog(vm: viewModel, profile: profile),
    );
    final address = find.byKey(const ValueKey('address-profile-row-address-0'));
    final search = find.byKey(const ValueKey('address-profile-search'));

    await tester.tap(address);
    await tester.enterText(address, '10');
    await tester.tap(search);
    await tester.pump();
    expect(tester.widget<TextField>(address).controller!.text, '10');

    await tester.tap(address);
    await tester.enterText(address, '0x10');
    await tester.tap(search);
    await tester.pump();
    expect(tester.widget<TextField>(address).controller!.text, '0x10');
  });
}

AddressConfigProfile _profile(
  AddressProfileProtocolType protocol,
  AddressValueFormat format,
) {
  return AddressConfigProfile(
    id: 'profile',
    name: '测试配置',
    protocolType: protocol,
    presets: [
      AddressChannelPreset(name: '通道', address: 1, addressFormat: format),
    ],
  );
}

Future<void> _pumpDialog(WidgetTester tester, Widget dialog) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: dialog)));
  await tester.pumpAndSettle();
}
