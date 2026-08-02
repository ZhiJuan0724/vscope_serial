import 'package:flutter/material.dart';

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 8),
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ],
    ),
  );
}

class AppColorSwatchPicker extends StatelessWidget {
  const AppColorSwatchPicker({
    super.key,
    required this.colors,
    required this.value,
    required this.onChanged,
  });

  final List<Color> colors;
  final Color value;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final color in colors)
        InkWell(
          onTap: () => onChanged(color),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color:
                    color.toARGB32() == value.toARGB32()
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).dividerColor,
                width: color.toARGB32() == value.toARGB32() ? 2 : 1,
              ),
            ),
          ),
        ),
    ],
  );
}
