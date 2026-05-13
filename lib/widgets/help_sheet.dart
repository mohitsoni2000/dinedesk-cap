// Help Sheet — slide-up modal accessible from QR scan and login screens.
//
// Walks through pairing steps, troubleshooting, support contact.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';

class HelpSheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      builder: (_) => const _HelpSheet(),
    );
  }
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30, thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: 8),
                children: [
                  const Text('Help', style: AppTypography.displayMd),
                  const SizedBox(height: 4),
                  const Text('Pair, sign in, and troubleshoot',
                    style: AppTypography.caption),
                  const SizedBox(height: 24),

                  const _Section(
                    title: 'How to pair this device',
                    children: [
                      _Step(num: 1, label:
                        'On the admin desktop, open Settings → Operator Mobile App → Pairing QR.'),
                      _Step(num: 2, label:
                        'Make sure your phone is on the same WiFi as the admin PC.'),
                      _Step(num: 3, label:
                        'Tap "Pair Device" here and scan the QR shown on screen.'),
                      _Step(num: 4, label:
                        'Enter your username and PIN — given to you by your manager.'),
                    ],
                  ),
                  const SizedBox(height: 16),

                  const _Section(
                    title: 'QR not working?',
                    children: [
                      _Tip(label:
                        'QR refreshes every 25 seconds — wait for a new one if it fails.'),
                      _Tip(label:
                        'Hold the phone steady, ~20 cm from the screen.'),
                      _Tip(label:
                        'Turn on the torch in low light.'),
                      _Tip(label:
                        'If you still can\'t connect, ensure both devices are on the same WiFi.'),
                    ],
                  ),
                  const SizedBox(height: 16),

                  const _Section(
                    title: 'Forgot your PIN?',
                    children: [
                      _Tip(label:
                        'Ask your manager to reset it from User Management on the admin desktop.'),
                      _Tip(label:
                        'You\'ll be prompted to set a new PIN on the next sign-in.'),
                    ],
                  ),
                  const SizedBox(height: 24),

                  Text('CONTACT SUPPORT',
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  const _ContactRow(
                    icon: Icons.phone_outlined,
                    label: '+91 98100 00000',
                  ),
                  const SizedBox(height: 8),
                  const _ContactRow(
                    icon: Icons.mail_outline,
                    label: 'support@restroapp.in',
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16,
                16 + MediaQuery.of(context).viewPadding.bottom),
              child: LiquidPrimaryButton(
                label: 'Got it',
                fullWidth: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTypography.title),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int num;
  final String label;
  const _Step({required this.num, required this.label});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24, height: 24,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.terra400, AppColors.terra600],
              ),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text('$num',
                style: AppTypography.caption.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: AppTypography.bodyMd)),
        ],
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  final String label;
  const _Tip({required this.label});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.circle, size: 6, color: AppColors.ink50),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: AppTypography.bodyMd)),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ContactRow({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: AppColors.ink10),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.ink70, size: 18),
          const SizedBox(width: 10),
          Text(label, style: AppTypography.bodyMd),
        ],
      ),
    );
  }
}
