// Connection banner — slides down from top when offline / reconnecting.
//
// Shows a M:SS countdown counting down from 2:00. When it hits 0:00 the user
// is routed to /disconnected — at that point the session is considered stale
// and a fresh QR scan is needed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

class ConnectionBanner extends ConsumerStatefulWidget {
  final Widget child;
  const ConnectionBanner({super.key, required this.child});
  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  Timer? _ticker;
  int _remaining = 120;       // seconds — full 2-min grace window

  @override
  void dispose() { _ticker?.cancel(); super.dispose(); }

  void _startTimer() {
    _ticker?.cancel();
    setState(() => _remaining = 120);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _ticker?.cancel();
        setState(() => _remaining = 0);
        // Move user to the timeout screen — but only once.
        Future.microtask(() {
          if (mounted) context.go('/disconnected');
        });
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
  }

  String get _label {
    if (_remaining <= 0) return 'Reconnect failed';
    final m = _remaining ~/ 60;
    final s = (_remaining % 60).toString().padLeft(2, '0');
    return 'Reconnecting · $m:$s remaining';
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);

    // React to connection state transitions via ref.listen (not in build).
    ref.listen<ConnectionStatus>(connectionProvider, (prev, next) {
      if (prev != null && prev.online && !next.online) {
        _startTimer();
      } else if (prev != null && !prev.online && next.online) {
        _stopTimer();
      }
    });

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0, left: 0, right: 0,
          child: IgnorePointer(
            ignoring: conn.online,
            child: AnimatedSlide(
            offset: conn.online ? const Offset(0, -1.5) : Offset.zero,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: TickerMode(
              enabled: !conn.online,
              child: AnimatedOpacity(
              opacity: conn.online ? 0 : 1,
              duration: const Duration(milliseconds: 220),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: LiquidGlassSurface(
                    borderRadius: const BorderRadius.all(AppRadii.md),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    blur: 24, thickness: 12,
                    tint: AppColors.danger.withValues(alpha: 0.12),
                    child: Row(
                      children: [
                        const _PulseDot(color: AppColors.danger),
                        const SizedBox(width: 10),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Reconnecting…', style: AppTypography.bodyMd.copyWith(
                              color: AppColors.danger, fontWeight: FontWeight.w600)),
                            Text(_label, style: AppTypography.micro.copyWith(
                              color: AppColors.ink70)),
                          ],
                        )),
                        // Countdown ring.
                        SizedBox(
                          width: 32, height: 32,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 32, height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  value: _remaining / 120,
                                  color: AppColors.danger,
                                  backgroundColor: AppColors.ink10,
                                ),
                              ),
                              Text(
                                _remaining > 0 ? '${_remaining ~/ 60}m' : '!',
                                style: AppTypography.micro.copyWith(
                                  color: AppColors.danger, letterSpacing: 0,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        ),  // IgnorePointer
        ),  // Positioned
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
    AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12, height: 12,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          return Stack(alignment: Alignment.center, children: [
            Opacity(
              opacity: (1 - t).clamp(0, 1),
              child: Container(
                width: 12 * (0.6 + t * 0.6),
                height: 12 * (0.6 + t * 0.6),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
            ),
          ]);
        },
      ),
    );
  }
}
