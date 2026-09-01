import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../discover_pairing_sheet.dart';
import '../help_sheet.dart';
import '../liquid_glass_surface.dart';
import '../manual_entry_sheet.dart';
import '../page_content_clamp.dart';

class QrScanConsole extends StatelessWidget {
  final VoidCallback onOpenScanner;
  final VoidCallback onDemoScan;

  const QrScanConsole({
    super.key,
    required this.onOpenScanner,
    required this.onDemoScan,
  });

  @override
  Widget build(BuildContext context) {
    return PageContentClamp(
      maxWidth: 560,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Top Header & Brand Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: AppColors.logoBg,
                                borderRadius:
                                    const BorderRadius.all(AppRadii.md),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Image.asset(
                                'assets/images/appicon_cream.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Command.Crew',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppTypography.cormorant,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 22,
                                      color: Colors.white,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  Text(
                                    'Setup & Pairing',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.micro.copyWith(
                                      color:
                                          Colors.white.withValues(alpha: 0.50),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
                  const SizedBox(height: 22),

                  // 2. Hero Setup Text
                  const Text(
                    'Pair this Device',
                    style: TextStyle(
                      fontFamily: AppTypography.cormorant,
                      fontWeight: FontWeight.w600,
                      fontSize: 26,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Connect this captain device to your POS desktop server to manage tables, place orders, and sync kitchen tickets.',
                    style: AppTypography.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 3. Featured Primary Action Card (Scan QR Code)
                  _PairingFeaturedTile(
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Scan QR Code',
                    badgeText: 'RECOMMENDED',
                    subtitle:
                        'Point camera at the rotating QR code on admin POS desktop',
                    actionLabel: 'Scan Now',
                    onTap: onOpenScanner,
                  ),
                  const SizedBox(height: 12),

                  // 4. Secondary Action Cards (Enter Code & Discover)
                  Row(
                    children: [
                      Expanded(
                        child: _PairingSecondaryCard(
                          icon: Icons.keyboard_outlined,
                          title: 'Enter Code',
                          subtitle: 'IP, port & token',
                          onTap: () => ManualEntrySheet.show(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _PairingSecondaryCard(
                          icon: Icons.wifi_find_rounded,
                          title: 'Auto Discover',
                          subtitle: 'Search Wi-Fi network',
                          onTap: () => DiscoverPairingSheet.show(context),
                        ),
                      ),
                    ],
                  ),

                  const Spacer(),
                  const SizedBox(height: 16),

                  // 5. Footer Demo Setup Banner
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: GestureDetector(
                        onTap: onDemoScan,
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: AppTypography.caption.copyWith(
                              color: Colors.white.withValues(alpha: 0.50),
                              fontSize: 13,
                            ),
                            children: [
                              const TextSpan(text: 'No server nearby? '),
                              TextSpan(
                                text: 'Explore Demo Kitchen →',
                                style: TextStyle(
                                  color: AppColors.terra100
                                      .withValues(alpha: 0.95),
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairingFeaturedTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String badgeText;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;

  const _PairingFeaturedTile({
    required this.icon,
    required this.title,
    required this.badgeText,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.lg),
      tint: AppColors.terra.withValues(alpha: 0.18),
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: AppColors.terra500,
                  borderRadius: BorderRadius.all(AppRadii.md),
                ),
                child: Icon(
                  icon,
                  color: AppColors.terra50,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.terra100,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.terra500.withValues(alpha: 0.35),
                            borderRadius: const BorderRadius.all(AppRadii.pill),
                            border: Border.all(
                              color: AppColors.terra200.withValues(alpha: 0.40),
                            ),
                          ),
                          child: Text(
                            badgeText,
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: AppColors.terra100,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppTypography.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.terra500,
              borderRadius: BorderRadius.all(AppRadii.md),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  actionLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.terra50,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: AppColors.terra50,
                  size: 16,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PairingSecondaryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PairingSecondaryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.lg),
      tint: Colors.white.withValues(alpha: 0.06),
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: const BorderRadius.all(AppRadii.sm),
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: 0.50),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
