

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

class BillInfo {
  final String id;
  final String billNumber;
  final double totalAmount;
  final String billType;

  const BillInfo({
    required this.id,
    required this.billNumber,
    required this.totalAmount,
    required this.billType,
  });

  factory BillInfo.fromMap(Map<String, dynamic> m) {
    return BillInfo(
      id: m['id']?.toString() ?? '',
      billNumber: m['bill_number']?.toString() ?? '',
      totalAmount: (m['total_amount'] as num?)?.toDouble() ?? 0,
      billType: m['bill_type']?.toString() ?? 'food',
    );
  }
}

enum PaymentMode { cash, upi, card, complimentary, credit, company }

class _PaymentEntry {
  final PaymentMode mode;
  final double amount;
  final String? reference;
  final String? notes;

  const _PaymentEntry({
    required this.mode,
    required this.amount,
    this.reference,
    this.notes,
  });

  Map<String, dynamic> toMap() => {
        'payment_mode': mode.name,
        'amount': amount,
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
    required List<BillInfo> bills,
    bool hasCustomer = false,
  }) {
    final grandTotal =
        bills.fold(0.0, (double s, BillInfo b) => s + b.totalAmount);
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
  final List<BillInfo> bills;
  final double grandTotal;
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

  double get _paidSoFar => _splits.fold(0.0, (s, e) => s + e.amount);
  double get _remaining => widget.grandTotal - _paidSoFar;

  double get _tendered {
    final t = double.tryParse(_tenderedController.text.trim());
    return t ?? 0;
  }

  double get _change =>
      (_tendered - widget.grandTotal).clamp(0, double.infinity);

  bool get _needsRef =>
      _selectedMode == PaymentMode.upi || _selectedMode == PaymentMode.card;
  bool get _needsReason =>
      _selectedMode == PaymentMode.complimentary ||
      _selectedMode == PaymentMode.company;
  bool get _isCreditBlocked =>
      _selectedMode == PaymentMode.credit && !widget.hasCustomer;

  List<PaymentMode> _availableModes() {
    final modes = <PaymentMode>[
      PaymentMode.cash,
      PaymentMode.upi,
      PaymentMode.card,
    ];

    modes.addAll([
      PaymentMode.complimentary,
      PaymentMode.credit,
      PaymentMode.company,
    ]);
    return modes;
  }

  Future<void> _pay() async {
    if (_submitting) return;
    if (_isCreditBlocked) {
      DynamicToast.show(context,
          message: 'Link a customer before using Credit payment',
          kind: ToastKind.error);
      return;
    }

    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;

    setState(() => _submitting = true);

    final flags = ref.read(flagsProvider);
    final socketService = ref.read(socketServiceProvider);

    List<_PaymentEntry> entries;
    if (flags.splitPayment && _splits.isNotEmpty) {
      entries = _splits;
    } else {
      final notes = _needsReason
          ? '${_reasonController.text.trim()} | Auth: ${_authorizedByController.text.trim()}'
          : null;
      entries = [
        _PaymentEntry(
          mode: _selectedMode!,
          amount: widget.grandTotal,
          reference: _refController.text.trim().isNotEmpty
              ? _refController.text.trim()
              : null,
          notes: notes,
        ),
      ];
    }

    int billsPaid = 0;

    for (final bill in widget.bills) {
      final billPayments = <Map<String, dynamic>>[];
      double billRemaining = bill.totalAmount;

      for (final entry in entries) {
        if (billRemaining <= 0.01) break;
        final share = entry.amount * (bill.totalAmount / widget.grandTotal);
        final payAmount = share.clamp(0, billRemaining);
        if (payAmount < 0.01) continue;
        billPayments.add(_PaymentEntry(
          mode: entry.mode,
          amount: double.parse(payAmount.toStringAsFixed(2)),
          reference: entry.reference,
          notes: entry.notes,
        ).toMap());
        billRemaining -= payAmount;
      }

      if (billPayments.isNotEmpty && billRemaining > 0.001 && billRemaining < 1.0) {
        final last = billPayments.last;
        final lastAmt = (last['amount'] as num).toDouble();
        billPayments[billPayments.length - 1] = {
          ...last,
          'amount': double.parse((lastAmt + billRemaining).toStringAsFixed(2)),
        };
      }

      if (billPayments.isEmpty) continue;

      final completer = Completer<bool>();
      socketService.emit('bill:payment', <String, dynamic>{
        'bill_id': bill.id,
        'payments': billPayments,
      }, onAck: (response) {
        if (!completer.isCompleted) {
          completer.complete(response['kind'] == 'success');
        }
      });

      final success = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      if (success) billsPaid++;
    }

    if (!mounted) return;
    if (billsPaid == widget.bills.length) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _submitting = false);
      DynamicToast.show(context,
          message:
              'Paid $billsPaid of ${widget.bills.length} bills — retry remaining',
          kind: ToastKind.error);
    }
  }

  void _addSplit() {
    if (_selectedMode == null) return;
    final amountText = _splitAmountController.text.trim();
    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) return;
    final capped = amount > _remaining ? _remaining : amount;
    if (capped <= 0) return;

    setState(() {
      _splits.add(_PaymentEntry(
        mode: _selectedMode!,
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
      canPay = (_remaining.abs() < 0.01) && !_submitting;
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
              if (_tendered > 0 && _change > 0) ...[
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
                    if (d >= widget.grandTotal * 0.5)
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
                        color: _remaining > 0.01
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

              if (_remaining > 0 && _remaining < 1.0 && _splits.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _splits.add(_PaymentEntry(
                          mode: PaymentMode.cash,
                          amount: double.parse(_remaining.toStringAsFixed(2)),
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
              if (_remaining > 0.01) ...[
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
                        gradient: _selectedMode != null
                            ? const LinearGradient(colors: [
                                AppColors.terra400,
                                AppColors.terra600
                              ])
                            : null,
                        color: _selectedMode != null
                            ? null
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
