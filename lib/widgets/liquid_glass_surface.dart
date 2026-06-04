// Liquid-glass surface primitive — iOS 26-accurate settings.
//
// Key changes from previous version:
//   • blur 38 (was 20) — real frosted-glass needs heavy blur
//   • thickness 20 (was 12) — depth for visible refraction
//   • lightIntensity 0.55 (was 1.2) — overblown highlights killed the effect
//   • ambientStrength 0.18 (was 0.55) — excessive ambient washed out refraction
//   • refractiveIndex 1.35 — now has visible lens distortion
//   • saturation 1.25 — vivid-through-glass look
//   • glassColor alpha 0.08 (was 0.22) — nearly transparent = truer glass
//   • specular sweep 0.18 max (was 0.41) — subtle iOS rim-light
//
// For solid surfaces (dense content), use AppCard — dense content stays opaque.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

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

  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(AppRadii.lg),
    this.variant = LiquidGlassVariant.regular,
    this.padding,
    this.thickness = 20, // was 12 — needs 20+ for real refraction depth
    this.blur = 38,      // was 20 — needs 38+ for iOS frosted look
    this.shadow,
    this.tint,
    this.onTap,
  });

  Color _tint() {
    if (tint != null) return tint!;
    switch (variant) {
      case LiquidGlassVariant.regular:
        return Colors.white.withValues(alpha: 0.08); // was 0.22 — too opaque
      case LiquidGlassVariant.strong:
        return Colors.white.withValues(alpha: 0.16); // was 0.40
      case LiquidGlassVariant.dark:
        return Colors.black.withValues(alpha: 0.18); // was 0.28
      case LiquidGlassVariant.terra:
        return AppColors.terra400.withValues(alpha: 0.18); // was 0.32
    }
  }

  @override
  Widget build(BuildContext context) {
    final tintColor = _tint();
    final isDark = variant == LiquidGlassVariant.dark;

    // iOS-accurate specular values — subtle, not "AI glow"
    final specularPeak = isDark ? 0.10 : 0.18;  // was 0.41 — way too bright
    final specularMid  = isDark ? 0.04 : 0.08;  // was 0.21
    final rimAlpha     = isDark ? 0.10 : 0.20;  // hairline border

    final effectiveShadow = shadow ?? AppShadows.glass;

    Widget surface = LiquidGlass.withOwnLayer(
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius.topLeft.x),
      settings: LiquidGlassSettings(
        thickness: thickness,
        blur: blur,
        glassColor: tintColor,
        lightAngle: math.pi * 0.58, // ~105° — upper-left light source
        lightIntensity: 0.55,        // was 1.2 — overblown
        ambientStrength: 0.18,       // was 0.55 — washed out refraction
        refractiveIndex: 1.35,       // visible lens effect (was 1.2 default)
        saturation: 1.25,            // slightly vivid through glass (was 1.5)
        chromaticAberration: 0.006,  // very subtle colour fringe
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          // Hairline rim-light — iOS signature thin bright edge
          border: Border.all(
            color: Colors.white.withValues(alpha: rimAlpha),
            width: 0.5,
          ),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: borderRadius,
          // Inner specular sweep — diagonal light catch, now subtle
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: specularPeak),
              Colors.white.withValues(alpha: specularMid),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.15, 0.40],
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
