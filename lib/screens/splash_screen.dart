import 'dart:async';

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

class _SplashScreenState extends State<SplashScreen> {
  bool _show = false;
  Timer? _redirectTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _show = true);
    });
    // Check for stored pairing — skip QR scan if a previous session exists.
    _redirectTimer = Timer(const Duration(milliseconds: 1800), () async {
      if (!mounted) return;
      final pairing = await SessionService().getSavedPairing();
      if (!mounted) return;
      if (pairing != null) {
        context.go('/connecting'); // Skip QR scan, try reconnect.
      } else {
        context.go('/scan');
      }
    });
  }

  @override
  void dispose() {
    _redirectTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LiquidMeshBackground(
      dark: true,
      child: DepthParallaxStack(
        maxOffset: 8,
        layers: [
          // Background: the mesh (stationary anchor)
          const DepthLayer(depth: 0.0, child: SizedBox.expand()),
          // Foreground: the logo content
          DepthLayer(
            depth: 0.6,
            child: Center(
              child: SpringBuilder(
                from: 0.0,
                to: _show ? 1.0 : 0.0,
                spring: RestroSprings.bouncy,
                builder: (BuildContext _, double t, Widget? child) {
                  final scale = 0.8 + 0.2 * t;
                  return Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.scale(scale: scale, child: child),
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Hero(
                      tag: HeroTags.appLogo,
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [AppColors.terra400, AppColors.terra600],
                          ),
                          borderRadius: BorderRadius.all(AppRadii.lg),
                          boxShadow: AppShadows.terraGlow,
                        ),
                        child: const Center(
                          child: Text(
                            'R',
                            style: TextStyle(
                              fontFamily: AppTypography.cormorant,
                              fontSize: 56,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Restro',
                      style: TextStyle(
                        fontFamily: AppTypography.cormorant,
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Operator',
                      style: AppTypography.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.7),
                        letterSpacing: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
