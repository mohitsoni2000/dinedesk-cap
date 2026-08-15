

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';

class DisconnectedScreen extends ConsumerWidget {
  const DisconnectedScreen({super.key});

  Future<void> _confirmScanQr(BuildContext context, WidgetRef ref) async {
    // The background socket keeps retrying forever and may well have already
    // reconnected by the time staff looks at the phone again — scanning a
    // fresh QR wipes the still-possibly-valid saved pairing and forces a trip
    // to the admin desktop, so make sure that's really what's needed first.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.palette.surface,
        title: const Text('Scan a new QR?', style: AppTypography.title),
        content: const Text(
          'This clears the current pairing — you\'ll need the admin desktop '
          'to show a fresh QR code. If the WiFi has since come back, try '
          '"Try reconnect once more" first instead.',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Scan QR',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    SessionService().clearPairing();
    ref.read(isAuthenticatedProvider.notifier).state = false;
    ref.read(cartProvider.notifier).clear();
    context.go('/scan');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The background socket (SocketService) keeps retrying indefinitely even
    // while this screen is up — if it silently reconnects (e.g. the WiFi
    // dead zone was left a minute after the 15-minute banner gave up),
    // there's no reason to keep stranding the operator here.
    ref.listen(connectionProvider.select((c) => c.online), (prev, online) {
      if (online == true) context.go('/tables');
    });

    return ColoredBox(
      color: context.palette.paper,
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
                      icon: Icon(Icons.close, color: context.palette.ink70),
                      onPressed: () => context.pop(),
                    ),
                  ),
                ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: AppSurface(
                    borderRadius: const BorderRadius.all(AppRadii.lg),
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppColors.warn.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.wifi_off_rounded,
                              color: AppColors.warn, size: 32),
                        ),
                        const SizedBox(height: 20),
                        const Text('Connection lost',
                            style: AppTypography.displayMd),
                        const SizedBox(height: 8),
                        Text(
                          'Couldn\'t reconnect in time. '
                          'Please scan the QR again to resume.',
                          textAlign: TextAlign.center,
                          style: AppTypography.bodyMd
                              .copyWith(color: context.palette.ink70),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.warn.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('CHECK WIFI · NETWORK · ADMIN PC',
                              style: AppTypography.micro.copyWith(
                                color: AppColors.warn,
                                letterSpacing: 1.0,
                              )),
                        ),
                        const SizedBox(height: 24),
                        LiquidPrimaryButton(
                          label: 'Try reconnect once more',
                          fullWidth: true,
                          leadingIcon: Icons.refresh,
                          onPressed: () => context.go('/connecting'),
                        ),
                        const SizedBox(height: 8),
                        LiquidSecondaryButton(
                          label: 'Scan QR',
                          leadingIcon: Icons.qr_code_scanner,
                          onPressed: () => _confirmScanQr(context, ref),
                        ),
                        // Only offered when this exact phone already holds a
                        // device secret from a prior real pairing — the desk
                        // still decides at connect time whether the admin has
                        // actually turned this on, but there is no reason to
                        // show the option on a device that could never use it.
                        FutureBuilder<bool>(
                          future: SessionService().hasDeviceSecret(),
                          builder: (context, snapshot) {
                            if (snapshot.data != true) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TextButton(
                                onPressed: () =>
                                    context.push('/recovery-login'),
                                child: Text(
                                  'Log in with employee ID instead',
                                  style: AppTypography.caption.copyWith(
                                    color: context.palette.ink50,
                                  ),
                                ),
                              ),
                            );
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
      ),
    );
  }
}
