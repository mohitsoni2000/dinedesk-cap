import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();

  @override
  void initState() {
    super.initState();
    // Check for stored pairing — skip QR scan if a previous session exists.
    Future.delayed(const Duration(milliseconds: 1800), () async {
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
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return LiquidMeshBackground(
      dark: true,
      child: Center(
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween(begin: 0.8, end: 1.0).animate(
              CurvedAnimation(parent: _c, curve: Curves.easeOutCubic),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96, height: 96,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [AppColors.terra400, AppColors.terra600],
                    ),
                    borderRadius: BorderRadius.all(AppRadii.lg),
                    boxShadow: AppShadows.terraGlow,
                  ),
                  child: const Center(
                    child: Text('R',
                      style: TextStyle(
                        fontFamily: AppTypography.cormorant,
                        fontSize: 56, fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Restro',
                  style: TextStyle(
                    fontFamily: AppTypography.cormorant,
                    color: Colors.white, fontSize: 36, fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text('Operator',
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
    );
  }
}
