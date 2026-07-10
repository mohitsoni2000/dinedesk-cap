

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';

class ConnectionBanner extends ConsumerStatefulWidget {
  final Widget child;
  const ConnectionBanner({super.key, required this.child});
  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  static const _reconnectWindowSeconds = 15 * 60;

  Timer? _ticker;
  int _remaining = _reconnectWindowSeconds;
  FeedbackService? _feedbackSvc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feedbackSvc = ref.read(feedbackServiceProvider);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _ticker?.cancel();
    setState(() => _remaining = _reconnectWindowSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _ticker?.cancel();
        setState(() => _remaining = 0);

        Future.microtask(() {
          if (mounted) context.go('/disconnected');
        });
      } else {
        setState(() => _remaining--);
        if (_remaining == 30) {
          _feedbackSvc?.fire(const FeedbackWarning());
        }
      }
    });
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _resetTimer() {
    if (!mounted) return;
    setState(() => _remaining = _reconnectWindowSeconds);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _ticker?.cancel();
        setState(() => _remaining = 0);
        Future.microtask(() {
          if (mounted) context.go('/disconnected');
        });
      } else {
        setState(() => _remaining--);
        if (_remaining == 30) {
          _feedbackSvc?.fire(const FeedbackWarning());
        }
      }
    });
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

    if (!conn.online && _ticker == null && _remaining > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            ref.read(connectionProvider).online ||
            _ticker != null) {
          return;
        }
        _startTimer();
      });
    }

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
            child: SpringBuilder(
              from: conn.online ? 0.0 : 1.0,
              to: conn.online ? 0.0 : 1.0,
              spring: RestroSprings.soft,
              builder: (BuildContext _, double t, Widget? child) {
                return Transform.translate(
                  offset: Offset(0, -1.5 * (1.0 - t) * 100),
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: child,
                  ),
                );
              },
              child: TickerMode(
                enabled: !conn.online,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: AppSurface(
                      borderRadius: const BorderRadius.all(AppRadii.md),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      tint: AppColors.danger.withValues(alpha: 0.12),
                      border: Border.all(
                          color: AppColors.danger.withValues(alpha: 0.3)),
                      child: Row(
                        children: [
                          const _PulseDot(color: AppColors.danger),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Reconnecting…',
                                  style: AppTypography.bodyMd.copyWith(
                                      color: AppColors.danger,
                                      fontWeight: FontWeight.w600)),
                              Text(_label,
                                  style: AppTypography.micro
                                      .copyWith(color: context.palette.ink70)),
                            ],
                          )),

                          SizedBox(
                            width: 32,
                            height: 32,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    value: _remaining / _reconnectWindowSeconds,
                                    color: AppColors.danger,
                                    backgroundColor: context.palette.ink10,
                                  ),
                                ),
                                Text(
                                  _remaining > 0 ? '${_remaining ~/ 60}m' : '!',
                                  style: AppTypography.micro.copyWith(
                                    color: AppColors.danger,
                                    letterSpacing: 0,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _resetTimer,
                              borderRadius: BorderRadius.all(AppRadii.sm),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: AppColors.danger.withValues(alpha: 0.5),
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.all(AppRadii.sm),
                                ),
                                child: Text(
                                  'Stay here',
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.danger,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
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
        ),
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
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
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
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: widget.color, shape: BoxShape.circle),
            ),
          ]);
        },
      ),
    );
  }
}
