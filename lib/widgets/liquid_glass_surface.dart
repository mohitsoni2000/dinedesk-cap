

import 'dart:ui' as ui;
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
  });

  Color _tint(bool darkTheme) {
    if (tint != null) return tint!;
    switch (variant) {
      case LiquidGlassVariant.regular:
        return Colors.white.withValues(alpha: darkTheme ? 0.08 : 0.14);
      case LiquidGlassVariant.strong:
        return Colors.white.withValues(alpha: darkTheme ? 0.14 : 0.24);
      case LiquidGlassVariant.dark:
        return Colors.black.withValues(alpha: 0.20);
      case LiquidGlassVariant.terra:
        return AppColors.terra400.withValues(alpha: 0.22);
    }
  }

  @override
  Widget build(BuildContext context) {

    final darkTheme = context.palette.isDark;
    final tintColor = _tint(darkTheme);
    final isDark = variant == LiquidGlassVariant.dark || darkTheme;

    final rimColor = Colors.white.withValues(alpha: isDark ? 0.14 : 0.55);

    final sheenTop = Colors.white.withValues(alpha: isDark ? 0.06 : 0.22);

    final effectiveShadow = shadow ?? AppShadows.glass;

    final sigma = (blur / 3.2).clamp(6.0, 16.0);

    final fillColor = skipBlur
        ? tintColor.withValues(alpha: (tintColor.a + 0.18).clamp(0.0, 1.0))
        : tintColor;

    Widget body = DecoratedBox(

      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [sheenTop, Colors.transparent],
          stops: const [0.0, 0.55],
        ),
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: borderRadius,
          border: Border.all(color: rimColor, width: 0.8),
        ),
        child: child,
      ),
    );

    final surface = skipBlur
        ? body
        : BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: body,
          );

    final wrapped = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: effectiveShadow,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: surface),
    );

    if (onTap == null) return wrapped;

    return Pressable(
      onTap: onTap,
      pressedScale: 0.95,
      child: wrapped,
    );
  }
}
