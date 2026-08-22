import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/connection_bootstrap.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';

/// CC-LAT-010: a pure view over [connectionBootstrapProvider] — every
/// connect/rediscovery/resume decision lives in `connection_bootstrap.dart`
/// now, started from `main()` well before this screen ever mounts. This
/// class owns nothing but the spinner animation and navigating on terminal
/// outcomes.
class ConnectingScreen extends ConsumerStatefulWidget {
  const ConnectingScreen({super.key});
  @override
  ConsumerState<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends ConsumerState<ConnectingScreen>
    with SingleTickerProviderStateMixin {
  static const _stages = <String>[
    'Reaching the POS server',
    'Securing the session',
    'Loading restaurant data',
  ];

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  Future<void> _cancelToScan() =>
      ref.read(connectionBootstrapProvider.notifier).cancelToScan();

  void _retry() => ref.read(connectionBootstrapProvider.notifier).retry();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<BootstrapOutcome>(connectionBootstrapProvider, (_, next) {
      if (!mounted) return;
      if (next is BootstrapResumed) {
        context.go('/tables');
      } else if (next is BootstrapNeedsAuth) {
        context.go('/auth');
      } else if (next is BootstrapNoPairing) {
        // Cancel-to-scan, or a rejected/failed pairing that was cleared.
        context.go('/scan');
      }
    });
    final outcome = ref.watch(connectionBootstrapProvider);

    final pairing = switch (outcome) {
      BootstrapConnecting(:final pairing) => pairing,
      BootstrapRediscovering(:final pairing) => pairing,
      _ => null,
    };
    final stage = outcome is BootstrapConnecting ? outcome.stage : 0;
    final errorMsg = outcome is BootstrapConnecting ? outcome.errorMsg : null;
    final failed =
        outcome is BootstrapFailed || outcome is BootstrapPairingRejected;
    final pairingRejected = outcome is BootstrapPairingRejected;

    final host = pairing?.host ?? '';
    final port = pairing?.port;
    final isDemo = pairing?.token == 'demo-token';

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: AppSurface(
                borderRadius: const BorderRadius.all(AppRadii.lg),
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Hero(
                      tag: HeroTags.pairingCore,
                      child: SizedBox(
                        width: 96,
                        height: 96,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (!failed) _PulseRing(),
                            RotationTransition(
                              turns: failed
                                  ? const AlwaysStoppedAnimation(0)
                                  : _spin,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: failed
                                      ? AppColors.terraDeep
                                      : AppColors.terra500,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  // A wifi-off glyph beside "Wi-Fi is not the
                                  // problem" is the same mixed signal this
                                  // screen is meant to stop sending.
                                  pairingRejected
                                      ? Icons.link_off_rounded
                                      : failed
                                          ? Icons.wifi_off_rounded
                                          : Icons.wifi_tethering,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (failed) ...[
                      Text(
                          pairingRejected
                              ? 'This device needs pairing again'
                              : "Can't reach the server",
                          style: AppTypography.displayMd,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: pairingRejected
                              ? const [
                                  _ChecklistItem(
                                      text:
                                          'The desk turned this device away — the pairing has expired, was revoked, or the account was switched off.'),
                                  _ChecklistItem(
                                      text:
                                          'Wi-Fi is not the problem. Retrying will not help.'),
                                  _ChecklistItem(
                                      text:
                                          'Ask the admin to open Devices on the desktop and show you a fresh QR.'),
                                ]
                              : const [
                                  _ChecklistItem(
                                      text:
                                          'Is this phone on the same Wi-Fi as the desktop?'),
                                  _ChecklistItem(
                                      text:
                                          'Is the Restro POS app running on the desktop?'),
                                  _ChecklistItem(
                                      text:
                                          'QR codes expire — ask the admin for a fresh one.'),
                                ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (pairingRejected)
                        SizedBox(
                          width: double.infinity,
                          child: _CardButton(
                            label: 'Scan new QR',
                            filled: true,
                            onTap: _cancelToScan,
                          ),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: _CardButton(
                                label: 'Scan new QR',
                                filled: false,
                                onTap: _cancelToScan,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _CardButton(
                                label: 'Try again',
                                filled: true,
                                onTap: _retry,
                              ),
                            ),
                          ],
                        ),
                    ] else ...[
                      Text('CONNECTING TO',
                          style: AppTypography.micro
                              .copyWith(color: context.palette.ink50)),
                      const SizedBox(height: 4),
                      Text(
                        host.isEmpty ? '—' : (isDemo ? 'Demo Kitchen' : host),
                        style: AppTypography.tableName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isDemo
                            ? 'Local sandbox · no server needed'
                            : 'Port ${port ?? '—'} · Restro POS',
                        style: context.palette.caption,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (errorMsg != null) ...[
                        const SizedBox(height: 8),
                        Text(errorMsg,
                            style: AppTypography.caption
                                .copyWith(color: AppColors.warn),
                            textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      Column(
                        children: [
                          for (int i = 0; i < _stages.length; i++) ...[
                            _StageRow(
                              label: _stages[i],
                              done: i < stage,
                              active: i == stage,
                            ),
                            if (i < _stages.length - 1)
                              const SizedBox(height: 6),
                          ],
                        ],
                      ),
                      const SizedBox(height: 20),
                      // This was a bare `Pressable(child: Text('Cancel'))` —
                      // a tap target the size of 12px of text, roughly
                      // 60x16pt, against this app's own declared minimum of
                      // 48. It is also the *only* way out while the connect
                      // is still spinning: the "Scan new QR / Try again" pair
                      // above only appears once it has given up. A waiter
                      // whose Wi-Fi died mid-shift is stuck on this screen
                      // until they hit it, one-handed, in a hurry.
                      SizedBox(
                        width: double.infinity,
                        child: _CardButton(
                          label: 'Cancel',
                          filled: false,
                          onTap: _cancelToScan,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  final String text;
  const _ChecklistItem({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ',
              style: AppTypography.caption.copyWith(color: AppColors.terra)),
          Expanded(
            child: Text(text,
                style: AppTypography.caption
                    .copyWith(color: context.palette.ink70)),
          ),
        ],
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _CardButton(
      {required this.label, required this.filled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        // Padding alone left this at ~46px, and it shrinks further at small
        // text scales. The floor is explicit now.
        constraints: const BoxConstraints(
          minHeight: AppTouchTargets.minimum,
        ),
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? context.palette.ink : Colors.transparent,
          borderRadius: const BorderRadius.all(AppRadii.md),
          border: filled ? null : Border.all(color: context.palette.hairline),
        ),
        child: Text(
          label,
          style: AppTypography.bodyMd.copyWith(
            color: filled ? Colors.white : context.palette.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatefulWidget {
  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();
  late final Animation<double> _curved =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (_, __) {
        final t = _curved.value;
        return Container(
          width: 96 * (0.6 + t * 0.4),
          height: 96 * (0.6 + t * 0.4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.terra400
                  .withValues(alpha: (1 - t).clamp(0, 1) * 0.6),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

class _StageRow extends StatelessWidget {
  final String label;
  final bool done;
  final bool active;
  const _StageRow(
      {required this.label, required this.done, required this.active});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? AppColors.success
                : active
                    ? context.palette.terraSoft
                    : context.palette.ink05,
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : active
                  ? const Center(
                      child: SizedBox(
                        width: 8,
                        height: 8,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppColors.terra,
                        ),
                      ),
                    )
                  : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: AppTypography.bodyMd.copyWith(
              color: done ? context.palette.ink70 : context.palette.ink,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
