import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/currency.dart';
import '../data/gate_providers.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../models/pay_mode.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import '../services/entry_ticket_service.dart';
import '../services/slip_printer.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/gate/slip_print_button.dart';
import '../widgets/gate/ticket_qr_sheet.dart';
import '../widgets/liquid_chrome.dart';

/// After a sale: its number, what was paid, and one card per ticket with
/// its QR a tap away. Print goes through the slip-printer seam (disabled
/// until a printer is set up; the QR on screen does meanwhile).
///
/// The numbers are shown only when they add up (payments = total, one
/// ticket per unit); otherwise it says so instead of showing wrong ones.
class TicketIssueResultScreen extends ConsumerStatefulWidget {
  const TicketIssueResultScreen({super.key});

  @override
  ConsumerState<TicketIssueResultScreen> createState() =>
      _TicketIssueResultScreenState();
}

class _TicketIssueResultScreenState
    extends ConsumerState<TicketIssueResultScreen> {
  @override
  void initState() {
    super.initState();
    if (ref.read(ticketIssueResultProvider) != null) {
      ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    }
  }

  String _modeLabel(String code, String? printName) {
    if (printName != null && printName.isNotEmpty) return printName;
    for (final mode in <PayMode>[
      ...PayMode.builtIns,
      ...ref.read(listedPayModesProvider),
    ]) {
      if (mode.code == code) return mode.label;
    }
    return code;
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(ticketIssueResultProvider);
    final palette = context.palette;
    final problem = result == null ? null : ticketSaleProblem(result);

    final Widget body;
    if (result == null) {
      body = Center(
        child: Text('No sale to show', style: palette.caption),
      );
    } else if (problem != null) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppCard(
            background: AppColors.danger.withValues(alpha: 0.08),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
            child: const Text(kIssueUnreadable, style: AppTypography.bodyMd),
          ),
        ],
      );
    } else {
      final sale = result.sale;
      final totals = sale.totals;
      final entry = totals.total - totals.coverTotal;
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.check_circle_rounded,
                      color: AppColors.success, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${result.tickets.length} '
                      '${result.tickets.length == 1 ? 'ticket' : 'tickets'} issued',
                      style: AppTypography.title,
                    ),
                  ),
                  Text(formatRupees(totals.total),
                      style: AppTypography.headline),
                ]),
                if (sale.saleNumber.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(sale.saleNumber, style: palette.caption),
                ],
                const SizedBox(height: 10),
                _Line(label: 'Entry (GST incl.)', amount: formatRupees(entry)),
                if (totals.coverTotal.isPositive)
                  _Line(
                      label: 'Cover for food & drinks today',
                      amount: formatRupees(totals.coverTotal)),
                Divider(height: 16, color: palette.ink10),
                for (final p in sale.payments)
                  _Line(
                      label: _modeLabel(p.mode, p.printName),
                      amount: formatRupees(p.amount)),
                if (sale.guestName != null || sale.guestPhoneLast4 != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (sale.guestName != null) sale.guestName!,
                      if (sale.guestPhoneLast4 != null)
                        '•••• ${sale.guestPhoneLast4}',
                    ].join(' · '),
                    style: palette.caption,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('TICKETS',
              style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
          const SizedBox(height: 8),
          for (final ticket in result.tickets) ...[
            _TicketCard(ticket: ticket),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Center(
            child: SlipPrintButton(slips: <TicketSlip>[
              for (final ticket in result.tickets)
                TicketSlip.fromTicket(ticket),
            ]),
          ),
        ],
      );
    }

    return ColoredBox(
      color: palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  Expanded(
                    child: Text('Tickets issued',
                        style: AppTypography.sheetTitle),
                  ),
                ]),
              ),
              Expanded(child: body),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    16, 8, 16, 12 + context.sheetBottomInset),
                child: Row(children: [
                  Expanded(
                    child: LiquidSecondaryButton(
                      label: 'Done',
                      onPressed: () => context.go('/gate'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LiquidPrimaryButton(
                      key: const ValueKey<String>('result-new-sale'),
                      label: 'New sale',
                      leadingIcon: Icons.add,
                      fullWidth: true,
                      onPressed: () => context.go('/gate/issue'),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.amount});

  final String label;
  final String amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: AppTypography.bodyMd)),
        Text(amount, style: AppTypography.bodyMd),
      ]),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket});

  final EntryTicket ticket;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final qr = ticket.slip?.qrData ?? ticket.qrCode;
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ticket.ticketNumber,
                  style: AppTypography.title.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    ticket.typeName,
                    'Admits ${ticket.pax}',
                    if (ticket.coverAmount.isPositive)
                      'Cover ${formatRupeesCompact(ticket.coverAmount)}',
                  ].join(' · '),
                  style: palette.caption,
                ),
              ],
            ),
          ),
          LiquidSecondaryButton(
            key: ValueKey<String>('show-qr-${ticket.id}'),
            label: 'Show QR',
            leadingIcon: Icons.qr_code_2,
            onPressed: () => showTicketQrSheet(
              context,
              ticketId: ticket.id,
              qrData: qr,
              ticketNumber: ticket.ticketNumber,
              typeName: ticket.typeName,
              slip: ticket.slip,
            ),
          ),
        ],
      ),
    );
  }
}
