import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../motion/motion.dart';
import '../../services/app_settings.dart';
import '../../theme/tokens.dart';
import '../discover_pairing_sheet.dart';
import '../manual_entry_sheet.dart';

class CameraUnavailableView extends ConsumerWidget {
  final VoidCallback? onOpenSettings;

  const CameraUnavailableView({
    super.key,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: AppColors.ink,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            children: [
              const Spacer(),
              // Icon
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: const Icon(
                  Icons.no_photography_outlined,
                  color: AppColors.terra400,
                  size: 34,
                ),
              ),
              const SizedBox(height: 24),

              // Title
              const Text(
                'Camera Access Required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppTypography.cormorant,
                  fontWeight: FontWeight.w600,
                  fontSize: 26,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),

              // Subtitle
              Text(
                'Camera permission is required to scan the desktop pairing QR code. Enable it in device settings or enter the code manually.',
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(
                  color: Colors.white.withValues(alpha: 0.65),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),

              // Primary Action: Open Settings Button
              Pressable(
                semanticLabel: 'Open this app’s settings',
                onTap: () {
                  onOpenSettings?.call();
                  AppSettingsLauncher.open();
                },
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: AppTouchTargets.minimum,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(AppRadii.md),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.settings_outlined,
                        color: AppColors.night,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Open Settings',
                        style: AppTypography.bodyMd.copyWith(
                          color: AppColors.night,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),

              // Alternative Actions (Manual Code / Discover)
              Row(
                children: [
                  Expanded(
                    child: Pressable(
                      onTap: () => ManualEntrySheet.show(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: const BorderRadius.all(AppRadii.md),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.keyboard_outlined,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Enter code',
                              style: AppTypography.caption.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Pressable(
                      onTap: () => DiscoverPairingSheet.show(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: const BorderRadius.all(AppRadii.md),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.wifi_find_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Discover',
                              style: AppTypography.caption.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
