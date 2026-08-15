import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double _controlHeight = 40;

InputDecoration appDialogInputDecoration({
  String? hintText,
  String? helperText,
  String? errorText,
  String? suffixText,
  String? prefixText,
  Widget? suffixIcon,
}) => InputDecoration(
  hintText: hintText,
  helperText: helperText,
  errorText: errorText,
  suffixText: suffixText,
  prefixText: prefixText,
  suffixIcon: suffixIcon,
  isDense: true,
  constraints: const BoxConstraints(minHeight: _controlHeight),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  border: const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(4)),
  ),
);

class AppDialogTextField extends StatelessWidget {
  const AppDialogTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.labelText,
    this.hintText,
    this.helperText,
    this.errorText,
    this.suffixText,
    this.prefixText,
    this.suffixIcon,
    this.enabled = true,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.minLines = 1,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final String? suffixText;
  final String? prefixText;
  final Widget? suffixIcon;
  final bool enabled;
  final bool autofocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final int? minLines;
  final int? maxLines;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) => SizedBox(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (labelText != null) ...[
          Text(labelText!, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
        ],
        SizedBox(
          height:
              errorText == null &&
                      helperText == null &&
                      minLines == 1 &&
                      maxLines == 1
                  ? _controlHeight
                  : null,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            autofocus: autofocus,
            obscureText: obscureText,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            onEditingComplete: onEditingComplete,
            minLines: minLines,
            maxLines: obscureText ? 1 : maxLines,
            textCapitalization: textCapitalization,
            decoration: appDialogInputDecoration(
              hintText: hintText,
              helperText: helperText,
              errorText: errorText,
              suffixText: suffixText,
              prefixText: prefixText,
              suffixIcon: suffixIcon,
            ),
          ),
        ),
      ],
    ),
  );
}

class AppNumberField extends AppDialogTextField {
  AppNumberField({
    super.key,
    super.controller,
    super.focusNode,
    super.labelText,
    super.hintText,
    super.helperText,
    super.errorText,
    super.suffixText,
    super.enabled,
    super.autofocus,
    super.onChanged,
    super.onSubmitted,
    super.onEditingComplete,
    bool allowDecimal = false,
    bool allowNegative = false,
  }) : super(
         keyboardType: TextInputType.numberWithOptions(
           decimal: allowDecimal,
           signed: allowNegative,
         ),
         inputFormatters: [
           FilteringTextInputFormatter.allow(
             RegExp(
               allowDecimal
                   ? (allowNegative ? r'^-?\d*\.?\d*$' : r'^\d*\.?\d*$')
                   : (allowNegative ? r'^-?\d*$' : r'^\d*$'),
             ),
           ),
         ],
       );
}

/// 设置弹窗中「标题在左、固定宽度数值输入框在右」的单行字段。
///
/// 与 [AppSwitchRow] / [AppCheckboxRow] 保持一致的排版，内部使用
/// [AppNumberField] 统一提供数字键盘与输入过滤，并把失焦/回车统一绑定到同一个
/// [onApply] 回调上，避免逐字段复制 `onSubmitted` + `onEditingComplete`。
class AppNumberRow extends StatelessWidget {
  const AppNumberRow({
    super.key,
    required this.label,
    required this.controller,
    this.suffixText,
    this.allowDecimal = false,
    this.allowNegative = false,
    this.enabled = true,
    this.fieldWidth = 140,
    this.onApply,
  });

  final String label;
  final TextEditingController controller;
  final String? suffixText;
  final bool allowDecimal;
  final bool allowNegative;
  final bool enabled;
  final double fieldWidth;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: const TextStyle(fontSize: 14)),
      const Spacer(),
      SizedBox(
        width: fieldWidth,
        child: AppNumberField(
          controller: controller,
          enabled: enabled,
          suffixText: suffixText,
          allowDecimal: allowDecimal,
          allowNegative: allowNegative,
          onSubmitted: onApply == null ? null : (_) => onApply!(),
          onEditingComplete: onApply,
        ),
      ),
    ],
  );
}

/// 弹窗表单的统一“标题 + 控件”布局。
///
/// 标题始终位于输入框或下拉框之外，避免聚焦时浮动到边框上。
class AppLabeledField extends StatelessWidget {
  const AppLabeledField({
    super.key,
    required this.label,
    required this.child,
    this.helpText,
  });

  final String label;
  final Widget child;
  final String? helpText;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 4),
      child,
      if (helpText != null) ...[
        const SizedBox(height: 4),
        Text(
          helpText!,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ],
  );
}

class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                child: title,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: Colors.grey,
                  ),
                  child: subtitle!,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 文本只负责说明，不能切换设置；避免用户滚动或选择文字时误触。
        Switch.adaptive(value: value, onChanged: onChanged),
      ],
    ),
  );
}

class AppCheckboxRow extends StatelessWidget {
  const AppCheckboxRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    title: title,
    subtitle: subtitle,
    value: value,
    onChanged: onChanged,
  );
}
