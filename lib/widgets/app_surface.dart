import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';

class AppSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  final Color? tint;
  final BorderRadius borderRadius;
  final Border? border;
  final List<BoxShadow>? shadow;
  final VoidCallback? onTap;

  const AppSurface({
    super.key,
    required this.child,
    this.padding,
    this.tint,
    this.borderRadius = const BorderRadius.all(AppRadii.lg),
    this.border,
    this.shadow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow ?? AppShadows.cardFor(context),
      ),
      child: Material(
        color: tint ?? context.palette.surface,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border:
                border ?? Border.all(color: context.palette.hairline, width: 1),
          ),
          child: child,
        ),
      ),
    );
    if (onTap == null) return box;
    return Pressable(onTap: onTap, child: box);
  }
}
