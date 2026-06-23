// Frosted-glass surface primitive.
//
// Previously this used the experimental `liquid_glass_renderer` shader
// (LiquidGlass.withOwnLayer). That shader fails on many Android GPUs
// (notably Samsung/Mali + Impeller) and rendered solid black blobs over
// every glass tile — keypad keys, banners, sheets, cards. This reimplementation
// keeps the exact same public API but draws the frosted look with standard,
// well-supported Flutter primitives (BackdropFilter blur + translucent tint +
// hairline rim-light + soft shadow), so it renders correctly on every device.
//
// For solid surfaces (dense content), use AppCard — dense content stays opaque.

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

  /// Kept for API compatibility with the old shader implementation; unused.
  final double thickness;

  /// Frosted-glass blur strength (in the old shader's units). Mapped to a
  /// sensible BackdropFilter sigma below.
  final double blur;
  final List<BoxShadow>? shadow;
  final Color? tint;
  final VoidCallback? onTap;

  /// PERF: skip the (expensive) BackdropFilter blur and use a slightly more
  /// opaque tint instead. Set true for small tiles (keypad keys, chips, small
  /// buttons) where a real blur is GPU-costly and visually indistinguishable.
  /// Keep false for large surfaces (sheets, app bar, bottom nav) where the
  /// frosted effect is visible.
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

  Color _tint() {
    if (tint != null) return tint!;
    switch (variant) {
      case LiquidGlassVariant.regular:
        return Colors.white.withValues(alpha: 0.14);
      case LiquidGlassVariant.strong:
        return Colors.white.withValues(alpha: 0.24);
      case LiquidGlassVariant.dark:
        return Colors.black.withValues(alpha: 0.20);
      case LiquidGlassVariant.terra:
        return AppColors.terra400.withValues(alpha: 0.22);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tintColor = _tint();
    final isDark = variant == LiquidGlassVariant.dark;

    // Hairline bright edge — the iOS-signature rim light that defines the shape.
    final rimColor = Colors.white.withValues(alpha: isDark ? 0.14 : 0.55);
    // Subtle top-left sheen so the surface reads as glass, not flat plastic.
    final sheenTop = Colors.white.withValues(alpha: isDark ? 0.06 : 0.22);

    final effectiveShadow = shadow ?? AppShadows.glass;
    // Map the legacy shader "blur" (≈38) onto a real BackdropFilter sigma.
    final sigma = (blur / 3.2).clamp(6.0, 16.0);

    // Without a real backdrop blur, lift the tint a little so the tile still
    // reads as a surface rather than washing out.
    final fillColor = skipBlur
        ? tintColor.withValues(alpha: (tintColor.a + 0.18).clamp(0.0, 1.0))
        : tintColor;

    Widget body = DecoratedBox(
      // Top-left sheen drawn over the tint for a soft light-catch.
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
    // iOS press-scale on every tappable glass tile (keypads, chips, actions…).
    return Pressable(
      onTap: onTap,
      pressedScale: 0.95,
      child: wrapped,
    );
  }
}
