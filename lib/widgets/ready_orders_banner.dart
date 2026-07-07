// Ready-to-serve banner — overlays the app shell when the kitchen bumps a
// round for an order this device owns. Tap to dismiss the most recent ticket.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';

/// Wraps the app shell and shows a top banner whenever there are
/// ready-to-serve tickets for this device. Tap the banner to dismiss
/// the most recent ticket.
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

class _ReadyCard extends StatelessWidget {
  final ReadyTicket ticket;
  final int extra;
  final VoidCallback onDismiss;
  const _ReadyCard({
    required this.ticket,
    required this.extra,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDismiss,
        borderRadius: const BorderRadius.all(AppRadii.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: const BoxDecoration(
            color: AppColors.success,
            borderRadius: BorderRadius.all(AppRadii.md),
            boxShadow: [
              BoxShadow(
                color: AppColors.scrim,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.restaurant, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Food ready · ${ticket.tableName}',
                      style: AppTypography.bodyMd.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (ticket.itemLabels.isNotEmpty)
                      Text(
                        ticket.itemLabels.join(' · '),
                        style: AppTypography.micro.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (extra > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '+$extra',
                    style: AppTypography.micro.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              const Icon(Icons.close, color: Colors.white, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
