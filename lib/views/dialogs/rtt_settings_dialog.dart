import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/constants/terminal_fonts.dart';
import '../../core/constants/rtt_configuration.dart';
import '../../core/localization/app_strings.dart';
import '../../services/app_settings.dart';
import '../../services/shell_stream_decoder.dart';
import '../../viewmodels/rtt_viewmodel.dart';
import '../../viewmodels/settings_drafts.dart';
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
  late String _encoding;
  late String _fontFamily;
  String? _fontSizeError;
  String? _historyError;

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
    _encoding = settings.rttEncoding;
    _fontFamily = settings.rttFontFamily;
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
    return AppSettingsDialog(
      title: Text(AppStrings.rtt.settings),
      size: AppDialogSize.navigation,
      changeListenables: [_historyController, _fontSizeController],
      hasUnsavedChanges: () {
        final settings = AppSettings();
        return _encoding != settings.rttEncoding ||
            _fontFamily != settings.rttFontFamily ||
            _fontSizeController.text !=
                settings.rttFontSize.round().toString() ||
            _historyController.text != '${settings.rttHistoryLineLimit}';
      },
      onSave: () async {
        final fontSize = double.tryParse(_fontSizeController.text);
        final history = int.tryParse(_historyController.text);
        setState(() {
          _fontSizeError =
              fontSize == null || fontSize < 10 || fontSize > 24
                  ? AppStrings.raw.terminalFontSizeInvalid
                  : null;
          _historyError =
              history == null ||
                      history < RttConfiguration.minHistoryLines ||
                      history > RttConfiguration.maxHistoryLines
                  ? AppStrings.probe.historyLineRange(
                    min: RttConfiguration.minHistoryLines,
                    max: RttConfiguration.maxHistoryLines,
                  )
                  : null;
        });
        if (_fontSizeError != null || _historyError != null) {
          throw FormatException(AppStrings.probe.invalidSettingsError);
        }
        await context.read<RttViewModel>().applyTerminalSettings(
          RttTerminalSettingsDraft(
            encoding: _encoding,
            fontFamily: _fontFamily,
            fontSize: fontSize!,
            historyLineLimit: history!,
          ),
        );
      },
      child: SettingsNavigationView(
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
              AppStrings.common.settingsTextEncoding,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: _encoding,
                  hint: AppStrings.probe.selectTextEncodingHint,
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
                    if (value != null) setState(() => _encoding = value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.common.settingsTerminalFont,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kSecondaryDialogWideFieldWidth,
                child: NoAnimDropdown<String>(
                  value: _fontFamily,
                  hint: AppStrings.probe.selectTerminalFontHint,
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
                    if (value != null) setState(() => _fontFamily = value);
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  AppStrings.probe.fontSizeLabel,
                  style: const TextStyle(fontSize: 14),
                ),
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
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.probe.fontPreviewLabel,
              style: const TextStyle(fontSize: 14),
            ),
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
                AppStrings.probe.fontPreviewText,
                style: TextStyle(
                  fontFamily: _fontFamily,
                  fontSize:
                      double.tryParse(_fontSizeController.text) ?? vm.fontSize,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 12),
            AppDialogTextField(
              controller: _historyController,
              keyboardType: TextInputType.number,
              labelText: AppStrings.probe.historyLinesLabel,
              errorText: _historyError,
              helperText: AppStrings.probe.historyLinesHelp(
                min: RttConfiguration.minHistoryLines,
                max: RttConfiguration.maxHistoryLines,
                currentMiB: (vm.rawHistoryBytes / 1024 / 1024).toStringAsFixed(
                  1,
                ),
              ),
              onChanged: (_) {
                if (_historyError != null) setState(() => _historyError = null);
              },
            ),
          ],
        ),
      ),
    );
  }
}
