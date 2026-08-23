import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';

class ReadyOrdersBanner extends ConsumerWidget {
  final Widget child;
  const ReadyOrdersBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(readyOrdersProvider);

    return Stack(
      children: [
        child,
        if (ready.isNotEmpty)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _ReadyCard(
                  ticket: ready.first,
                  extra: ready.length - 1,
                  onDismiss: () {
                    final list = ref.read(readyOrdersProvider);
                    ref.read(readyOrdersProvider.notifier).state =
                        list.skip(1).toList();
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReadyCard extends StatefulWidget {
  final ReadyTicket ticket;
  final int extra;
  final VoidCallback onDismiss;
  const _ReadyCard({
    required this.ticket,
    required this.extra,
    required this.onDismiss,
  });

  @override
  State<_ReadyCard> createState() => _ReadyCardState();
}

class _ReadyCardState extends State<_ReadyCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppPerf.reduceEffects(context)) {
      _wiggle.stop();
    } else if (!_wiggle.isAnimating) {
      _wiggle.repeat();
    }
  }

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.palette.alertDeep,
        borderRadius: BorderRadius.all(AppRadii.md),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _wiggle,
            builder: (_, child) {
              final t = _wiggle.value;

              final wiggle = t < 0.5
                  ? (t < 0.125
                      ? t * 8
                      : t < 0.375
                          ? 1 - (t - 0.125) * 8
                          : (t - 0.375) * 8 - 1)
                  : 0.0;
              return Transform.rotate(angle: wiggle * 0.18, child: child);
            },
            child: const Icon(Icons.notifications_active,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Food ready · ${widget.ticket.tableName}',
                  style: AppTypography.bodyMd.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (widget.ticket.itemLabels.isNotEmpty)
                  Text(
                    widget.ticket.itemLabels.join(' · '),
                    style: AppTypography.micro.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (widget.extra > 0)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '+${widget.extra}',
                style: AppTypography.micro.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 8),
          Material(
            color: Colors.white,
            borderRadius: const BorderRadius.all(AppRadii.sm),
            child: InkWell(
              onTap: widget.onDismiss,
              borderRadius: const BorderRadius.all(AppRadii.sm),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  'Serve',
                  style: AppTypography.caption.copyWith(
                    color: context.palette.alertDeep,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
