import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/gate_providers.dart';
import '../data/parked_providers.dart';
import '../data/providers.dart';
import '../models/parked_draft.dart';
import '../services/offline_guard.dart';
import '../services/pending_slips_store.dart';
import '../services/slip_printer.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/gate/gate_offline_strip.dart';
import '../widgets/gate/ticket_park_actions.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/slip_queue_sheet.dart';

/// Gate home: sell entry tickets, check guests in, today's tickets, and the
/// sales parked on this phone. Each tile shows only for the user's rights.
/// Without the desk nothing is sold or checked in, and it says so.
class GateScreen extends ConsumerWidget {
  const GateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(flagsProvider);
    final canIssue = flags.entryTickets && flags.ticketIssue;
    final canCheckIn = flags.entryTickets && flags.ticketCheckin;
    final parked = ref.watch(parkedCountProvider(ParkedKind.ticketIssue));
    final pending = ref.watch(pendingTicketIssueProvider);
    final printer = ref.watch(slipPrinterProvider);
    final unprinted = ref.watch(unprintedSlipsProvider).length;
    // Rebuilt when the link drops or returns; read on every build.
    ref.watch(connectionProvider.select((c) => c.online));
    final offline = isDeskOffline(ref);
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
                Row(
                  children: [
                    const Expanded(
                      child: Text('Gate', style: AppTypography.displayLg),
                    ),
                    _PrinterChip(ready: printer.isReady),
                  ],
                ),
                const SizedBox(height: 16),
                if (offline) ...[
                  const GateOfflineStrip(
                      message: "Desk unreachable – can't sell tickets or "
                          'verify entries'),
                  const SizedBox(height: 12),
                ],
                if (pending != null) ...[
                  AppCard(
                    onTap: () => context.push('/gate/issue'),
                    background: AppColors.amber.withValues(alpha: 0.10),
                    border: Border.all(
                        color: AppColors.amber.withValues(alpha: 0.4)),
                    child: Row(children: [
                      const Icon(Icons.sync_problem_outlined,
                          color: AppColors.warn, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'The last ticket sale was not confirmed — check it '
                          'before the next sale',
                          style: AppTypography.bodyMd
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: palette.ink50),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (unprinted > 0) ...[
                  AppCard(
                    key: const ValueKey<String>('gate-unprinted'),
                    onTap: () => SlipQueueSheet.show(context),
                    child: Row(children: [
                      const Icon(Icons.receipt_long_outlined,
                          color: AppColors.warn, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$unprinted ${unprinted == 1 ? 'slip' : 'slips'} '
                          'not printed',
                          style: AppTypography.bodyMd
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: palette.ink50),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (canIssue) ...[
                  _GateTile(
                    key: const ValueKey<String>('gate-issue'),
                    icon: Icons.confirmation_number_outlined,
                    title: 'Issue tickets',
                    detail: 'Sell entry and cover tickets',
                    primary: true,
                    onTap: () => context.push('/gate/issue'),
                  ),
                  const SizedBox(height: 12),
                ],
                if (canCheckIn) ...[
                  _GateTile(
                    key: const ValueKey<String>('gate-scan'),
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Scan entry',
                    detail: 'Check guests in by their ticket QR',
                    primary: !canIssue,
                    onTap: () => context.push('/gate/scan'),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      child: _GateTile(
                        key: const ValueKey<String>('gate-recent'),
                        icon: Icons.history_rounded,
                        title: 'Recent',
                        detail: "Today's tickets",
                        onTap: () => context.push('/gate/recent'),
                      ),
                    ),
                    if (canIssue) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: _GateTile(
                          key: const ValueKey<String>('gate-parked'),
                          icon: Icons.bookmark_outline,
                          title: 'Parked ($parked)',
                          detail: parked == 0
                              ? 'Nothing parked'
                              : 'Tap to resume one',
                          onTap: parked == 0
                              ? null
                              : () async {
                                  final resumed =
                                      await resumeTicketSale(context, ref);
                                  if (resumed && context.mounted) {
                                    await context.push('/gate/issue');
                                  }
                                },
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GateTile extends StatelessWidget {
  const _GateTile({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AppCard(
      onTap: onTap,
      background: primary ? palette.terraSoft : null,
      padding: EdgeInsets.all(primary ? 18 : 14),
      child: Row(
        children: [
          Icon(icon,
              size: primary ? 30 : 22,
              color: primary ? AppColors.terraDeep : palette.ink70),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: (primary ? AppTypography.title : AppTypography.bodyMd)
                        .copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: palette.caption),
              ],
            ),
          ),
          if (onTap != null) Icon(Icons.chevron_right, color: palette.ink30),
        ],
      ),
    );
  }
}

/// Whether slips can be printed here; a tap opens the printer settings.
/// Without a printer each ticket's QR is shown on screen instead.
class _PrinterChip extends StatelessWidget {
  const _PrinterChip({required this.ready});

  final bool ready;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return GestureDetector(
      onTap: () => context.push('/printer-settings'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: ready
              ? AppColors.success.withValues(alpha: 0.12)
              : palette.ink05,
          borderRadius: const BorderRadius.all(AppRadii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ready ? Icons.print_outlined : Icons.print_disabled_outlined,
              size: 16, color: ready ? AppColors.success : palette.ink50),
          const SizedBox(width: 6),
          Text(ready ? 'Printer ready' : 'No printer',
              style: AppTypography.caption
                  .copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
