

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../models/server_models.dart';
import '../services/pin_guard.dart';
import '../utils/request_id.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

enum PaymentMode { cash, upi, card, complimentary, credit, company }

class _PaymentEntry {
  final PaymentMode mode;
  final Money amount;
  final String? reference;
  final String? notes;

  const _PaymentEntry({
    required this.mode,
    required this.amount,
    this.reference,
    this.notes,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'payment_mode': mode.name,
        'amount': amount.toWire(),
        if (reference != null && reference!.isNotEmpty)
          'reference_number': reference,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
      };
}

String _modeLabel(PaymentMode m) => switch (m) {
      PaymentMode.cash => 'Cash',
      PaymentMode.upi => 'UPI',
      PaymentMode.card => 'Card',
      PaymentMode.complimentary => 'Comp',
      PaymentMode.credit => 'Credit',
      PaymentMode.company => 'Company',
    };

IconData _modeIcon(PaymentMode m) => switch (m) {
      PaymentMode.cash => Icons.payments_outlined,
      PaymentMode.upi => Icons.phone_android_outlined,
      PaymentMode.card => Icons.credit_card_outlined,
      PaymentMode.complimentary => Icons.card_giftcard_outlined,
      PaymentMode.credit => Icons.account_balance_outlined,
      PaymentMode.company => Icons.business_outlined,
    };

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

class _PaymentSheetBodyState extends ConsumerState<_PaymentSheetBody> {
  PaymentMode? _selectedMode;
  final _refController = TextEditingController();
  final _tenderedController = TextEditingController();
  final _reasonController = TextEditingController();
  final _authorizedByController = TextEditingController();
  bool _submitting = false;

  final List<_PaymentEntry> _splits = [];
  final _splitAmountController = TextEditingController();

  Money get _paidSoFar => _splits.map((e) => e.amount).sumMoney();
  Money get _remaining => widget.grandTotal - _paidSoFar;

  /// Parsed from the tendered-cash field. This is the only place a typed
  /// rupee string becomes money, and it becomes paise immediately.
  Money get _tendered =>
      Money.fromWire(_tenderedController.text.trim()) ?? Money.zero;

  Money get _change {
    final difference = _tendered - widget.grandTotal;
    return difference.isPositive ? difference : Money.zero;
  }

  bool get _needsRef =>
      _selectedMode == PaymentMode.upi || _selectedMode == PaymentMode.card;
  bool get _needsReason =>
      _selectedMode == PaymentMode.complimentary ||
      _selectedMode == PaymentMode.company;
  bool get _isCreditBlocked =>
      _selectedMode == PaymentMode.credit && !widget.hasCustomer;

  /// Comp / credit / company were appended unconditionally, ignoring the
  /// flags that exist precisely to control them — every waiter could comp a
  /// bill. The desk must enforce this too; this is the UX half only.
  List<PaymentMode> _availableModes() {
    final flags = ref.read(flagsProvider);
    return <PaymentMode>[
      PaymentMode.cash,
      PaymentMode.upi,
      PaymentMode.card,
      if (flags.complimentary) PaymentMode.complimentary,
      if (flags.customers) PaymentMode.credit,
      if (flags.complimentary) PaymentMode.company,
    ];
  }

  /// Bills already settled in this sheet's lifetime.
  ///
  /// The old flow reported "Paid 1 of 2 — retry remaining" and then restarted
  /// the loop from bill index 0 on the next tap, re-paying the settled bill.
  /// `bill:payment` also carried no idempotency key here (unlike the
  /// quick-settle path), so the desk had nothing to dedupe on.
  final Set<String> _settledBillIds = <String>{};

  /// Idempotency keys, stable per bill for the life of this sheet. A retry
  /// re-sends the *same* key so the desk can recognise and collapse it.
  final Map<String, String> _requestIds = <String, String>{};

  String _requestIdFor(String billId) =>
      _requestIds.putIfAbsent(billId, newRequestId);

  Future<void> _pay() async {
    if (_submitting) return;
    if (_isCreditBlocked) {
      DynamicToast.show(context,
          message: 'Link a customer before using Credit payment',
          kind: ToastKind.error);
      return;
    }

    final flags = ref.read(flagsProvider);
    final useSplits = flags.splitPayment && _splits.isNotEmpty;

    // Guard the non-split branch explicitly. `canPay` allowed a null mode
    // through whenever split mode was on with an empty split list and the
    // grand total happened to be zero, and `_selectedMode!` then threw.
    final selectedMode = _selectedMode;
    if (!useSplits && selectedMode == null) {
      DynamicToast.show(context,
          message: 'Pick a payment mode first', kind: ToastKind.error);
      return;
    }

    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;

    setState(() => _submitting = true);

    final socketService = ref.read(socketServiceProvider);

    final List<_PaymentEntry> entries;
    if (useSplits) {
      entries = _splits;
    } else {
      final notes = _needsReason
          ? '${_reasonController.text.trim()} | Auth: ${_authorizedByController.text.trim()}'
          : null;
      entries = <_PaymentEntry>[
        _PaymentEntry(
          mode: selectedMode!,
          amount: widget.grandTotal,
          reference: _refController.text.trim().isNotEmpty
              ? _refController.text.trim()
              : null,
          notes: notes,
        ),
      ];
    }

    // Bills still owing. Anything already settled in this sheet is skipped,
    // which is what makes the retry button safe.
    final outstanding = widget.bills
        .where((b) => !_settledBillIds.contains(b.id))
        .toList(growable: false);
    final billWeights =
        outstanding.map((b) => b.totalAmount).toList(growable: false);

    // Every entry is split across the outstanding bills by largest
    // remainder, in integer paise. Each entry's allocations sum back to the
    // entry exactly — no drift to patch up afterwards, and no NaN when the
    // weights are all zero.
    final perBillPayments = <String, List<Map<String, dynamic>>>{
      for (final bill in outstanding) bill.id: <Map<String, dynamic>>[],
    };
    for (final entry in entries) {
      final shares = allocateProportionally(entry.amount, billWeights);
      for (var i = 0; i < outstanding.length; i++) {
        final share = shares[i];
        if (share.isZero) continue;
        perBillPayments[outstanding[i].id]!.add(
          _PaymentEntry(
            mode: entry.mode,
            amount: share,
            reference: entry.reference,
            notes: entry.notes,
          ).toMap(),
        );
      }
    }

    var failures = 0;
    for (final bill in outstanding) {
      final payments = perBillPayments[bill.id]!;
      if (payments.isEmpty) continue;

      final response = await socketService.emitAck(
        'bill:payment',
        <String, dynamic>{
          'bill_id': bill.id,
          'payments': payments,
          'client_request_id': _requestIdFor(bill.id),
        },
        timeout: const Duration(seconds: 15),
      );

      if (response['kind'] == 'success') {
        _settledBillIds.add(bill.id);
      } else {
        failures++;
        // Stop on the first failure. Carrying on would settle later bills
        // while an earlier one is in an unknown state.
        break;
      }
    }

    if (!mounted) return;
    if (failures == 0 && _settledBillIds.length == widget.bills.length) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() => _submitting = false);
    final done = _settledBillIds.length;
    DynamicToast.show(
      context,
      message: done == 0
          ? 'Payment failed — nothing was charged. Retry.'
          : 'Settled $done of ${widget.bills.length}. '
              'Retry sends only the remaining ${widget.bills.length - done}.',
      kind: ToastKind.error,
    );
  }

  void _addSplit() {
    final mode = _selectedMode;
    if (mode == null) return;
    final amount = Money.fromWire(_splitAmountController.text.trim());
    if (amount == null || !amount.isPositive) return;
    final capped = amount > _remaining ? _remaining : amount;
    if (!capped.isPositive) return;

    setState(() {
      _splits.add(_PaymentEntry(
        mode: mode,
        amount: capped,
        reference: _refController.text.trim().isNotEmpty
            ? _refController.text.trim()
            : null,
        notes: _needsReason
            ? '${_reasonController.text.trim()} | Auth: ${_authorizedByController.text.trim()}'
            : null,
      ));
      _splitAmountController.clear();
      _refController.clear();
      _reasonController.clear();
      _authorizedByController.clear();
      _selectedMode = null;
    });
  }

  @override
  void dispose() {
    _refController.dispose();
    _tenderedController.dispose();
    _reasonController.dispose();
    _authorizedByController.dispose();
    _splitAmountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(flagsProvider);
    final isSplitMode = flags.splitPayment;
    final modes = _availableModes();

    final bool canPay;
    if (isSplitMode && _splits.isNotEmpty) {
      canPay = _remaining.isZero && !_submitting;
    } else {
      canPay = _selectedMode != null && !_submitting && !_isCreditBlocked;
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 28 + context.sheetBottomInset),
        child: ListView(
          controller: scrollCtrl,
          children: [
            Center(
                child: const SheetHandle()),
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
            const SizedBox(height: 16),

            Text('PAYMENT MODE',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in modes)
                  _ModeChip(
                    label: _modeLabel(mode),
                    icon: _modeIcon(mode),
                    selected: _selectedMode == mode,
                    onTap: () => setState(() => _selectedMode = mode),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            if (_isCreditBlocked)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(
                      color: AppColors.danger.withValues(alpha: 0.3)),
                ),
                child: const Row(children: [
                  Icon(Icons.warning_amber, color: AppColors.danger, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                      child: Text('Link a customer to use Credit',
                          style: AppTypography.caption)),
                ]),
              ),

            if (_needsRef) ...[
              const SizedBox(height: 12),
              Text('REFERENCE NUMBER',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              _InputField(
                controller: _refController,
                hint: _selectedMode == PaymentMode.upi
                    ? 'UPI transaction ID'
                    : 'Card approval code',
              ),
            ],

            if (_needsReason) ...[
              const SizedBox(height: 12),
              Text('REASON',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              _InputField(
                  controller: _reasonController,
                  hint: 'Reason for comp / company bill'),
              const SizedBox(height: 8),
              _InputField(
                  controller: _authorizedByController,
                  hint: 'Authorized by (name)'),
            ],

            if (_selectedMode == PaymentMode.cash &&
                !(isSplitMode && _splits.isNotEmpty)) ...[
              const SizedBox(height: 12),
              Text('CASH TENDERED',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              _InputField(
                controller: _tenderedController,
                hint: formatRupeesCompact(widget.grandTotal),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                prefix: '₹ ',
                onChanged: (_) => setState(() {}),
              ),
              if (_tendered.isPositive && _change.isPositive) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.all(AppRadii.sm),
                    border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.change_circle_outlined,
                        color: AppColors.success, size: 18),
                    const SizedBox(width: 8),
                    const Text('Change:', style: AppTypography.bodyMd),
                    const Spacer(),
                    Text(formatRupeesCompact(_change),
                        style: AppTypography.title.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
              ],

              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in [100, 200, 500, 1000, 2000])
                    if (Money.rupees(d) >= widget.grandTotal)
                      GestureDetector(
                        onTap: () {
                          _tenderedController.text = d.toString();
                          setState(() {});
                        },
                        child: AppSurface(
                          borderRadius: const BorderRadius.all(AppRadii.pill),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          shadow: const [],
                          child: Text('₹$d',
                              style: AppTypography.caption
                                  .copyWith(fontWeight: FontWeight.w600)),
                        ),
                      ),
                ],
              ),
            ],

            if (isSplitMode) ...[
              const SizedBox(height: 12),
              Divider(color: context.palette.ink10),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.call_split_outlined,
                    color: context.palette.ink70, size: 18),
                const SizedBox(width: 8),
                const Text('Split Payment', style: AppTypography.bodyMd),
                const Spacer(),
                Text('Remaining: ${formatRupeesCompact(_remaining)}',
                    style: AppTypography.caption.copyWith(
                        color: _remaining.isPositive
                            ? AppColors.terra500
                            : AppColors.success,
                        fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 8),
              for (int i = 0; i < _splits.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: AppSurface(
                    borderRadius: const BorderRadius.all(AppRadii.sm),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    shadow: const [],
                    child: Row(children: [
                      Icon(_modeIcon(_splits[i].mode),
                          size: 16, color: context.palette.ink70),
                      const SizedBox(width: 8),
                      Text(_modeLabel(_splits[i].mode),
                          style: AppTypography.bodyMd),
                      const Spacer(),
                      Text(formatRupeesCompact(_splits[i].amount),
                          style: AppTypography.bodyMd
                              .copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _splits.removeAt(i)),
                        child: const Icon(Icons.close,
                            size: 16, color: AppColors.danger),
                      ),
                    ]),
                  ),
                ),

              // Explicit, operator-initiated round-off. The automatic
              // version silently topped up the last payment line by up to
              // 99 paise the customer never handed over; this makes it a
              // deliberate act with a "Round-off" note attached.
              if (_remaining.isPositive &&
                  _remaining < const Money.rupees(1) &&
                  _splits.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _splits.add(_PaymentEntry(
                          mode: PaymentMode.cash,
                          amount: _remaining,
                          notes: 'Round-off',
                        ));
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.amber.withValues(alpha: 0.1),
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(
                            color: AppColors.amber.withValues(alpha: 0.3)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.monetization_on_outlined,
                            color: AppColors.amber, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                'Settle ${formatRupeesCompact(_remaining)} shortfall (round-off)',
                                style: AppTypography.caption
                                    .copyWith(fontWeight: FontWeight.w600))),
                        const Icon(Icons.add_circle_outline,
                            color: AppColors.amber, size: 16),
                      ]),
                    ),
                  ),
                ),
              if (_remaining.isPositive) ...[
                Row(children: [
                  Expanded(
                      child: _InputField(
                    controller: _splitAmountController,
                    hint: formatRupeesCompact(_remaining),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    prefix: '₹ ',
                  )),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _selectedMode != null ? _addSplit : null,
                    child: Container(
                      width: AppTouchTargets.control,
                      height: AppTouchTargets.control,
                      decoration: BoxDecoration(
                        color: _selectedMode != null
                            ? AppColors.terra500
                            : context.palette.ink05,
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                      ),
                      child: Icon(Icons.add,
                          color: _selectedMode != null
                              ? Colors.white
                              : context.palette.ink30),
                    ),
                  ),
                ]),
              ],
            ],

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

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final String? prefix;
  final ValueChanged<String>? onChanged;
  const _InputField({
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.prefix,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: context.palette.hairline, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: AppTypography.bodyMd,
        onChanged: onChanged,
        cursorColor: AppColors.terra,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: AppTypography.caption,
          isDense: true,
          prefixText: prefix,
          prefixStyle: AppTypography.bodyMd,
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? context.palette.terraSoft : palette.surface,
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
              color: selected ? AppColors.terra : context.palette.hairline,
              width: selected ? 1.5 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? AppColors.terraDeep : palette.ink70),
            const SizedBox(width: 6),
            Text(label,
                style: AppTypography.bodyMd.copyWith(
                    color: selected ? AppColors.terraDeep : palette.ink,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
