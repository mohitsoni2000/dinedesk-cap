import 'package:flutter/material.dart';

import '../motion/motion.dart';
import '../theme/tokens.dart';

enum LiquidGlassVariant { regular, strong, dark, terra }

class LiquidGlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final LiquidGlassVariant variant;
  final EdgeInsetsGeometry? padding;

  final double thickness;

  final double blur;
  final List<BoxShadow>? shadow;
  final Color? tint;
  final VoidCallback? onTap;

  final bool skipBlur;

  final String? semanticLabel;

  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(AppRadii.lg),
    this.variant = LiquidGlassVariant.regular,
    this.padding,
    this.thickness = 20,
    this.blur = 38,
    this.shadow,
    this.tint,
    this.onTap,
    this.skipBlur = false,
    this.semanticLabel,
  });

  Color _fill(BuildContext context) {
    if (tint != null) return tint!;
    final palette = context.palette;
    switch (variant) {
      case LiquidGlassVariant.regular:
        return palette.surface;
      case LiquidGlassVariant.strong:
        return palette.surfaceWarm;
      case LiquidGlassVariant.dark:
        return palette.isDark ? AppColors.night : palette.surfaceWarm;
      case LiquidGlassVariant.terra:
        return AppColors.terra400;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget wrapped = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _fill(context),
        borderRadius: borderRadius,
        border: Border.all(color: context.palette.hairline),
        boxShadow: shadow,
      ),
      child: child,
    );

    if (onTap == null) return wrapped;

    return Pressable(
      onTap: onTap,
      pressedScale: 0.97,
      semanticLabel: semanticLabel,
      child: wrapped,
    );
  }
}
