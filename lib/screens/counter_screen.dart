import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/counter_providers.dart';
import '../data/currency.dart';
import '../data/parked_providers.dart';
import '../data/providers.dart';
import '../models/parked_draft.dart';
import '../models/token.dart';
import '../services/offline_order_queue_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/counter_notices.dart';
import '../widgets/counter_park_actions.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/token_badge.dart';

/// Counter home: table-less ordering with daily tokens, the home tab on a QSR
/// desk. A new order, the carts parked on this phone, the orders queued
/// while the desk was away, and today's open tokens (or open orders, with
/// tokens off), live from the desk's broadcasts.
class CounterScreen extends ConsumerWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A queued order landing says "Q-3 → Token #42", wherever the cashier is.
    ref.watch(counterReplayWatcherProvider);
    final parked = ref.watch(parkedCountProvider(ParkedKind.counterCart));
    final queued = ref.watch(queuedCounterOrdersProvider).valueOrNull ??
        const <QueuedCounterOrder>[];
    final tokens = ref.watch(flagsProvider.select((f) => f.orderTokens));
    final open = ref.watch(openCounterOrdersProvider);
    final pending = ref.watch(pendingCheckoutProvider);
    final palette = context.palette;

    return ColoredBox(
      color: palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: PageContentClamp(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                const CounterNotices(),
                const Text('Counter', style: AppTypography.displayLg),
                const SizedBox(height: 16),
                if (pending != null) ...[
                  AppCard(
                    onTap: () => context.push('/counter/order/checkout'),
                    background: AppColors.amber.withValues(alpha: 0.10),
                    border: Border.all(
                        color: AppColors.amber.withValues(alpha: 0.4)),
                    child: Row(children: [
                      const Icon(Icons.sync_problem_outlined,
                          color: AppColors.warn, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'The last Pay & Fire was not confirmed — check it '
                          'before the next charge',
                          style: AppTypography.bodyMd
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: palette.ink50),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                LiquidPrimaryButton(
                  label: 'New order',
                  leadingIcon: Icons.add_shopping_cart,
                  fullWidth: true,
                  onPressed: () => context.push('/counter/order'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _CountCard(
                        icon: Icons.bookmark_outline,
                        title: 'Parked',
                        count: parked,
                        detail: parked == 0
                            ? 'Nothing parked'
                            : 'Tap to resume one',
                        onTap: parked == 0
                            ? null
                            : () async {
                                final resumed =
                                    await resumeCounterCart(context, ref);
                                if (resumed && context.mounted) {
                                  await context.push('/counter/order');
                                }
                              },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _CountCard(
                        icon: Icons.cloud_upload_outlined,
                        title: 'Queued',
                        count: queued.length,
                        detail: queued.isEmpty
                            ? 'Nothing waiting'
                            : queued.map((q) => q.localRef).take(4).join(' · '),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(tokens ? 'OPEN TOKENS' : 'OPEN ORDERS',
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                const SizedBox(height: 8),
                if (open.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      tokens ? 'No open tokens' : 'No open counter orders',
                      textAlign: TextAlign.center,
                      style: palette.caption,
                    ),
                  )
                else
                  for (final order in open) ...[
                    _OpenOrderTile(order: order, tokens: tokens),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.icon,
    required this.title,
    required this.count,
    required this.detail,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final int count;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: palette.ink70),
            const SizedBox(width: 6),
            Expanded(child: Text(title, style: AppTypography.bodyMd)),
            Text('$count',
                style: AppTypography.headline.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ])),
          ]),
          const SizedBox(height: 4),
          Text(detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: palette.caption),
        ],
      ),
    );
  }
}

/// One open token (or, with tokens off, one open counter order).
class _OpenOrderTile extends StatelessWidget {
  const _OpenOrderTile({required this.order, required this.tokens});

  final HistoryOrder order;
  final bool tokens;

  @override
  Widget build(BuildContext context) {
    final label = order.tokenLabel;
    final fulfillment = order.fulfillmentType;
    final paid = order.status == OrderStatus.paid;
    return AppCard(
      onTap: () => context.push('/history/${order.id}'),
      child: Row(
        children: [
          if (tokens && label != null)
            TokenBadge(
              label: label,
              status: order.tokenStatus ?? TokenStatus.unknown,
              showStatus: true,
            )
          else
            Text(order.id,
                style:
                    AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              [
                if (fulfillment != null) fulfillment.label,
                '${order.itemCount} items',
                paid ? 'Paid' : 'Pay at pickup',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.palette.caption,
            ),
          ),
          Text(formatRupeesCompact(order.total),
              style:
                  AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
