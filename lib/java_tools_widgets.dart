import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Design tokens shared by the Java tools page and its detail pages.
///
/// Mirrors the visual language of the sibling `netrix` tool app: Material 3
/// `ColorScheme`, flat cards with a hairline outline, 12 px radii, and a
/// section heading built from a primary-coloured icon plus a title/subtitle
/// pair. Kept in one place so the grid and the details cannot drift apart.
abstract final class JavaToolsTheme {
  /// Horizontal page padding: tight on phones, wider on tablets.
  static double horizontalPadding(double width) =>
      width < 600 ? 16 : (width >= 1200 ? 32 : 24);

  /// Widest the content column grows before it is centred on a large screen.
  static const double contentMaxWidth = 1000;

  /// Card grid geometry. `maxCrossAxisExtent` lets Flutter pick the column
  /// count, so the same code is a single column on a phone and three or four on
  /// a tablet without a breakpoint table.
  static const double cardMaxWidth = 320;
  static const double cardHeight = 132;
  static const double cardSpacing = 12;

  static const double cardRadius = 12;
  static const double cardPadding = 16;

  /// The card surface: flat, outlined, and tinted from the scheme so it works
  /// in light and dark without hard-coded colours.
  static BoxDecoration cardDecoration(ColorScheme scheme) => BoxDecoration(
    color: scheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(cardRadius),
    border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
  );
}

/// A section heading: icon, title, optional subtitle and trailing action.
///
/// The same widget heads every group on the tools page, so the hierarchy is
/// identical across groups.
class JavaToolsSectionHeading extends StatelessWidget {
  const JavaToolsSectionHeading({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 20, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One tool tile: icon, name and a one-line description.
///
/// The whole tile is the tap target, and it is deliberately flat rather than
/// Material-elevated so a grid of them reads as a single surface.
class JavaToolCard extends StatelessWidget {
  const JavaToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(JavaToolsTheme.cardRadius),
          child: Ink(
            decoration: JavaToolsTheme.cardDecoration(scheme),
            child: Padding(
              padding: const EdgeInsets.all(JavaToolsTheme.cardPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 20, color: scheme.primary),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled result row with its own copy button.
///
/// Used by every tool page, so a value is always one tap from the clipboard.
class JavaResultRow extends StatelessWidget {
  const JavaResultRow({
    super.key,
    required this.label,
    required this.value,
    this.monospace = true,
    this.allowCopy = true,
  });

  final String label;
  final String value;
  final bool monospace;
  final bool allowCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontFamily: monospace ? 'monospace' : null,
                fontSize: monospace ? 13 : null,
                height: 1.4,
              ),
            ),
          ),
          if (allowCopy)
            IconButton(
              tooltip: '复制$label',
              visualDensity: VisualDensity.compact,
              onPressed: () => JavaCopy.copy(context, value),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
            ),
        ],
      ),
    );
  }
}

/// Clipboard helper shared by the tool pages.
abstract final class JavaCopy {
  static Future<void> copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制')));
  }
}
