import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';

/// Flat, blur-free surface for the "Light" design system — white/card fill,
/// hairline border, soft drop shadow. Replaces [LiquidGlassSurface] on light
/// screens (no [BackdropFilter], nothing to composite per frame).
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
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? context.palette.surface,
        borderRadius: borderRadius,
        border: border ?? Border.all(color: context.palette.hairline, width: 1),
        boxShadow: shadow ?? AppShadows.cardFor(context),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Pressable(onTap: onTap, child: box);
  }
}
