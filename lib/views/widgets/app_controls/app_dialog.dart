import 'package:flutter/material.dart';

import '../../../core/localization/app_strings.dart';

/// 弹窗路由完成关闭动画后再释放由调用方创建的控制器。
///
/// `showDialog` 返回的 Future 会在路由开始退出时完成，此时退出动画中的控件
/// 仍可能重建。立即 dispose 会触发“controller used after disposed”。
void disposeAfterDialogTransition(VoidCallback dispose) {
  Future<void>.delayed(kThemeAnimationDuration, dispose);
}

/// 应用弹窗只使用这些经过验证的宽度，避免各页面继续散落魔法数字。
enum AppDialogSize {
  compact(280),
  small(360),
  medium(420),
  large(520),
  extraLarge(680),
  navigation(660);

  const AppDialogSize(this.width);

  final double width;
}

/// 统一的设置弹窗骨架。
///
/// 内容只编辑调用方持有的草稿；[onSave] 成功返回后弹窗才会关闭。
class AppSettingsDialog extends StatefulWidget {
  const AppSettingsDialog({
    super.key,
    required this.title,
    required this.child,
    required this.onSave,
    this.size = AppDialogSize.medium,
    this.errorText,
    this.saveText,
    this.cancelText,
    this.hasUnsavedChanges,
  });

  final Widget title;
  final Widget child;
  final Future<void> Function() onSave;
  final AppDialogSize size;
  final String? errorText;
  final String? saveText;
  final String? cancelText;
  final bool Function()? hasUnsavedChanges;

  @override
  State<AppSettingsDialog> createState() => _AppSettingsDialogState();
}

class _AppSettingsDialogState extends State<AppSettingsDialog> {
  bool _saving = false;
  String? _saveError;

  Future<void> _save() async {
    if (_saving || !(widget.hasUnsavedChanges?.call() ?? true)) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onSave();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saveError = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!(widget.hasUnsavedChanges?.call() ?? false)) {
      Navigator.of(context).pop();
      return;
    }
    final choice = await showDialog<_UnsavedChoice>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(AppStrings.common.settingsNotSaved),
            content: Text(AppStrings.common.unsavedChangesMessage),
            actions: [
              TextButton(
                onPressed:
                    () => Navigator.pop(dialogContext, _UnsavedChoice.cancel),
                child: Text(AppStrings.common.cancel),
              ),
              TextButton(
                onPressed:
                    () => Navigator.pop(dialogContext, _UnsavedChoice.discard),
                child: Text(AppStrings.common.discard),
              ),
              AppDialogPrimaryButton(
                onPressed:
                    () => Navigator.pop(dialogContext, _UnsavedChoice.save),
                child: Text(AppStrings.common.save),
              ),
            ],
          ),
    );
    if (!mounted) return;
    switch (choice) {
      case _UnsavedChoice.save:
        await _save();
      case _UnsavedChoice.discard:
        if (mounted) Navigator.of(context).pop();
      case _UnsavedChoice.cancel:
      case null:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _saveError ?? widget.errorText;
    final hasUnsavedChanges = widget.hasUnsavedChanges?.call() ?? true;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: AlertDialog(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        title: widget.title,
        content: SizedBox(
          width: widget.size.width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(child: widget.child),
              if (error != null && error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  key: const ValueKey('app-settings-dialog-error'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _requestClose,
            child: Text(widget.cancelText ?? AppStrings.common.cancel),
          ),
          AppDialogPrimaryButton(
            onPressed: _saving || !hasUnsavedChanges ? null : _save,
            child:
                _saving
                    ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : Text(widget.saveText ?? AppStrings.common.save),
          ),
        ],
      ),
    );
  }
}

enum _UnsavedChoice { save, discard, cancel }

/// 弹窗唯一主操作按钮。只保留轻量层次，不产生大范围阴影。
class AppDialogPrimaryButton extends StatelessWidget {
  const AppDialogPrimaryButton({
    super.key,
    required this.onPressed,
    required this.child,
  });

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      elevation: 1,
      shadowColor: Colors.black26,
      minimumSize: const Size(88, 36),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
    ),
    child: child,
  );
}
