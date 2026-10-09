import 'package:flutter/material.dart';

import '../../controllers/gate_scan_controller.dart';
import '../../data/currency.dart';
import '../../models/entry_ticket.dart';
import '../../theme/tokens.dart';
import '../liquid_chrome.dart';

/// The colour of a gate answer.
Color gateToneColor(GateTone tone) => switch (tone) {
      GateTone.green => AppColors.success,
      GateTone.red => AppColors.danger,
      GateTone.amber => AppColors.warn,
    };

IconData _iconFor(GateScanCard card) => switch (card.kind) {
      GateCardKind.answer => switch (card.tone) {
          GateTone.green => Icons.check_circle_rounded,
          GateTone.red => Icons.block_rounded,
          GateTone.amber => Icons.error_outline_rounded,
        },
      GateCardKind.notTicket => Icons.qr_code_2_rounded,
      GateCardKind.refused => Icons.error_outline_rounded,
      GateCardKind.unconfirmed => Icons.sync_problem_rounded,
    };

/// A gate answer, full screen in its tone: the headline big enough to read
/// at arm's length, then the ticket. An unanswered check-in offers Retry
/// and Drop; anything else goes away on a tap (or by itself).
class CheckInCardView extends StatelessWidget {
  const CheckInCardView({
    super.key,
    required this.card,
    this.onDismiss,
    this.onRetry,
    this.onDrop,
    this.busy = false,
  });

  final GateScanCard card;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetry;
  final VoidCallback? onDrop;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = gateToneColor(card.tone);
    final ticket = card.result?.ticket;
    final unconfirmed = card.kind == GateCardKind.unconfirmed;
    final details = <String>[
      if (ticket != null) '${ticket.ticketNumber} · ${ticket.typeName}',
      if (ticket?.guestName != null) ticket!.guestName!,
      if (ticket != null &&
          card.result?.outcome == CheckInOutcome.valid &&
          ticket.coverBalance.isPositive)
        'Cover ${formatRupeesCompact(ticket.coverBalance)} to spend today',
      if (card.detail != null) card.detail!,
    ];
    return GestureDetector(
      key: const ValueKey<String>('gate-card'),
      behavior: HitTestBehavior.opaque,
      onTap: unconfirmed ? null : onDismiss,
      child: ColoredBox(
        color: color,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              children: [
                const Spacer(),
                Icon(_iconFor(card), color: Colors.white, size: 96),
                const SizedBox(height: 20),
                Text(
                  card.headline,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: AppTypography.inter,
                    fontSize: 34,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                for (final line in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      line,
                      textAlign: TextAlign.center,
                      style: AppTypography.title.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const Spacer(),
                if (unconfirmed)
                  Row(children: [
                    Expanded(
                      child: LiquidSecondaryButton(
                        label: 'Drop it',
                        leadingIcon: Icons.delete_outline,
                        onPressed: busy ? null : onDrop,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LiquidPrimaryButton(
                        label: busy ? 'Checking…' : 'Retry',
                        leadingIcon: Icons.refresh,
                        fullWidth: true,
                        onPressed: busy ? null : onRetry,
                      ),
                    ),
                  ])
                else
                  Text(
                    'Tap for the next guest',
                    style: AppTypography.bodyMd.copyWith(
                        color: Colors.white.withValues(alpha: 0.85)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
