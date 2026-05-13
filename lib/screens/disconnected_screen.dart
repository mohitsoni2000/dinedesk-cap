// Disconnected Screen — shown when the 2-minute reconnect grace expires.
//
// Distinct from /force-disconnected which is triggered by an admin-initiated
// kick. Here the device simply lost contact long enough that the session is
// stale and a fresh QR pair is required.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';

class DisconnectedScreen extends StatelessWidget {
  const DisconnectedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LiquidMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              if (context.canPop())
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: AppColors.ink70),
                      onPressed: () => context.pop(),
                    ),
                  ),
                ),
              Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LiquidGlassSurface(
                blur: 32, thickness: 14,
                borderRadius: const BorderRadius.all(AppRadii.lg),
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.warn.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.wifi_off_rounded,
                        color: AppColors.warn, size: 32),
                    ),
                    const SizedBox(height: 20),
                    const Text('Connection lost', style: AppTypography.displayMd),
                    const SizedBox(height: 8),
                    Text(
                      'Couldn\'t reconnect in time. Your draft has been cleared — '
                      'please scan the QR again to resume.',
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyMd.copyWith(color: AppColors.ink70),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.warn.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('CHECK WIFI · NETWORK · ADMIN PC',
                        style: AppTypography.micro.copyWith(
                          color: AppColors.warn, letterSpacing: 1.0,
                        )),
                    ),
                    const SizedBox(height: 24),
                    LiquidPrimaryButton(
                      label: 'Scan QR',
                      fullWidth: true,
                      leadingIcon: Icons.qr_code_scanner,
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        context.go('/scan');
                      },
                    ),
                    const SizedBox(height: 8),
                    LiquidSecondaryButton(
                      label: 'Try reconnect once more',
                      leadingIcon: Icons.refresh,
                      onPressed: () => context.go('/connecting'),
                    ),
                  ],
                ),
              ),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}
