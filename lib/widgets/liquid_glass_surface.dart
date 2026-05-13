// Liquid-glass surface primitive.
//
// Wraps `liquid_glass_renderer`'s LiquidGlass widget with our app defaults
// (terra-tuned tints, rim-light overlay, sensible blur). Use this for any
// floating chrome — app bar, bottom nav, FAB, modals, pills, ghost buttons.
//
// For solid surfaces (cards, list rows, dense content), use a regular
// Container with AppColors.paper — per HIG, dense content stays opaque.

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/tokens.dart';

enum LiquidGlassVariant { regular, strong, dark, terra }

class LiquidGlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final LiquidGlassVariant variant;
  final EdgeInsetsGeometry? padding;
  final double thickness; // controls refraction strength
  final double blur;
  final List<BoxShadow>? shadow;
  final Color? tint;
  final VoidCallback? onTap;

  /// Note: [LiquidRoundedSuperellipse] only supports a uniform radius.
  /// The glass refraction layer uses [borderRadius.topLeft] for its shape.
  /// The outer clip and decoration correctly use the full [borderRadius].
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(AppRadii.lg),
    this.variant = LiquidGlassVariant.regular,
    this.padding,
    this.thickness = 12,
    this.blur = 20,
    this.shadow,
    this.tint,
    this.onTap,
  });

  Color _tint() {
    if (tint != null) return tint!;
    switch (variant) {
      case LiquidGlassVariant.regular: return Colors.white.withValues(alpha: 0.22);
      case LiquidGlassVariant.strong:  return Colors.white.withValues(alpha: 0.40);
      case LiquidGlassVariant.dark:    return Colors.black.withValues(alpha: 0.28);
      case LiquidGlassVariant.terra:   return AppColors.terra400.withValues(alpha: 0.32);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tintColor = _tint();
    final isDark = variant == LiquidGlassVariant.dark;
    final rimWhite = isDark ? 0.32 : 0.75;
    final rimAmbient = isDark ? 0.18 : 0.28;

    final effectiveShadow = shadow ?? AppShadows.card;

    Widget surface = LiquidGlass.withOwnLayer(
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius.topLeft.x),
      settings: LiquidGlassSettings(
        thickness: thickness,
        blur: blur,
        glassColor: tintColor,
        lightAngle: 0.6, // upper-left light source
        lightIntensity: 1.2,
        ambientStrength: 0.55,
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          // Rim-light: signature inset white highlight on the bezel
          border: Border.all(
            color: Colors.white.withValues(alpha: rimAmbient),
            width: 0.5,
          ),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: borderRadius,
          // Inner specular sweep — diagonal light catch
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: rimWhite * 0.55),
              Colors.white.withValues(alpha: rimWhite * 0.18),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.18, 0.45],
          ),
          backgroundBlendMode: BlendMode.overlay,
        ),
        child: child,
      ),
    );

    final wrapped = Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: effectiveShadow,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: surface),
    );

    if (onTap == null) return wrapped;
    return GestureDetector(onTap: onTap, child: wrapped);
  }
}
