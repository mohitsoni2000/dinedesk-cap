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
    // Same shape as [AppCard]: the fill is a [Material] so that a ListTile
    // inside finds one *above* the opaque surface colour and its ink splash
    // is visible. Painting the colour with a plain Container left the nearest
    // Material behind the card, so settings rows gave no ripple at all and
    // Flutter asserted on every build.
    //
    // The shadow moves to an outer Container — Material would otherwise clip
    // it — and the border to an inner one, since Material has no border.
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
