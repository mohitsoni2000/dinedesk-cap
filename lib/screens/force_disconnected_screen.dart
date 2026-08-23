import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';

class ForceDisconnectedScreen extends ConsumerWidget {
  const ForceDisconnectedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: Stack(
          children: [
            if (context.canPop())
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => context.pop(),
                  ),
                ),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: const BorderRadius.all(AppRadii.lg),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.danger.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.power_off_rounded,
                            color: AppColors.danger, size: 32),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Signed out',
                        style: AppTypography.displayMd
                            .copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'A manager signed this device out, or your seat was given to another '
                        'phone. Scan the pairing QR again to continue.',
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyMd.copyWith(
                            color: Colors.white.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 24),
                      LiquidPrimaryButton(
                        label: 'Scan QR to pair',
                        fullWidth: true,
                        leadingIcon: Icons.qr_code_scanner,
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          SessionService().clearPairing();
                          ref.read(forceDisconnectedProvider.notifier).state =
                              false;
                          context.go('/scan');
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
