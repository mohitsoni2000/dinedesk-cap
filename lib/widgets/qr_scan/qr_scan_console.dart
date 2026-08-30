import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../discover_pairing_sheet.dart';
import '../help_sheet.dart';
import '../liquid_glass_surface.dart';
import '../manual_entry_sheet.dart';

class QrScanConsole extends StatelessWidget {
  final VoidCallback onDemoScan;

  const QrScanConsole({
    super.key,
    required this.onDemoScan,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.xl),
        tint: AppColors.night,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text(
                    'Pair this device',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTypography.cormorant,
                      fontWeight: FontWeight.w600,
                      fontSize: 26,
                      height: 1.1,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => HelpSheet.show(context),
                  icon: Icon(
                    Icons.help_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.70),
                    size: 22,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Point at the rotating QR on the admin desktop — '
              'verified with the server before anything is saved.',
              style: AppTypography.caption.copyWith(
                color: Colors.white.withValues(alpha: 0.60),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ConsoleButton(
                    icon: Icons.keyboard_outlined,
                    label: 'Enter code',
                    emphasis: true,
                    onTap: () => ManualEntrySheet.show(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ConsoleButton(
                    icon: Icons.wifi_find_rounded,
                    label: 'Discover',
                    onTap: () => DiscoverPairingSheet.show(context),
                  ),
                ),
              ],
            ),
            if (kDebugMode) ...[
              const SizedBox(height: 14),
              Center(
                child: GestureDetector(
                  onTap: onDemoScan,
                  child: RichText(
                    text: TextSpan(
                      style: AppTypography.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.42),
                      ),
                      children: [
                        const TextSpan(text: 'No server around? '),
                        TextSpan(
                          text: 'Explore the demo kitchen',
                          style: TextStyle(
                            color: AppColors.terra100.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ConsoleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool emphasis;
  final VoidCallback onTap;

  const ConsoleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.md),
      tint: emphasis
          ? AppColors.terra500
          : Colors.white.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(vertical: 13),
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: emphasis ? AppColors.terra100 : Colors.white,
            size: 16,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                color: emphasis ? AppColors.terra100 : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
