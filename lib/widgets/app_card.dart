
import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  final Color? background;
  final BorderRadius borderRadius;
  final Border? border;
  final List<BoxShadow>? shadow;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.background,
    this.borderRadius = const BorderRadius.all(AppRadii.lg),
    this.border,
    this.shadow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final box = Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow ?? context.palette.cardShadow,
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
        ),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: background ?? palette.surface,
            borderRadius: borderRadius,
            border: border ?? Border.all(color: palette.ink10, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
    if (onTap == null) return box;
    return Pressable(onTap: onTap, child: box);
  }
}
