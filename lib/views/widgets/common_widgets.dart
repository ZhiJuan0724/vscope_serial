import 'package:flutter/material.dart';

/// 二级弹窗内单行输入框和下拉框的默认宽度。
const double kSecondaryDialogFieldWidth = 140;

/// 二级弹窗内较长选项输入框和下拉框的默认宽度。
const double kSecondaryDialogWideFieldWidth = 220;

/// 三个业务页面高级设置弹窗的统一内容宽度。
const double kAdvancedSettingsDialogWidth = 420;

/// 高级设置弹窗统一使用较小圆角，与绘图高级设置保持一致。
const RoundedRectangleBorder kAdvancedSettingsDialogShape =
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)));

/// 高级设置滚动内容为右侧滚动条预留的统一间距。
const EdgeInsets kAdvancedSettingsDialogScrollPadding = EdgeInsets.only(
  right: 12,
);

/// 左侧分类导航 + 右侧连续内容设置弹窗的默认内容宽度。
const double kSettingsNavigationDialogWidth = 660;

/// 设置分类导航栏宽度，保持紧凑并为右侧表单保留主要空间。
const double kSettingsNavigationWidth = 136;

/// 绘图工具栏原有开始/停止按钮的最小高度，其他页面以此为视觉基准。
const double kToolbarStartStopButtonMinHeight = 28;

/// 页面工具栏统一高度。
const double kToolbarHeight = 40;

/// 工具栏图标按钮统一尺寸和点击区域。
const double kToolbarControlExtent = 32;
const double kToolbarIconSize = 18;

/// 同组工具和左右工具组之间的统一间距。
const double kToolbarItemSpacing = 4;
const double kToolbarGroupSpacing = 12;

/// 纯图标开始/停止按钮的最小宽度，与绘图按钮的最小高度一致。
const double kToolbarStartStopIconButtonMinWidth = 28;

/// 页面底部业务状态栏的统一高度。
const double kPageStatusBarHeight = 24;

/// 页面底部业务状态栏的统一水平留白。
const EdgeInsets kPageStatusBarPadding = EdgeInsets.symmetric(horizontal: 8);

/// 页面底部业务状态栏的统一文字样式。
const TextStyle kPageStatusBarTextStyle = TextStyle(
  fontSize: 11,
  color: Colors.grey,
);

/// 设置导航项只保存显示名称和右侧内容锚点，不代表互斥页面。
class SettingsNavigationItem {
  const SettingsNavigationItem({required this.label, required this.anchorKey});

  final String label;
  final GlobalKey anchorKey;
}

/// 左侧分类导航、右侧连续滚动内容的统一设置布局。
///
/// 点击分类仅滚动到对应锚点；右侧所有内容始终存在，不按分类切换或
/// 人为增加大段分隔空间，避免编辑中的控件状态被重建。
class SettingsNavigationView extends StatefulWidget {
  const SettingsNavigationView({
    super.key,
    required this.scrollController,
    required this.items,
    required this.child,
    this.width = kSettingsNavigationDialogWidth,
  });

  final ScrollController scrollController;
  final List<SettingsNavigationItem> items;
  final Widget child;
  final double width;

  @override
  State<SettingsNavigationView> createState() => _SettingsNavigationViewState();
}

class _SettingsNavigationViewState extends State<SettingsNavigationView> {
  int _selectedIndex = 0;
  final GlobalKey _contentViewportKey = GlobalKey();
  bool _selectionSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_scheduleSelectionSync);
  }

  @override
  void didUpdateWidget(covariant SettingsNavigationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController == widget.scrollController) return;
    oldWidget.scrollController.removeListener(_scheduleSelectionSync);
    widget.scrollController.addListener(_scheduleSelectionSync);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_scheduleSelectionSync);
    super.dispose();
  }

  void _scheduleSelectionSync() {
    if (_selectionSyncScheduled) return;
    _selectionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionSyncScheduled = false;
      if (!mounted) return;
      _syncSelectionToScrollPosition();
    });
  }

  void _syncSelectionToScrollPosition() {
    if (!widget.scrollController.hasClients || widget.items.isEmpty) return;

    final position = widget.scrollController.position;
    var nextIndex = 0;
    if (position.extentAfter <= 0.5) {
      // 最后一类通常没有足够的下方空间移到视口顶部，
      // 因此滚动到底时直接选中最后一类。
      nextIndex = widget.items.length - 1;
    } else {
      final viewportBox =
          _contentViewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewportBox == null || !viewportBox.hasSize) return;
      final activationY = viewportBox.localToGlobal(Offset.zero).dy + 12;

      for (var index = 0; index < widget.items.length; index++) {
        final anchorBox =
            widget.items[index].anchorKey.currentContext?.findRenderObject()
                as RenderBox?;
        if (anchorBox == null || !anchorBox.hasSize) continue;
        if (anchorBox.localToGlobal(Offset.zero).dy <= activationY) {
          nextIndex = index;
        } else {
          break;
        }
      }
    }

    if (nextIndex != _selectedIndex) {
      setState(() => _selectedIndex = nextIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height =
        (MediaQuery.sizeOf(context).height * 0.72)
            .clamp(360.0, 560.0)
            .toDouble();
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      key: const ValueKey('settings-navigation-view'),
      width: widget.width,
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: kSettingsNavigationWidth,
            child: ListView.builder(
              padding: const EdgeInsets.only(right: 8),
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final item = widget.items[index];
                final selected = index == _selectedIndex;
                return TextButton(
                  key: ValueKey('settings-navigation-item-$index'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor:
                        selected ? colorScheme.primary : colorScheme.onSurface,
                    backgroundColor:
                        selected
                            ? colorScheme.primaryContainer.withValues(
                              alpha: 0.5,
                            )
                            : Colors.transparent,
                    minimumSize: const Size.fromHeight(34),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: () {
                    setState(() => _selectedIndex = index);
                    final anchorContext = item.anchorKey.currentContext;
                    if (anchorContext == null) return;
                    Scrollable.ensureVisible(
                      anchorContext,
                      alignment: 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                    );
                  },
                  child: Semantics(
                    key: ValueKey('settings-navigation-selection-$index'),
                    selected: selected,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            ),
          ),
          VerticalDivider(width: 1, color: colorScheme.outlineVariant),
          const SizedBox(width: 16),
          Expanded(
            child: SizedBox.expand(
              key: _contentViewportKey,
              child: Scrollbar(
                controller: widget.scrollController,
                child: SingleChildScrollView(
                  key: const ValueKey('settings-navigation-content'),
                  controller: widget.scrollController,
                  padding: kAdvancedSettingsDialogScrollPadding,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具栏项目折叠到“更多”菜单后对应的一项操作。
class ToolbarOverflowAction {
  const ToolbarOverflowAction({
    this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final Key? key;
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
}

/// 工具栏内可参与响应式折叠的布局项目。
///
/// [extent] 只用于决定何时折叠，不会强制修改子控件宽度；项目没有
/// [overflowActions] 时始终保留在工具栏中。
class ToolbarLayoutItem {
  const ToolbarLayoutItem({
    required this.child,
    required this.extent,
    this.overflowActions = const [],
  });

  final Widget child;
  final double extent;
  final List<ToolbarOverflowAction> overflowActions;
}

/// 页面共用工具栏，统一背景、边框、高度以及左右对齐方式。
///
/// 宽度不足时先从右侧最末项目开始折叠，再折叠左侧最末项目，所有被
/// 折叠的操作进入右侧“更多”菜单，避免水平滚动或 RenderFlex 溢出。
class UnifiedToolbar extends StatelessWidget {
  const UnifiedToolbar({
    super.key,
    required this.leadingItems,
    required this.trailingItems,
    this.height = kToolbarHeight,
  });

  final List<ToolbarLayoutItem> leadingItems;
  final List<ToolbarLayoutItem> trailingItems;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final leadingVisible = List<bool>.filled(leadingItems.length, true);
          final trailingVisible = List<bool>.filled(trailingItems.length, true);

          bool hasHiddenItems() =>
              leadingVisible.contains(false) || trailingVisible.contains(false);

          double usedWidth() {
            final visible = <ToolbarLayoutItem>[
              for (var i = 0; i < leadingItems.length; i++)
                if (leadingVisible[i]) leadingItems[i],
              for (var i = 0; i < trailingItems.length; i++)
                if (trailingVisible[i]) trailingItems[i],
            ];
            var width = visible.fold<double>(
              0,
              (sum, item) => sum + item.extent,
            );
            if (visible.length > 1) {
              width += (visible.length - 1) * kToolbarItemSpacing;
            }
            final hasLeading = leadingVisible.contains(true);
            final hasTrailing = trailingVisible.contains(true);
            if (hasLeading && (hasTrailing || hasHiddenItems())) {
              width += kToolbarGroupSpacing - kToolbarItemSpacing;
            }
            if (hasHiddenItems()) {
              width += kToolbarControlExtent + kToolbarItemSpacing;
            }
            return width;
          }

          bool hideLastOverflowable(
            List<ToolbarLayoutItem> items,
            List<bool> visible,
          ) {
            for (var index = items.length - 1; index >= 0; index--) {
              if (visible[index] && items[index].overflowActions.isNotEmpty) {
                visible[index] = false;
                return true;
              }
            }
            return false;
          }

          while (usedWidth() > constraints.maxWidth) {
            if (hideLastOverflowable(trailingItems, trailingVisible)) continue;
            if (hideLastOverflowable(leadingItems, leadingVisible)) continue;
            break;
          }

          final hiddenActions = <ToolbarOverflowAction>[
            for (var i = 0; i < leadingItems.length; i++)
              if (!leadingVisible[i]) ...leadingItems[i].overflowActions,
            for (var i = 0; i < trailingItems.length; i++)
              if (!trailingVisible[i]) ...trailingItems[i].overflowActions,
          ];
          final leading = <Widget>[
            for (var i = 0; i < leadingItems.length; i++)
              if (leadingVisible[i]) leadingItems[i].child,
          ];
          final trailing = <Widget>[
            for (var i = 0; i < trailingItems.length; i++)
              if (trailingVisible[i]) trailingItems[i].child,
            if (hiddenActions.isNotEmpty)
              _ToolbarMoreButton(actions: hiddenActions),
          ];

          return Row(
            children: [
              ..._spacedToolbarChildren(leading),
              if (leading.isNotEmpty && trailing.isNotEmpty)
                const SizedBox(width: kToolbarGroupSpacing),
              if (trailing.isNotEmpty) ...[
                const Spacer(),
                ..._spacedToolbarChildren(trailing),
              ],
            ],
          );
        },
      ),
    );
  }
}

List<Widget> _spacedToolbarChildren(List<Widget> children) {
  return [
    for (var index = 0; index < children.length; index++) ...[
      if (index > 0) const SizedBox(width: kToolbarItemSpacing),
      children[index],
    ],
  ];
}

class _ToolbarMoreButton extends StatelessWidget {
  const _ToolbarMoreButton({required this.actions});

  final List<ToolbarOverflowAction> actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kToolbarControlExtent,
      height: kToolbarControlExtent,
      child: PopupMenuButton<int>(
        key: const ValueKey('toolbar-more-button'),
        tooltip: '更多',
        padding: EdgeInsets.zero,
        iconSize: kToolbarIconSize,
        icon: const Icon(Icons.more_vert),
        onSelected: (index) => actions[index].onPressed?.call(),
        itemBuilder:
            (context) => [
              for (var index = 0; index < actions.length; index++)
                PopupMenuItem<int>(
                  key: actions[index].key,
                  value: index,
                  enabled: actions[index].onPressed != null,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: IconTheme.merge(
                          data: IconThemeData(
                            size: kToolbarIconSize,
                            color:
                                actions[index].selected
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                          ),
                          child: actions[index].icon,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(actions[index].label)),
                      if (actions[index].selected)
                        Icon(
                          Icons.check,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
            ],
      ),
    );
  }
}

/// 无状态的单图标工具栏按钮。
class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kToolbarControlExtent,
      height: kToolbarControlExtent,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: kToolbarControlExtent,
          height: kToolbarControlExtent,
        ),
        // 合并 IconButton 提供的前景色，确保自定义 SVG 图标同步普通、悬停和禁用状态。
        icon: IconTheme.merge(
          data: const IconThemeData(size: kToolbarIconSize),
          child: icon,
        ),
      ),
    );
  }
}

/// 带选中状态的单图标工具栏按钮。
class ToolbarToggleIconButton extends StatelessWidget {
  const ToolbarToggleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.activeColor,
  });

  final Widget icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: selected ? color : null),
        child: ToolbarIconButton(
          icon: icon,
          tooltip: tooltip,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// 带图标、文字、提示和选中状态的工具栏按钮。
class ToolbarToggleTextButton extends StatelessWidget {
  const ToolbarToggleTextButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.activeColor,
  });

  final Widget icon;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onPressed,
        // 未选中时继承 TextButton 的前景色，选中时仅覆盖为业务状态色。
        icon: IconTheme.merge(
          data: IconThemeData(
            size: kToolbarIconSize,
            color: selected ? color : null,
          ),
          child: icon,
        ),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'SarasaUiSC',
            color: selected ? color : null,
          ),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 28),
          backgroundColor:
              selected ? color.withValues(alpha: 0.12) : Colors.transparent,
        ),
      ),
    );
  }
}

/// 工具栏统一下拉选择框。
class ToolbarDropdown<T> extends StatelessWidget {
  const ToolbarDropdown({
    super.key,
    required this.width,
    required this.value,
    required this.hint,
    required this.items,
    this.onChanged,
    this.visibleFieldOffsetY = 1,
  });

  final double width;
  final T? value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  /// 可见输入框相对工具栏点击区域的垂直偏移，用于页面级视觉对齐。
  final double visibleFieldOffsetY;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: kToolbarControlExtent,
      // 点击布局保持 32px，内部可见字段与绘图原有开始按钮同为 28px。
      child: Center(
        // 开始按钮的阴影使可见填充区域视觉中心略低，字段边框同步下移。
        child: Transform.translate(
          offset: Offset(0, visibleFieldOffsetY),
          child: SizedBox(
            height: kToolbarStartStopButtonMinHeight,
            child: NoAnimDropdown<T>(
              value: value,
              hint: hint,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
  }
}

/// 数据收发、Shell 和绘图页面共用的开始/停止按钮。
///
/// 样式以绘图页面原有按钮为准：保留 ElevatedButton 的主题圆角和阴影，
/// 仅统一状态颜色、内边距和最小高度。[label] 为空时显示纯图标。
class ToolbarStartStopButton extends StatelessWidget {
  const ToolbarStartStopButton({
    super.key,
    required this.onPressed,
    required this.running,
    this.busy = false,
    this.label,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final bool running;
  final bool busy;
  final String? label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final icon =
        busy
            ? Icons.hourglass_empty
            : running
            ? Icons.stop
            : Icons.play_arrow;
    final backgroundColor =
        busy
            ? Colors.grey
            : running
            ? Colors.red
            : Colors.green;

    final style = ElevatedButton.styleFrom(
      backgroundColor: backgroundColor,
      foregroundColor: Colors.white,
      padding:
          label == null
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      minimumSize: Size(
        label == null ? kToolbarStartStopIconButtonMinWidth : 0,
        kToolbarStartStopButtonMinHeight,
      ),
    );
    final button =
        label == null
            ? ElevatedButton(
              onPressed: onPressed,
              style: style,
              child: Icon(icon, size: 16),
            )
            : ElevatedButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: 16),
              label: Text(
                label!,
                style: const TextStyle(fontFamily: 'SarasaUiSC'),
              ),
            );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 数据收发、Shell 和绘图页面共用的高级设置入口。
///
/// 入口沿用绘图工具栏原有的调节图标，不显示文字，确保三个页面的尺寸、
/// 点击区域和提示行为完全一致。
class ToolbarAdvancedSettingsButton extends StatelessWidget {
  const ToolbarAdvancedSettingsButton({
    super.key,
    required this.onPressed,
    required this.tooltip,
  });

  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return ToolbarIconButton(
      onPressed: onPressed,
      icon: const Icon(Icons.tune),
      tooltip: tooltip,
    );
  }
}

/// 二级弹窗内单行输入框和下拉框的统一装饰。
InputDecoration secondaryDialogFieldDecoration({
  String? hintText,
  String? labelText,
  String? suffixText,
  String? counterText,
}) {
  return InputDecoration(
    isDense: true,
    border: const OutlineInputBorder(),
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    hintText: hintText,
    labelText: labelText,
    suffixText: suffixText,
    counterText: counterText,
  );
}

/// 设置弹窗右下角的统一主操作按钮。
///
/// 数据收发与 Shell 等设置弹窗共用同一 ElevatedButton 样式，仅保留各自
/// 的“确定”或“保存”语义，避免不同 Material 按钮类型产生圆角差异。
class DialogPrimaryActionButton extends StatelessWidget {
  const DialogPrimaryActionButton({
    super.key,
    required this.onPressed,
    required this.label,
  });

  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(onPressed: onPressed, child: Text(label));
  }
}

/// 无动画下拉选择框
class NoAnimDropdown<T> extends StatefulWidget {
  final T? value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;

  const NoAnimDropdown({
    super.key,
    required this.value,
    required this.hint,
    required this.items,
    this.onChanged,
    this.decoration,
  });

  @override
  State<NoAnimDropdown<T>> createState() => _NoAnimDropdownState<T>();
}

class _NoAnimDropdownState<T> extends State<NoAnimDropdown<T>> {
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();

  void _toggleMenu() {
    if (_overlayEntry != null) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final position = renderBox.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;
    final availableBelow = screenHeight - position.dy - size.height - 8;
    final availableAbove = position.dy - 8;
    final estimatedHeight = widget.items.length * 40.0;
    final desiredMaxHeight = estimatedHeight.clamp(80.0, 280.0);
    final opensUp =
        availableBelow < desiredMaxHeight && availableAbove > availableBelow;
    final availableSpace = opensUp ? availableAbove : availableBelow;
    final menuMaxHeight = availableSpace.clamp(56.0, desiredMaxHeight);

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _removeOverlay,
                behavior: HitTestBehavior.translucent,
                child: Container(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: opensUp ? Alignment.topLeft : Alignment.bottomLeft,
              followerAnchor:
                  opensUp ? Alignment.bottomLeft : Alignment.topLeft,
              offset: Offset(0, opensUp ? -2 : 2),
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(4),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: size.width,
                    maxWidth: size.width,
                    maxHeight: menuMaxHeight.toDouble(),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children:
                            widget.items.map((item) {
                              final isSelected = item.value == widget.value;
                              return InkWell(
                                onTap: () {
                                  widget.onChanged?.call(item.value);
                                  _removeOverlay();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        isSelected
                                            ? Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer
                                            : null,
                                  ),
                                  child: DefaultTextStyle(
                                    style: TextStyle(
                                      color:
                                          isSelected
                                              ? Theme.of(
                                                context,
                                              ).colorScheme.onPrimaryContainer
                                              : Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                      fontSize: 14,
                                    ),
                                    child: item.child,
                                  ),
                                ),
                              );
                            }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String displayText = widget.hint;
    if (widget.value != null) {
      for (final item in widget.items) {
        if (item.value == widget.value) {
          final child = item.child;
          if (child is Text) {
            displayText = child.data ?? widget.value.toString();
          } else {
            displayText = widget.value.toString();
          }
          break;
        }
      }
    }

    return CompositedTransformTarget(
      link: _layerLink,
      child: InkWell(
        onTap: widget.onChanged == null ? null : _toggleMenu,
        child: InputDecorator(
          decoration:
              widget.decoration ??
              const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  displayText,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        widget.onChanged == null
                            ? Colors.grey
                            : (widget.value != null
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.grey),
                    fontSize: 14,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                color: widget.onChanged == null ? Colors.grey : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可输入可下拉的组合框
class ComboInput extends StatefulWidget {
  final String? value;
  final String hint;
  final List<String> items;
  final ValueChanged<String>? onChanged;
  final InputDecoration? decoration;
  final bool enabled;

  const ComboInput({
    super.key,
    this.value,
    required this.hint,
    required this.items,
    this.onChanged,
    this.decoration,
    this.enabled = true,
  });

  @override
  State<ComboInput> createState() => _ComboInputState();
}

class _ComboInputState extends State<ComboInput> {
  late final TextEditingController _controller;
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value ?? '');
  }

  @override
  void didUpdateWidget(covariant ComboInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _toggleMenu() {
    if (_overlayEntry != null) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _removeOverlay,
                behavior: HitTestBehavior.translucent,
                child: Container(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              offset: Offset(0, size.height + 2),
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(4),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: size.width,
                    maxWidth: size.width,
                    maxHeight: 280,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children:
                            widget.items.map((item) {
                              final isSelected = item == _controller.text;
                              return InkWell(
                                onTap: () {
                                  _controller.text = item;
                                  widget.onChanged?.call(item);
                                  _removeOverlay();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        isSelected
                                            ? Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer
                                            : null,
                                  ),
                                  child: Text(
                                    item,
                                    style: TextStyle(
                                      color:
                                          isSelected
                                              ? Theme.of(
                                                context,
                                              ).colorScheme.onPrimaryContainer
                                              : Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: widget.enabled,
        decoration: (widget.decoration ??
                const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ))
            .copyWith(
              suffixIcon:
                  widget.enabled
                      ? InkWell(
                        onTap: _toggleMenu,
                        child: const Icon(Icons.arrow_drop_down),
                      )
                      : const Icon(Icons.arrow_drop_down, color: Colors.grey),
            ),
        style: const TextStyle(fontSize: 14),
        onChanged: widget.onChanged,
      ),
    );
  }
}
