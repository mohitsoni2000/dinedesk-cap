// Order Submitting Overlay — shown during the in-flight order.create round trip.
//
// The caller provides a [Completer<bool>] which is resolved when the server
// acknowledges (true) or rejects (false) the order. A safety timeout of 15s
// prevents the overlay from staying on-screen indefinitely.

import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

class OrderSubmittingOverlay {
  /// Shows the overlay and returns when the [completer] resolves or the safety
  /// timeout (15 s) fires. Returns `true` on success, `false` on error/timeout.
  static Future<bool> show(
    BuildContext context, {
    required Completer<bool> completer,
  }) async {
    // Capture navigator before any async gap to satisfy use_build_context_synchronously.
    final nav = Navigator.of(context, rootNavigator: true);

    // Safety timeout — auto-dismiss after 15 s so the UI never locks up.
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) completer.complete(false);
    });

    // Wait for the external signal in parallel with showing the dialog.
    final dialogFuture = showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const _Overlay(),
      transitionBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );

    // When the completer resolves, pop the dialog.
    completer.future.then((ok) {
      timer.cancel();
      if (nav.canPop()) nav.pop(ok);
    });

    return await dialogFuture ?? false;
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
            const Text('Sending to kitchen\u2026', style: AppTypography.title),
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
