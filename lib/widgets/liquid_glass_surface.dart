import 'package:flutter/material.dart';

import '../motion/motion.dart';
import '../theme/tokens.dart';

/// A plain, opaque panel.
///
/// This was a frosted-glass surface: a [BackdropFilter] blur, a translucent
/// white tint, a diagonal sheen gradient and a bright rim, stacked under a
/// four-layer drop shadow. All of that is gone. It is now a solid fill and a
/// hairline border, which is the whole of the visual language the app uses
/// now.
///
/// The class and its parameters survive so the call sites keep reading the
/// way they did. [blur] and [skipBlur] are retained and ignored — there is no
/// blur left to skip.
enum LiquidGlassVariant { regular, strong, dark, terra }

class LiquidGlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final LiquidGlassVariant variant;
  final EdgeInsetsGeometry? padding;

  final double thickness;

  /// Retained for source compatibility. Ignored.
  final double blur;
  final List<BoxShadow>? shadow;
  final Color? tint;
  final VoidCallback? onTap;

  /// Retained for source compatibility. Ignored.
  final bool skipBlur;

  /// Screen-reader label, forwarded to [Pressable]. Only meaningful when
  /// [onTap] is set and the child is an icon rather than text.
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

  /// An opaque fill per variant. The old tints were low-alpha whites that only
  /// read as anything because there was a blurred, gradient-washed backdrop
  /// behind them; over a flat background they were invisible.
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
