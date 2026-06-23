// Liquid-glass background mesh painter.
//
// Paints the warm cream backdrop with terra/amber/violet/teal radial blobs so
// the LiquidGlass widgets have something to refract.
//
// PERFORMANCE NOTES (why this is structured the way it is):
//  • The animated painter is isolated in its own RepaintBoundary and the UI
//    `child` is a SIBLING in a Stack — so when the mesh repaints each frame it
//    re-rasterizes ONLY the background layer, not the whole screen on top of it.
//    (Previously the child sat inside the CustomPaint subtree, so every drift
//    frame re-rastered the entire UI.)
//  • `willChange` is true only while animating; when static, Flutter caches the
//    painted picture and per-frame cost drops to zero.
//  • Pass `animate: false` for transient pushed screens that sit on screen
//    briefly (order builder/review/detail) — the drift is imperceptible there
//    and you save a second looping controller behind the visible one.

import 'package:flutter/material.dart';
import '../theme/tokens.dart';

class LiquidMeshBackground extends StatefulWidget {
  final Widget child;
  final bool dark;
  final bool animate;
  const LiquidMeshBackground({
    super.key,
    required this.child,
    this.dark = false,
    this.animate = true,
  });

  @override
  State<LiquidMeshBackground> createState() => _LiquidMeshBackgroundState();
}

class _LiquidMeshBackgroundState extends State<LiquidMeshBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _startController();
  }

  void _startController() {
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24), // slower drift = cheaper, calmer
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant LiquidMeshBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && _ctrl == null) {
      _startController();
    } else if (!widget.animate && _ctrl != null) {
      _ctrl!.dispose();
      _ctrl = null;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget background = _ctrl == null
        ? CustomPaint(
            size: Size.infinite,
            isComplex: true,
            willChange: false,
            painter: _MeshPainter(t: 0.5, dark: widget.dark),
          )
        : AnimatedBuilder(
            animation: _ctrl!,
            builder: (_, __) => CustomPaint(
              size: Size.infinite,
              isComplex: true,
              willChange: true,
              painter: _MeshPainter(t: _ctrl!.value, dark: widget.dark),
            ),
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Background lives in its own layer; its repaints never touch the UI.
        RepaintBoundary(child: background),
        widget.child,
      ],
    );
  }
}

class _MeshPainter extends CustomPainter {
  final double t;
  final bool dark;
  _MeshPainter({required this.t, required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    // Base wash
    final base = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark
            ? const [AppColors.meshDark1, AppColors.meshDark2, AppColors.meshDark3]
            : const [
                AppColors.paperHint,
                AppColors.paperWarm,
                AppColors.paperDeeper
              ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, base);

    // Drifting blobs
    final drift =
        Offset(size.width * 0.02 * (t - 0.5), size.height * 0.015 * (t - 0.5));
    void blob(Offset center, double radius, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center + drift, radius: radius));
      canvas.drawCircle(center + drift, radius, paint);
    }

    final terraA = dark ? 0.55 : 0.35;
    final amberA = dark ? 0.38 : 0.32;
    final amberB = dark ? 0.32 : 0.28;
    final violetA = dark ? 0.32 : 0.22;
    final blueA = dark ? 0.25 : 0.18;

    blob(Offset(size.width * 0.12, size.height * 0.06), size.width * 0.7,
        AppColors.terra400.withValues(alpha: terraA));
    blob(Offset(size.width * 0.92, size.height * 0.14), size.width * 0.6,
        AppColors.warn.withValues(alpha: amberA));
    blob(Offset(size.width * 0.50, size.height * 0.88), size.width * 0.85,
        AppColors.terra600.withValues(alpha: amberB));
    blob(Offset(size.width * 0.96, size.height * 0.78), size.width * 0.5,
        AppColors.violet.withValues(alpha: violetA));
    blob(Offset(size.width * 0.08, size.height * 0.64), size.width * 0.45,
        AppColors.teal.withValues(alpha: blueA));
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) =>
      old.t != t || old.dark != dark;
}
