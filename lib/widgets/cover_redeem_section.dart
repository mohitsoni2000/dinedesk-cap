import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../services/entry_ticket_service.dart';
import '../services/log.dart';
import '../services/offline_guard.dart';
import '../theme/tokens.dart';
import '../utils/tender_allocation.dart';
import 'app_surface.dart';
import 'qr_capture.dart';

/// "Cover ticket": take a guest's entry-ticket cover as payment. Scan or type
/// the ticket, the desk says what it has left, and it is applied up to what
/// cover may still pay here. Several tickets can stack; one ticket only once.
///
/// The screen owns the list: [onAdd] / [onRemove] change it, [covers] shows
/// it. The payment sheet shows it only when the user may redeem cover
/// (`canRedeemCover`).
class CoverRedeemSection extends ConsumerStatefulWidget {
  final List<AppliedCover> covers;

  /// What cover may still pay here: the open food and drink bills' due, less
  /// cover already applied, within what is still to collect.
  final Money coverable;
  final ValueChanged<AppliedCover> onAdd;
  final ValueChanged<AppliedCover> onRemove;
  final bool enabled;

  const CoverRedeemSection({
    super.key,
    required this.covers,
    required this.coverable,
    required this.onAdd,
    required this.onRemove,
    this.enabled = true,
  });

  @override
  ConsumerState<CoverRedeemSection> createState() => _CoverRedeemSectionState();
}

class _CoverRedeemSectionState extends ConsumerState<CoverRedeemSection> {
  bool _looking = false;
  String? _refusal;

  Future<void> _add() async {
    if (_looking) return;
    setState(() => _refusal = null);
    final code = await QrCapture.show(context,
        title: 'Cover ticket', hint: 'Ticket number or QR code');
    if (code == null || !mounted) return;
    if (!requireDesk(context, ref)) return;
    setState(() => _looking = true);
    final outcome = await ref.read(entryTicketServiceProvider).lookup(code);
    if (!mounted) return;
    final decision = switch (outcome) {
      TicketLookupFailed(:final message) => CoverRefused(message),
      TicketFound(:final result, :final message) => decideCover(
          lookup: result,
          entered: code,
          existing: widget.covers,
          coverable: widget.coverable,
          deskMessage: message,
        ),
    };
    logD('[Cover]',
        '${decision is CoverAccepted ? 'added' : 'refused'} a ticket; ${widget.covers.length} on this payment before');
    setState(() {
      _looking = false;
      _refusal = decision is CoverRefused ? decision.message : null;
    });
    if (decision is CoverAccepted) widget.onAdd(decision.cover);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return IgnorePointer(
      ignoring: !widget.enabled,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Text('COVER TICKET',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
            const SizedBox(height: 8),
            for (final cover in widget.covers)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: AppSurface(
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shadow: const [],
                  child: Row(children: [
                    Icon(Icons.confirmation_number_outlined,
                        size: 16, color: palette.ink70),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${cover.ticketNumber} · ${cover.typeName}',
                          style: AppTypography.bodyMd,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text('−${formatRupeesCompact(cover.amount)}',
                        style: AppTypography.bodyMd
                            .copyWith(fontWeight: FontWeight.w600)),
                    IconButton(
                      tooltip: 'Remove ${cover.ticketNumber}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => _refusal = null);
                        widget.onRemove(cover);
                      },
                      icon: const Icon(Icons.close,
                          size: 16, color: AppColors.danger),
                    ),
                  ]),
                ),
              ),
            GestureDetector(
              onTap: _looking ? null : _add,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: palette.hairline),
                ),
                child: Row(children: [
                  if (_looking)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(Icons.qr_code_scanner, size: 16, color: palette.ink70),
                  const SizedBox(width: 8),
                  Text(_looking ? 'Checking the ticket…' : 'Add cover ticket',
                      style: AppTypography.bodyMd
                          .copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            if (_refusal != null) ...[
              const SizedBox(height: 6),
              Text(_refusal!,
                  style:
                      AppTypography.caption.copyWith(color: AppColors.danger)),
            ],
          ],
        ),
      ),
    );
  }
}
