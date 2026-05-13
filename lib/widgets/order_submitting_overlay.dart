// Order Submitting Overlay — shown during the in-flight order.create round trip.
//
// Mocks 1.6s of "Sending to kitchen..." then resolves; in production this
// listens for order.confirmed / order.rejected from the WS connection.

import 'package:flutter/material.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

class OrderSubmittingOverlay {
  static Future<bool> show(BuildContext context) async {
    return await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const _Overlay(),
      transitionBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ) ?? false;
  }
}

class _Overlay extends StatefulWidget {
  const _Overlay();
  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() { _spin.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Center(
      child: LiquidGlassSurface(
        blur: 32, thickness: 14,
        borderRadius: const BorderRadius.all(AppRadii.lg),
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: _spin,
              child: Container(
                width: 56, height: 56,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.terra400, AppColors.terra600],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: AppShadows.terraGlow,
                ),
                child: const Icon(Icons.restaurant_menu,
                  color: Colors.white, size: 26),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Sending to kitchen…', style: AppTypography.title),
            const SizedBox(height: 6),
            const Text('Printing KOTs',
              style: AppTypography.caption),
          ],
        ),
      ),
    ),
    );
  }
}
