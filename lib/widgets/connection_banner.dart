import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../services/link_monitor.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';

/// Connection status as quiet, non-blocking pills at the top of the screen.
///
/// This used to be a full-width "Reconnecting…" banner that appeared the
/// instant the socket blinked and ran a 15-minute countdown ending in a
/// redirect to "scan the QR again". On restaurant Wi-Fi the socket blinks all
/// the time, so the banner flickered constantly and the countdown eventually
/// threw operators out of a perfectly recoverable session. Now:
///
/// - nothing is shown for a brief blip (each pill is debounced);
/// - nothing ever navigates away or blocks input — the app keeps working and
///   the outbox keeps the operator's orders safe;
/// - there is no deadline: the connection layer never gives up, so neither does
///   the UI. The only way to the "scan again" screen is the desk actually
///   refusing this device (see DisconnectedScreen).
class ConnectionBanner extends ConsumerStatefulWidget {
  final Widget child;
  const ConnectionBanner({super.key, required this.child});
  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  /// Suspect for this long before "Weak connection" appears.
  static const Duration weakAfter = Duration(seconds: 3);

  /// Disconnected for this long before "Offline" appears.
  static const Duration offlineAfter = Duration(milliseconds: 2500);

  bool _showWeak = false;
  bool _showOffline = false;
  Timer? _weakTimer;
  Timer? _offlineTimer;

  @override
  void initState() {
    super.initState();
    // Whatever is already true when this banner mounts (it is rebuilt per
    // route) starts its debounce now rather than waiting for a change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncOffline(ref.read(connectionProvider).online);
      _syncWeak(ref.read(linkHealthProvider));
    });
  }

  @override
  void dispose() {
    _weakTimer?.cancel();
    _offlineTimer?.cancel();
    super.dispose();
  }

  void _syncOffline(bool online) {
    _offlineTimer?.cancel();
    if (online) {
      if (_showOffline) setState(() => _showOffline = false);
      return;
    }
    if (_showOffline) return;
    _offlineTimer = Timer(offlineAfter, () {
      if (mounted) setState(() => _showOffline = true);
    });
  }

  void _syncWeak(LinkHealth health) {
    _weakTimer?.cancel();
    if (health != LinkHealth.suspect) {
      if (_showWeak) setState(() => _showWeak = false);
      return;
    }
    if (_showWeak) return;
    _weakTimer = Timer(weakAfter, () {
      if (mounted) setState(() => _showWeak = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(connectionProvider.select((c) => c.online),
        (_, online) => _syncOffline(online));
    ref.listen<LinkHealth>(linkHealthProvider, (_, h) => _syncWeak(h));

    final online = ref.watch(connectionProvider.select((c) => c.online));
    final stale = ref.watch(isFloorDataStaleProvider);
    final queued = ref.watch(outboxPendingCountProvider);

    // Offline outranks weak: a dead link is not also "weak".
    final pills = <Widget>[
      if (_showOffline && !online)
        _StatusPill(
          key: const ValueKey('offline'),
          color: AppColors.danger,
          pulse: true,
          title: queued > 0 ? 'Offline · $queued queued' : 'Offline',
          subtitle: queued > 0
              ? 'Orders are saved and will send when the desk is back'
              : 'Reconnecting automatically…',
          actionLabel: 'Retry now',
          onAction: () => ref.read(connectionSupervisorProvider).retryNow(),
        )
      else if (_showWeak && online)
        const _StatusPill(
          key: ValueKey('weak'),
          color: AppColors.warn,
          pulse: true,
          title: 'Weak connection',
          subtitle: 'Still working — checking the link',
        ),
      if (stale && (!online || _showOffline))
        const _StatusPill(
          key: ValueKey('stale'),
          color: AppColors.warn,
          title: 'Showing saved data',
          subtitle: 'May be out of date until the desk is back',
        ),
    ];

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final pill in pills)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: pill,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final Color color;
  final bool pulse;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StatusPill({
    super.key,
    required this.color,
    required this.title,
    required this.subtitle,
    this.pulse = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '$title. $subtitle',
      child: AppSurface(
        borderRadius: const BorderRadius.all(AppRadii.md),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        tint: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        child: Row(
          children: [
            pulse ? _PulseDot(color: color) : _StaticDot(color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTypography.bodyMd
                          .copyWith(color: color, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: AppTypography.micro
                          .copyWith(color: context.palette.ink70)),
                ],
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: 8),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAction,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  child: Container(
                    constraints: const BoxConstraints(
                        minHeight: AppTouchTargets.minimum),
                    alignment: Alignment.center,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                    ),
                    child: Text(
                      actionLabel!,
                      style: AppTypography.caption.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
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

class _StaticDot extends StatelessWidget {
  final Color color;
  const _StaticDot({required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 12,
        height: 12,
        child: Center(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      );
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
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppPerf.reduceEffects(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

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
