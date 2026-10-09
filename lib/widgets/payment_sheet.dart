import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../models/bill_payment.dart';
import '../models/entry_ticket.dart';
import '../models/feature_flags.dart';
import '../models/pay_mode.dart';
import '../models/server_models.dart';
import '../services/entry_ticket_service.dart';
import '../services/log.dart';
import '../services/offline_guard.dart';
import '../services/pin_guard.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../utils/tender_allocation.dart';
import 'app_surface.dart';
import 'cover_redeem_section.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';
import 'tender_form.dart';

class PaymentSheet {
  static Future<bool?> show(
    BuildContext context, {
    required List<ServerBill> bills,
    bool hasCustomer = false,
  }) {
    final grandTotal = bills.map((b) => b.totalAmount).sumMoney();
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _PaymentSheetBody(
        bills: bills,
        grandTotal: grandTotal,
        hasCustomer: hasCustomer,
      ),
    );
  }
}

class _PaymentSheetBody extends ConsumerStatefulWidget {
  final List<ServerBill> bills;
  final Money grandTotal;
  final bool hasCustomer;
  const _PaymentSheetBody({
    required this.bills,
    required this.grandTotal,
    required this.hasCustomer,
  });
  @override
  ConsumerState<_PaymentSheetBody> createState() => _PaymentSheetBodyState();
}

/// The `bill:payment` calls one Pay planned, and the bills they already
/// went through for.
class _PaymentRun {
  _PaymentRun(this.calls);

  final List<BillPaymentCall> calls;
  final Set<String> done = <String>{};
}

/// Why money is still due after a Pay went through in part.
enum _StillDue { coverCapped, partly }

class _PaymentSheetBodyState extends ConsumerState<_PaymentSheetBody> {
  final TenderFormController _tender = TenderFormController();
  final List<AppliedCover> _covers = <AppliedCover>[];

  /// What each bill still owes, as far as this sheet knows: its total until
  /// the desk records a payment on it.
  late final Map<String, Money> _dues = <String, Money>{
    for (final bill in widget.bills) bill.id: bill.totalAmount,
  };
  final Set<String> _settledBillIds = <String>{};

  /// Kept after some bills went through and the next one's answer was lost:
  /// a retry then resends exactly these calls (same payloads, so the same
  /// `client_request_id`s), and the fields stay locked until it lands. When
  /// nothing has gone through, Pay plans again from what is on screen;
  /// unchanged fields plan the same calls, so a retry is still identical.
  _PaymentRun? _pending;
  bool _submitting = false;
  _StillDue? _stillDue;

  @override
  void initState() {
    super.initState();
    _tender.addListener(_onTenderChanged);
  }

  void _onTenderChanged() {
    if (mounted) setState(() {});
  }

  bool get _coverOn =>
      canRedeemCover(ref.read(flagsProvider), ref.read(ticketConfigProvider));

  List<AppliedCover> get _activeCovers =>
      _coverOn ? _covers : const <AppliedCover>[];

  Iterable<ServerBill> get _openBills =>
      widget.bills.where((b) => !_settledBillIds.contains(b.id));

  /// What the open bills still owe.
  Money get _due => _openBills.map((b) => _dues[b.id]!).sumMoney();

  /// What the tenders must cover: the due less the cover applied.
  Money get _tenderDue => _due - _activeCovers.map((c) => c.amount).sumMoney();

  /// What another ticket's cover may still pay: the open food and drink
  /// bills' due less cover applied, within what is still to collect.
  Money _coverable(bool splitMode) {
    final eligible =
        _openBills.where(isCoverEligible).map((b) => _dues[b.id]!).sumMoney() -
            _activeCovers.map((c) => c.amount).sumMoney();
    final left = splitMode && _tender.splits.isNotEmpty
        ? _tenderDue - _tender.splitTotal
        : _tenderDue;
    final cap = eligible < left ? eligible : left;
    return cap.isPositive ? cap : Money.zero;
  }

  List<BillPaymentCall> _plan(FeatureFlags flags) => planBillPayments(
        bills: <PlanBill>[
          for (final bill in _openBills)
            PlanBill(
              id: bill.id,
              billType: bill.billType,
              due: _dues[bill.id]!,
              coverEligible: isCoverEligible(bill),
            ),
        ],
        covers: _activeCovers,
        coverMode: ref.read(ticketConfigProvider).coverPaymentMode,
        tenders:
            _tender.lines(due: _tenderDue, splitMode: flags.splitPayment) ??
                const <TenderLine>[],
      );

  /// Reads back what the desk recorded on [billId]. Cover may have been
  /// taken for less than was sent (the desk caps it at the ticket's balance),
  /// so the bill only counts as settled when the desk says so.
  void _record(String billId, Map<String, dynamic> response) {
    final ack = BillPaymentAck.fromAck(response);
    final left = ack.bill?.id == billId ? ack.remaining : null;
    if (left == null || !left.isPositive) {
      _settledBillIds.add(billId);
      _dues[billId] = Money.zero;
    } else {
      _dues[billId] = left;
    }
  }

  Future<void> _pay() async {
    if (_submitting) return;
    final flags = ref.read(flagsProvider);
    final retrying = _pending != null;
    final coverPaysAll = _activeCovers.isNotEmpty && _tenderDue.isZero;
    if (!retrying && !coverPaysAll) {
      if (_tender.creditBlocked(hasCustomer: widget.hasCustomer)) {
        DynamicToast.show(context,
            message: 'Link a customer before using Credit payment',
            kind: ToastKind.error);
        return;
      }
      final useSplits = flags.splitPayment && _tender.splits.isNotEmpty;
      if (!useSplits && _tender.selected == null) {
        DynamicToast.show(context,
            message: 'Pick a payment mode first', kind: ToastKind.error);
        return;
      }
    }

    if (!requireDesk(context, ref)) return;
    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;

    final run = _pending ?? _PaymentRun(_plan(flags));
    setState(() => _submitting = true);
    final modes = <String>{
      for (final call in run.calls)
        for (final line in call.lines) line.mode,
    };
    logD(
        '[Payment]',
        '${retrying ? 'retrying' : 'paying'} '
            '${run.calls.length - run.done.length} bill(s); '
            'cover x${_activeCovers.length}, modes ${modes.join('/')}');

    final socketService = ref.read(socketServiceProvider);
    ({BillPaymentCall call, Map<String, dynamic> ack})? failed;
    for (final call in run.calls) {
      if (run.done.contains(call.billId)) continue;

      // emitAckIdempotent owns the `client_request_id`: one per intent (bill +
      // payments), the same on a retry after a lost ack so the desk replays the
      // charge instead of repeating it, retired on success and expired when
      // unanswered. A per-widget id map here used to do that by hand, without
      // the retirement or the expiry.
      final response = await socketService.emitAckIdempotent(
        'bill:payment',
        call.toPayload(),
        timeout: const Duration(seconds: 15),
      );

      if (response['kind'] == 'success') {
        run.done.add(call.billId);
        _record(call.billId, response);
      } else {
        failed = (call: call, ack: response);
        break;
      }
    }

    if (!mounted) return;
    final total = widget.bills.length;
    final done = _settledBillIds.length;
    if (failed == null) {
      _pending = null;
      if (done == total) {
        Navigator.of(context).pop(true);
        return;
      }
      final short = run.done.any((id) => !_settledBillIds.contains(id));
      if (short) {
        // Everything went through, but the desk took less cover than was
        // sent: what was entered is spent, and the rest is still due.
        _covers.clear();
        _tender.reset();
        setState(() {
          _submitting = false;
          _stillDue = _StillDue.coverCapped;
        });
        logD('[Payment]', 'went through short; money still due');
        DynamicToast.show(context,
            message: '${formatRupeesCompact(_due)} still due',
            kind: ToastKind.warning);
        return;
      }
      // A bill nothing landed on was not sent (as before).
      setState(() => _submitting = false);
      DynamicToast.show(context,
          message: _retryMessage(done, total), kind: ToastKind.error);
      return;
    }

    final error = AckError.fromAck(failed.ack);
    final outcomeUnknown =
        isTransportFailure(failed.ack) || error.code == AckCode.badResponse;
    final partly = run.done.isNotEmpty;
    final coverRefused =
        !outcomeUnknown && failed.call.lines.any((l) => l.isCover);
    logD('[Payment]',
        'bill:payment failed: ${error.code ?? 'no code'}, $done of $total settled');
    if (outcomeUnknown) {
      // It may have landed: resend exactly this, so the desk can replay it.
      _pending = partly ? run : null;
    } else {
      // The desk refused that bill, so nothing on it was recorded.
      _pending = null;
      if (partly) {
        _covers.clear();
        _tender.reset();
        _stillDue = _StillDue.partly;
      }
    }
    setState(() => _submitting = false);
    final String message;
    if (coverRefused) {
      message = coverErrorCopy(error.code) ?? error.message;
    } else if (!outcomeUnknown && partly) {
      message = 'Settled $done of $total. Take payment for the remaining '
          '${formatRupeesCompact(_due)}.';
    } else {
      message = _retryMessage(done, total);
    }
    DynamicToast.show(context, message: message, kind: ToastKind.error);
  }

  static String _retryMessage(int done, int total) => done == 0
      ? 'Payment failed — nothing was charged. Retry.'
      : 'Settled $done of $total. '
          'Retry sends only the remaining ${total - done}.';

  @override
  void dispose() {
    _tender.removeListener(_onTenderChanged);
    _tender.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(flagsProvider);
    final coverOn = canRedeemCover(flags, ref.watch(ticketConfigProvider));
    final isSplitMode = flags.splitPayment;
    final modes =
        payModeCatalog(flags: flags, listed: ref.watch(payModesProvider));
    final locked = _pending != null;
    final tenderDue = _tenderDue;
    final coverPaysAll = _activeCovers.isNotEmpty && tenderDue.isZero;

    final bool canPay;
    if (_submitting) {
      canPay = false;
    } else if (locked || coverPaysAll) {
      canPay = true;
    } else if (isSplitMode && _tender.splits.isNotEmpty) {
      canPay = (tenderDue - _tender.splitTotal).isZero;
    } else {
      canPay = _tender.selectedComplete &&
          !_tender.creditBlocked(hasCustomer: widget.hasCustomer);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 28 + context.sheetBottomInset),
        child: ListView(
          controller: scrollCtrl,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.payment_outlined,
                    color: AppColors.terra, size: 22),
                const SizedBox(width: 10),
                const Text('Collect Payment', style: AppTypography.sheetTitle),
                const Spacer(),
                Text(formatRupeesCompact(widget.grandTotal),
                    style: AppTypography.headline),
              ],
            ),
            if (widget.bills.length > 1) ...[
              const SizedBox(height: 8),
              for (final bill in widget.bills)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: bill.billType == 'liquor'
                              ? AppColors.violet
                              : bill.billType == 'beverages'
                                  ? AppColors.teal
                                  : AppColors.terra500,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                          '${bill.billType[0].toUpperCase()}${bill.billType.substring(1)} · ${bill.billNumber}',
                          style: AppTypography.caption),
                      const Spacer(),
                      Text(formatRupeesCompact(bill.totalAmount),
                          style: AppTypography.caption
                              .copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
            if (_stillDue != null) ...[
              const SizedBox(height: 12),
              _Notice(
                color: AppColors.amber,
                icon: Icons.info_outline,
                text: '${formatRupeesCompact(_due)} still due — '
                    '${switch (_stillDue!) {
                  _StillDue.coverCapped =>
                    'a ticket had less cover left than shown. Take another payment for it.',
                  _StillDue.partly =>
                    'part of the payment went through. Take another payment for the rest.',
                }}',
              ),
            ],
            if (locked) ...[
              const SizedBox(height: 12),
              const _Notice(
                color: AppColors.amber,
                icon: Icons.sync_problem_outlined,
                text: 'Part of this payment went through. Pay retries the '
                    'rest exactly as entered.',
              ),
            ],
            if (coverOn)
              CoverRedeemSection(
                covers: _covers,
                coverable: _coverable(isSplitMode),
                enabled: !locked && !_submitting,
                onAdd: (cover) => setState(() => _covers.add(cover)),
                onRemove: (cover) => setState(() => _covers.remove(cover)),
              ),
            if (_activeCovers.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                if (coverPaysAll) ...[
                  const Icon(Icons.check_circle_outline,
                      color: AppColors.success, size: 18),
                  const SizedBox(width: 8),
                  const Text('Cover pays it all', style: AppTypography.bodyMd),
                ] else ...[
                  const Text('To collect', style: AppTypography.bodyMd),
                  const Spacer(),
                  Text(formatRupeesCompact(tenderDue),
                      style: AppTypography.title
                          .copyWith(fontWeight: FontWeight.w700)),
                ],
              ]),
            ],
            if (!coverPaysAll)
              TenderForm(
                controller: _tender,
                modes: modes,
                due: tenderDue,
                allowSplit: isSplitMode,
                hasCustomer: widget.hasCustomer,
                enabled: !locked,
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: LiquidSecondaryButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
              )),
              const SizedBox(width: 8),
              Expanded(
                  child: LiquidPrimaryButton(
                label: _submitting ? 'Processing...' : 'Pay',
                fullWidth: true,
                leadingIcon: _submitting
                    ? Icons.hourglass_top
                    : Icons.check_circle_outline,
                onPressed: canPay ? _pay : null,
              )),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _Notice({required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: AppTypography.caption)),
      ]),
    );
  }
}
