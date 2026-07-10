import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_mesh_background.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  bool _showLogo = false;
  bool _showWordmark = false;
  bool _showOperator = false;
  bool _showVersion = false;

  late final AnimationController _pulseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  Timer? _redirectTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _showLogo = true);

      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _showWordmark = true);
      });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showOperator = true);
      });
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _showVersion = true);
      });
    });

    _redirectTimer = Timer(const Duration(milliseconds: 1800), () async {
      if (!mounted) return;
      final pairing = await SessionService().getSavedPairing();
      if (!mounted) return;
      if (pairing != null) {
        context.go('/connecting');
      } else {
        context.go('/scan');
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _redirectTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LiquidMeshBackground(
      dark: true,
      child: Stack(
        children: [

          const Positioned.fill(
            child: IgnorePointer(child: _GrainOverlay()),
          ),

          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.0,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.45),
                    ],
                    stops: const [0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),

          DepthParallaxStack(
            maxOffset: 8,
            layers: [
              const DepthLayer(depth: 0.0, child: SizedBox.expand()),
              DepthLayer(
                depth: 0.6,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [

                      AnimatedBuilder(
                        animation: _pulseCtrl,
                        builder: (_, child) {
                          final glow = 0.3 + 0.7 * _pulseCtrl.value;
                          return Stack(
                            alignment: Alignment.center,
                            children: [

                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.terra400
                                          .withValues(alpha: 0.18 * glow),
                                      blurRadius: 40 * glow,
                                      spreadRadius: 8 * glow,
                                    ),
                                  ],
                                ),
                              ),
                              child!,
                            ],
                          );
                        },
                        child: SpringBuilder(
                          from: 0.0,
                          to: _showLogo ? 1.0 : 0.0,
                          spring: RestroSprings.bouncy,
                          builder: (_, t, child) => Opacity(
                            opacity: t.clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: 0.75 + 0.25 * t,
                              child: child,
                            ),
                          ),
                          child: Hero(
                            tag: HeroTags.appLogo,
                            child: Container(
                              width: 88,
                              height: 88,
                              decoration: const BoxDecoration(
                                color: AppColors.logoBg,
                                borderRadius: BorderRadius.all(AppRadii.lg),
                                boxShadow: AppShadows.logoGlow,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Image.asset(
                                  'assets/images/appicon_cream.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      SpringBuilder(
                        from: 0.0,
                        to: _showWordmark ? 1.0 : 0.0,
                        spring: RestroSprings.soft,
                        builder: (_, t, child) => Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(0, 12 * (1 - t)),
                            child: child,
                          ),
                        ),
                        child: Image.asset(
                          'assets/images/lockup_ink_cream.png',
                          height: 26,
                          fit: BoxFit.contain,
                        ),
                      ),

                      const SizedBox(height: 14),

                      SpringBuilder(
                        from: 0.0,
                        to: _showOperator ? 1.0 : 0.0,
                        spring: RestroSprings.soft,
                        builder: (_, t, child) => Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: child,
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 120,
                              height: 0.5,
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'O P E R A T O R',
                              style: TextStyle(
                                fontFamily: AppTypography.inter,
                                fontWeight: FontWeight.w600,
                                fontSize: 10,
                                letterSpacing: 6,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: 120,
                              height: 0.5,
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          Positioned(
            right: 20,
            bottom: 20,
            child: SafeArea(
              child: SpringBuilder(
                from: 0.0,
                to: _showVersion ? 1.0 : 0.0,
                spring: RestroSprings.soft,
                builder: (_, t, __) => Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Text(
                    'v2.0',
                    style: AppTypography.micro.copyWith(
                      color: Colors.white.withValues(alpha: 0.2),
                      fontSize: 9,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GrainOverlay extends StatefulWidget {
  const _GrainOverlay();
  @override
  State<_GrainOverlay> createState() => _GrainOverlayState();
}

class _GrainOverlayState extends State<_GrainOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _GrainPainter(seed: _ctrl.value),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  final double seed;
  _GrainPainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random((seed * 1000).toInt());
    final paint = Paint()..style = PaintingStyle.fill;
    const grainCount = 800;
    for (int i = 0; i < grainCount; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final opacity = rng.nextDouble() * 0.045;
      paint.color = Colors.white.withValues(alpha: opacity);
      canvas.drawRect(
        Rect.fromLTWH(x, y, 1.2, 1.2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) => old.seed != seed;
}
