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
import '../utils/payment_run.dart';
import '../utils/tender_allocation.dart';
import 'app_surface.dart';
import 'cover_redeem_section.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';
import 'tender_form.dart';

/// What payment sheets recorded on one order's bills, kept by the screen
/// that opens them across openings. `bill:generate` only gives each bill's
/// total; the desk's answers to `bill:payment` say what a bill still owes.
/// A sheet opened again starts from there: a settled bill is not offered
/// again, and a part-paid one is offered at what it still owes.
class BillDues {
  final Map<String, Money> _owed = <String, Money>{};
  final Set<String> _settled = <String>{};

  /// The desk recorded a payment on [billId]: it still owes [left], or
  /// nothing (settled) when [left] is null or not positive.
  void record(String billId, Money? left) {
    if (left == null || !left.isPositive) {
      _settled.add(billId);
      _owed[billId] = Money.zero;
    } else {
      _owed[billId] = left;
    }
  }

  /// What [bill] still owes, as far as payments on this phone have shown.
  Money owedOn(ServerBill bill) => _owed[bill.id] ?? bill.totalAmount;

  bool isSettled(String billId) => _settled.contains(billId);

  /// New bills (generated again): nothing recorded applies to them.
  void clear() {
    _owed.clear();
    _settled.clear();
  }
}

class PaymentSheet {
  /// [dues], when given, is where the sheet starts and what it updates as
  /// the desk records payments (see [BillDues]).
  static Future<bool?> show(
    BuildContext context, {
    required List<ServerBill> bills,
    bool hasCustomer = false,
    BillDues? dues,
  }) {
    final grandTotal = bills.map((b) => b.totalAmount).sumMoney();
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // Swiping closed is the inner DraggableScrollableSheet's, which the
      // sheet turns off while it must stay open; a tap outside is a pop its
      // PopScope can refuse.
      enableDrag: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _PaymentSheetBody(
        bills: bills,
        grandTotal: grandTotal,
        hasCustomer: hasCustomer,
        dues: dues,
      ),
    );
  }
}

class _PaymentSheetBody extends ConsumerStatefulWidget {
  final List<ServerBill> bills;
  final Money grandTotal;
  final bool hasCustomer;
  final BillDues? dues;
  const _PaymentSheetBody({
    required this.bills,
    required this.grandTotal,
    required this.hasCustomer,
    this.dues,
  });
  @override
  ConsumerState<_PaymentSheetBody> createState() => _PaymentSheetBodyState();
}

class _PaymentSheetBodyState extends ConsumerState<_PaymentSheetBody> {
  final TenderFormController _tender = TenderFormController();
  final List<AppliedCover> _covers = <AppliedCover>[];

  /// What the desk recorded on these bills, here and in earlier sheets.
  late final BillDues _kept = widget.dues ?? BillDues();

  /// What each bill still owes, as far as this sheet knows: its total until
  /// the desk records a payment on it.
  late final Map<String, Money> _dues = <String, Money>{
    for (final bill in widget.bills) bill.id: _kept.owedOn(bill),
  };
  late final Set<String> _settledBillIds = <String>{
    for (final bill in widget.bills)
      if (_kept.isSettled(bill.id)) bill.id,
  };

  /// The planned calls, from the moment Pay sends them until the desk has
  /// answered every one. While it is set the fields are locked and Pay
  /// resends its unsent calls exactly as planned (same payloads, so the same
  /// `client_request_id`s): a call that got no answer may have gone through.
  PaymentRun? _pending;
  bool _submitting = false;
  StillDue? _stillDue;
  bool _confirmingClose = false;

  /// A try got no answer and its run was let go without one (the desk
  /// refused the identical resend): it may have gone through. Kept for the
  /// sheet's life, so Close asks first and no later refusal reads "nothing
  /// was charged".
  bool _unresolved = false;

  /// Closing now would lose track of money: a payment in flight, one that
  /// may have gone through, or a part still due.
  bool get _holdOpen =>
      _submitting || _pending != null || _stillDue != null || _unresolved;

  /// Covers and tenders can change: nothing planned is kept or in flight.
  bool get _editable => _pending == null && !_submitting;

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

  /// "Food · INV/001", as staff read a bill.
  static String _billLabel(ServerBill bill) {
    final type =
        '${bill.billType[0].toUpperCase()}${bill.billType.substring(1)}';
    return bill.billNumber.isEmpty ? type : '$type · ${bill.billNumber}';
  }

  /// The calls for what is on screen, or null (with a toast saying why) when
  /// it is not ready to pay.
  List<BillPaymentCall>? _planFromScreen(FeatureFlags flags) {
    final tenderDue = _tenderDue;
    if (tenderDue.isPositive) {
      if (_tender.creditBlocked(hasCustomer: widget.hasCustomer)) {
        DynamicToast.show(context,
            message: 'Link a customer before using Credit payment',
            kind: ToastKind.error);
        return null;
      }
      final useSplits = flags.splitPayment && _tender.splits.isNotEmpty;
      if (!useSplits && _tender.selected == null) {
        DynamicToast.show(context,
            message: 'Pick a payment mode first', kind: ToastKind.error);
        return null;
      }
    }
    final tenders =
        _tender.lines(due: tenderDue, splitMode: flags.splitPayment);
    if (tenders == null) {
      DynamicToast.show(context,
          message: 'Fill in what ${_tender.selected?.label ?? 'this mode'} '
              'needs first',
          kind: ToastKind.error);
      return null;
    }
    final tendered = tenders.map((t) => t.amount ?? Money.zero).sumMoney();
    if (tendered != tenderDue) {
      DynamicToast.show(context,
          message: 'The payments add up to ${formatRupeesCompact(tendered)}, '
              'not ${formatRupeesCompact(tenderDue)}',
          kind: ToastKind.error);
      return null;
    }
    return planBillPayments(
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
      tenders: tenders,
    );
  }

  /// Reads back what the desk recorded on [billId]. Cover may have been
  /// taken for less than was sent (the desk caps it at the ticket's balance),
  /// so the bill only counts as settled when the desk says so.
  void _record(String billId, Map<String, dynamic> response) {
    final ack = BillPaymentAck.fromAck(response);
    final left = ack.bill?.id == billId ? ack.remaining : null;
    _kept.record(billId, left);
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
    final kept = _pending;
    final List<BillPaymentCall>? planned =
        kept == null ? _planFromScreen(flags) : null;
    if (kept == null && planned == null) return;

    if (!requireDesk(context, ref)) return;
    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;

    final run = kept ?? PaymentRun(planned!);
    setState(() {
      _submitting = true;
      _pending = run;
    });
    final modes = <String>{
      for (final call in run.calls)
        for (final line in call.lines) line.mode,
    };
    logD(
        '[Payment]',
        '${kept != null ? 'retrying' : 'paying'} ${run.unsent.length} '
            'bill(s); cover x${_activeCovers.length}, '
            'modes ${modes.join('/')}');
    try {
      final failure = await _send(run);
      if (!mounted) return;
      _apply(run, failure);
    } finally {
      if (mounted && _submitting) setState(() => _submitting = false);
    }
  }

  /// Sends the run's unsent calls in order, stopping at the first that does
  /// not go through.
  Future<CallFailure?> _send(PaymentRun run) async {
    final socketService = ref.read(socketServiceProvider);
    for (final call in run.unsent) {
      // emitAckIdempotent owns the `client_request_id`: one per intent (bill +
      // payments), the same on a retry after a lost ack so the desk replays the
      // charge instead of repeating it, retired on success and expired when
      // unanswered. A per-widget id map here used to do that by hand, without
      // the retirement or the expiry.
      //
      // The run holds the id it first stamped (PaymentRun.idFor): the intent
      // id lapses after 15 minutes, and a resend after that must still be
      // the same request for the desk to replay it.
      final response = await socketService.emitAckIdempotent(
        'bill:payment',
        call.toPayload(),
        timeout: const Duration(seconds: 15),
        requestId: run.idFor(call),
      );
      if (response['kind'] == 'success') {
        run.done.add(call.billId);
        _record(call.billId, response);
        continue;
      }
      final error = AckError.fromAck(response);
      final noAnswer =
          isTransportFailure(response) || error.code == AckCode.badResponse;
      if (noAnswer) run.sawNoAnswer = true;
      logD('[Payment]',
          'bill:payment ${noAnswer ? 'got no answer' : 'refused'}: ${error.code ?? 'no code'}');
      return CallFailure(
        call: call,
        noAnswer: noAnswer,
        refusal: namedTicketRefusal(error.code, error.message,
                tickets: call.lines.where((line) => line.isCover).length) ??
            coverErrorCopy(error.code) ??
            error.message,
      );
    }
    return null;
  }

  void _apply(PaymentRun run, CallFailure? failure) {
    final verdict = decidePay(
      run: run,
      failure: failure,
      settled: _settledBillIds.length,
      total: widget.bills.length,
      due: _due,
      short: <ShortBill>[
        for (final bill in widget.bills)
          if (run.done.contains(bill.id) && !_settledBillIds.contains(bill.id))
            (label: _billLabel(bill), hadCover: run.carriesCover(bill.id)),
      ],
      earlierUnanswered: _unresolved,
    );
    logD('[Payment]',
        '${_settledBillIds.length} of ${widget.bills.length} settled; ${verdict.keepRun ? 'kept for a retry' : 'done'}');
    if (verdict.close) {
      Navigator.of(context).pop(true);
      return;
    }
    if (verdict.clearInputs) {
      _covers.clear();
      _tender.reset();
    }
    setState(() {
      _submitting = false;
      _pending = verdict.keepRun ? run : null;
      if (verdict.stillDue != null) _stillDue = verdict.stillDue;
      if (verdict.unresolved) _unresolved = true;
    });
    final toast = verdict.toast;
    if (toast != null) {
      DynamicToast.show(context,
          message: toast,
          kind: verdict.toastIsWarning ? ToastKind.warning : ToastKind.error);
    }
  }

  /// Closing while money may have moved: say so before letting go.
  Future<void> _confirmClose() async {
    if (_confirmingClose || _submitting) return;
    _confirmingClose = true;
    try {
      final leave = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: context.palette.surface,
          title: const Text('Close the payment?', style: AppTypography.title),
          content: const Text(
              'A payment may have gone through or part is still due — '
              'check the bill on the order screen.',
              style: AppTypography.bodyMd),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep paying'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Close',
                  style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (leave == true && mounted && !_submitting) {
        Navigator.of(context).pop();
      }
    } finally {
      _confirmingClose = false;
    }
  }

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
    final pending = _pending;
    final editable = _editable;
    final tenderDue = _tenderDue;
    final coverPaysAll = _activeCovers.isNotEmpty && tenderDue.isZero;
    final moneyMayHaveMoved =
        pending != null || _stillDue != null || _unresolved;

    final bool canPay;
    if (_submitting) {
      canPay = false;
    } else if (pending != null || coverPaysAll) {
      canPay = true;
    } else if (isSplitMode && _tender.splits.isNotEmpty) {
      canPay = (tenderDue - _tender.splitTotal).isZero;
    } else {
      canPay = _tender.selectedComplete &&
          !_tender.creditBlocked(hasCustomer: widget.hasCustomer);
    }

    return PopScope(
      canPop: !_holdOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _submitting) return;
        unawaited(_confirmClose());
      },
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        shouldCloseOnMinExtent: !_holdOpen,
        builder: (_, scrollCtrl) => AppSurface(
          borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
          padding:
              EdgeInsets.fromLTRB(20, 12, 20, 28 + context.sheetBottomInset),
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
                  const Text('Collect Payment',
                      style: AppTypography.sheetTitle),
                  const Spacer(),
                  // Once the desk has taken part of it: what is still due,
                  // not the total it started at.
                  if (_due != widget.grandTotal)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${formatRupeesCompact(_due)} due',
                            style: AppTypography.headline),
                        Text('of ${formatRupeesCompact(widget.grandTotal)}',
                            style: AppTypography.caption),
                      ],
                    )
                  else
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
                        Text(
                            _settledBillIds.contains(bill.id)
                                ? 'Paid'
                                : _dues[bill.id] != bill.totalAmount
                                    ? '${formatRupeesCompact(_dues[bill.id]!)} '
                                        'left of '
                                        '${formatRupeesCompact(bill.totalAmount)}'
                                    : formatRupeesCompact(bill.totalAmount),
                            style: AppTypography.caption.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _settledBillIds.contains(bill.id)
                                    ? AppColors.success
                                    : null)),
                      ],
                    ),
                  ),
              ],
              if (_stillDue != null) ...[
                const SizedBox(height: 12),
                _Notice(
                  color: AppColors.amber,
                  icon: Icons.info_outline,
                  text: _stillDue!.message(_due),
                ),
              ],
              if (pending != null && !_submitting) ...[
                const SizedBox(height: 12),
                _Notice(
                  color: AppColors.amber,
                  icon: Icons.sync_problem_outlined,
                  text: pending.started
                      ? 'Part of this payment went through. Pay retries the '
                          'rest exactly as entered.'
                      : kPaymentNoAnswer,
                ),
              ] else if (_unresolved && !_submitting) ...[
                const SizedBox(height: 12),
                const _Notice(
                  color: AppColors.amber,
                  icon: Icons.sync_problem_outlined,
                  text: '$kEarlierTryUnanswered: it may have gone through. '
                      'Check it before taking the money again.',
                ),
              ],
              if (coverOn)
                CoverRedeemSection(
                  // Keyed: a notice appearing above it must not rebuild it
                  // and drop a lookup it is waiting on.
                  key: const ValueKey<String>('cover-redeem-section'),
                  covers: _covers,
                  coverable: _coverable(isSplitMode),
                  enabled: editable,
                  // A lookup may answer after Pay locked the sheet: nothing
                  // is added under a planned (or sent) payment.
                  onAdd: (cover) {
                    if (_editable) setState(() => _covers.add(cover));
                  },
                  onRemove: (cover) {
                    if (_editable) setState(() => _covers.remove(cover));
                  },
                ),
              if (_activeCovers.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(children: [
                  if (coverPaysAll) ...[
                    const Icon(Icons.check_circle_outline,
                        color: AppColors.success, size: 18),
                    const SizedBox(width: 8),
                    const Text('Cover pays it all',
                        style: AppTypography.bodyMd),
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
                  enabled: editable,
                ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                    child: LiquidSecondaryButton(
                  label: moneyMayHaveMoved && !_submitting ? 'Close' : 'Cancel',
                  onPressed: _submitting
                      ? null
                      : _holdOpen
                          ? () => unawaited(_confirmClose())
                          : () => Navigator.of(context).pop(),
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
