import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/constants/terminal_fonts.dart';
import '../../core/localization/app_strings.dart';
import '../../services/app_settings.dart';
import '../../services/shell_stream_decoder.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../widgets/common_widgets.dart';

Future<void> showRttSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _RttSettingsDialog(),
  );
}

class _RttSettingsDialog extends StatefulWidget {
  const _RttSettingsDialog();

  @override
  State<_RttSettingsDialog> createState() => _RttSettingsDialogState();
}

class _RttSettingsDialogState extends State<_RttSettingsDialog> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _displayKey = GlobalKey();
  late final TextEditingController _historyController;
  late final TextEditingController _fontSizeController;
  String? _fontSizeError;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _historyController = TextEditingController(
      text: '${settings.rttHistoryLineLimit}',
    );
    _fontSizeController = TextEditingController(
      text: settings.rttFontSize.round().toString(),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _historyController.dispose();
    _fontSizeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RttViewModel>();
    return AlertDialog(
      shape: kAdvancedSettingsDialogShape,
      title: Text(AppStrings.rtt.settings),
      content: SettingsNavigationView(
        scrollController: _scrollController,
        items: [
          SettingsNavigationItem(
            label: AppStrings.common.settingsDisplay,
            anchorKey: _displayKey,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              key: _displayKey,
              '文本编码',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: vm.encoding,
                  hint: '选择文本编码',
                  decoration: secondaryDialogFieldDecoration(),
                  items:
                      shellTextEncodings
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) vm.setEncoding(value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('终端字体', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: vm.fontFamily,
                  hint: '选择终端字体',
                  decoration: secondaryDialogFieldDecoration(),
                  items:
                      terminalFontFamilies
                          .map(
                            (font) => DropdownMenuItem(
                              value: font,
                              child: Text(font),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) vm.setFontFamily(value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('字号', style: TextStyle(fontSize: 14)),
                const Spacer(),
                SizedBox(
                  width: kSecondaryDialogFieldWidth,
                  child: TextField(
                    key: const ValueKey('rtt-font-size-field'),
                    controller: _fontSizeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: secondaryDialogFieldDecoration(
                      suffixText: 'px',
                    ).copyWith(errorText: _fontSizeError),
                    onChanged: (text) {
                      final value = double.tryParse(text);
                      if (value == null || value < 10 || value > 24) {
                        setState(() {
                          _fontSizeError =
                              AppStrings.raw.terminalFontSizeInvalid;
                        });
                        return;
                      }
                      setState(() => _fontSizeError = null);
                      vm.setFontSize(value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('字体示例', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Container(
              key: const ValueKey('rtt-font-preview'),
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'SerialTools RTT  中文终端\nAa Bb 0123456789  > _',
                style: TextStyle(
                  fontFamily: vm.fontFamily,
                  fontSize: vm.fontSize,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _historyController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '历史行数',
                helperText:
                    '范围 1000~1000000 行，当前原始历史 '
                    '${(vm.rawHistoryBytes / 1024 / 1024).toStringAsFixed(1)} MiB',
                suffixIcon: IconButton(
                  tooltip: '应用',
                  onPressed: () {
                    final value = int.tryParse(_historyController.text);
                    if (value != null) vm.setHistoryLineLimit(value);
                    _historyController.text = '${vm.historyLineLimit}';
                  },
                  icon: const Icon(Icons.check),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
