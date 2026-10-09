import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/home_route.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';

/// Why the app ended up here. This screen is no longer a timeout: a weak or
/// dropped connection never lands here (the connection layer keeps retrying
/// forever and the banner just says so). It exists for the two cases where
/// retrying cannot help because the desk has said no.
enum DisconnectedReason {
  /// The desk repeatedly refused this device's token at the handshake.
  pairingRejected,

  /// The desk told this device to disconnect (revoked or expired).
  forced,
}

class DisconnectedScreen extends ConsumerWidget {
  final DisconnectedReason reason;
  const DisconnectedScreen(
      {super.key, this.reason = DisconnectedReason.pairingRejected});

  /// Maps the route's `?reason=` query to a [DisconnectedReason].
  static DisconnectedReason reasonFromQuery(String? value) =>
      value == 'forced'
          ? DisconnectedReason.forced
          : DisconnectedReason.pairingRejected;

  void _tryReconnect(BuildContext context, WidgetRef ref) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    // A person asked, so this goes through even for a pairing the desk refused
    // (the monitor's own automatic retries never resurrect one).
    ref.read(connectionSupervisorProvider).retryNow();
    // Straight back into the app. The bootstrap state moves off "rejected"
    // synchronously inside retry(), so the router does not bounce us back.
    goHome(context, ref);
  }

  Future<void> _confirmScanQr(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.palette.surface,
        title: const Text('Scan a new QR?', style: AppTypography.title),
        content: const Text(
          'This clears the current pairing — you\'ll need the admin desktop '
          'to show a fresh QR code. If the admin has just re-enabled this '
          'device, try "Try reconnect" first instead.',
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
    unawaited(ref.read(connectionBootstrapProvider.notifier).signOut());
    ref.read(isAuthenticatedProvider.notifier).state = false;
    ref.read(cartProvider.notifier).clear();
    context.go('/scan');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(connectionProvider.select((c) => c.online), (prev, online) {
      if (online == true) goHome(context, ref);
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
                        Text(
                            reason == DisconnectedReason.forced
                                ? 'Disconnected by the desk'
                                : 'This device needs pairing again',
                            textAlign: TextAlign.center,
                            style: AppTypography.displayMd),
                        const SizedBox(height: 8),
                        Text(
                          reason == DisconnectedReason.forced
                              ? 'The desk ended this session — the pairing was '
                                  'revoked or has expired. Scan a new QR from the '
                                  'admin desktop to continue.'
                              : 'The desk turned this device away — the pairing '
                                  'expired, was revoked, or the account was '
                                  'switched off. Wi-Fi is not the problem.',
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
                          child: Text('ASK THE ADMIN FOR A NEW QR',
                              style: AppTypography.micro.copyWith(
                                color: AppColors.warn,
                                letterSpacing: 1.0,
                              )),
                        ),
                        const SizedBox(height: 24),
                        LiquidPrimaryButton(
                          label: 'Try reconnect',
                          fullWidth: true,
                          leadingIcon: Icons.refresh,
                          onPressed: () => _tryReconnect(context, ref),
                        ),
                        const SizedBox(height: 8),
                        LiquidSecondaryButton(
                          label: 'Scan QR',
                          leadingIcon: Icons.qr_code_scanner,
                          onPressed: () => _confirmScanQr(context, ref),
                        ),
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
