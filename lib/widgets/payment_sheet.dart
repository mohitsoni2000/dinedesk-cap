// Payment Sheet — bottom sheet for collecting payment after bill generation.
//
// Simple mode: select one payment mode, full amount, pay.
// Split mode (if flags.splitPayment): add multiple payments totaling the bill.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../utils/socket_helpers.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';

class PaymentSheet {
  /// Shows the payment bottom sheet. Returns `true` if payment was collected.
  static Future<bool?> show(
    BuildContext context, {
    required String billId,
    required double totalAmount,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _PaymentSheet(billId: billId, totalAmount: totalAmount),
    );
  }
}

enum _PaymentMode { cash, upi, card, complimentary, credit, company }

class _PaymentEntry {
  final _PaymentMode mode;
  final double amount;
  final String? reference;
  const _PaymentEntry({
    required this.mode,
    required this.amount,
    this.reference,
  });

  _PaymentEntry copyWith({double? amount, String? reference}) => _PaymentEntry(
    mode: mode,
    amount: amount ?? this.amount,
    reference: reference ?? this.reference,
  );

  Map<String, dynamic> toMap() => {
    'payment_mode': mode.name,
    'amount': amount,
    if (reference != null && reference!.isNotEmpty) 'reference_number': reference,
  };
}

String _modeLabel(_PaymentMode m) => switch (m) {
  _PaymentMode.cash         => 'Cash',
  _PaymentMode.upi          => 'UPI',
  _PaymentMode.card         => 'Card',
  _PaymentMode.complimentary => 'Comp',
  _PaymentMode.credit       => 'Credit',
  _PaymentMode.company      => 'Company',
};

IconData _modeIcon(_PaymentMode m) => switch (m) {
  _PaymentMode.cash         => Icons.payments_outlined,
  _PaymentMode.upi          => Icons.phone_android_outlined,
  _PaymentMode.card         => Icons.credit_card_outlined,
  _PaymentMode.complimentary => Icons.card_giftcard_outlined,
  _PaymentMode.credit       => Icons.account_balance_outlined,
  _PaymentMode.company      => Icons.business_outlined,
};

class _PaymentSheet extends ConsumerStatefulWidget {
  final String billId;
  final double totalAmount;
  const _PaymentSheet({required this.billId, required this.totalAmount});
  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  _PaymentMode? _selectedMode;
  final _refController = TextEditingController();
  bool _submitting = false;

  // Split payment state
  final List<_PaymentEntry> _splits = [];
  final _splitAmountController = TextEditingController();

  double get _paidSoFar => _splits.fold(0.0, (s, e) => s + e.amount);
  double get _remaining => widget.totalAmount - _paidSoFar;

  List<_PaymentMode> _availableModes(WidgetRef ref) {
    final modes = <_PaymentMode>[
      _PaymentMode.cash,
      _PaymentMode.upi,
      _PaymentMode.card,
    ];
    final op = ref.read(operatorProvider);
    if (op != null && (op.role == 'admin' || op.role == 'manager')) {
      modes.addAll([
        _PaymentMode.complimentary,
        _PaymentMode.credit,
        _PaymentMode.company,
      ]);
    }
    return modes;
  }

  Future<void> _pay() async {
    if (_submitting) return;
    _submitting = true;
    setState(() {});
    HapticFeedback.heavyImpact();

    final flags = ref.read(flagsProvider);
    List<Map<String, dynamic>> payments;

    if (flags.splitPayment && _splits.isNotEmpty) {
      // Split mode: use accumulated entries
      payments = _splits.map((e) => e.toMap()).toList();
    } else {
      // Simple mode: single payment for full amount
      payments = [
        _PaymentEntry(
          mode: _selectedMode!,
          amount: widget.totalAmount,
          reference: _refController.text.trim().isNotEmpty
              ? _refController.text.trim()
              : null,
        ).toMap(),
      ];
    }

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('bill:payment', {
      'bill_id': widget.billId,
      'payments': payments,
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              response['message']?.toString() ?? 'Payment failed',
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
      } else {
        Navigator.of(context).pop(true);
      }
    });

    // Timeout fallback
    scheduleSocketTimeout(
      duration: const Duration(seconds: 10),
      isMounted: () => mounted,
      isStillWaiting: () => _submitting,
      onTimeout: () {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('Payment timed out — please retry'),
          ));
      },
    );
  }

  void _addSplit() {
    if (_selectedMode == null) return;
    final amountText = _splitAmountController.text.trim();
    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) return;
    final capped = amount > _remaining ? _remaining : amount;
    if (capped <= 0) return;

    HapticFeedback.selectionClick();
    setState(() {
      _splits.add(_PaymentEntry(
        mode: _selectedMode!,
        amount: capped,
        reference: _refController.text.trim().isNotEmpty
            ? _refController.text.trim()
            : null,
      ));
      _splitAmountController.clear();
      _refController.clear();
      _selectedMode = null;
    });
  }

  void _removeSplit(int index) {
    HapticFeedback.selectionClick();
    setState(() => _splits.removeAt(index));
  }

  @override
  void dispose() {
    _refController.dispose();
    _splitAmountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(flagsProvider);
    final isSplitMode = flags.splitPayment;
    final modes = _availableModes(ref);
    final needsRef = _selectedMode == _PaymentMode.upi ||
                     _selectedMode == _PaymentMode.card;

    final bool canPay;
    if (isSplitMode && _splits.isNotEmpty) {
      canPay = (_remaining.abs() < 0.01) && !_submitting;
    } else {
      canPay = _selectedMode != null && !_submitting;
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, scrollCtrl) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.fromLTRB(
          20, 12, 20, 28 + MediaQuery.of(context).viewPadding.bottom),
        child: ListView(
          controller: scrollCtrl,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.ink30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                const Icon(Icons.payment_outlined,
                  color: AppColors.terra500, size: 22),
                const SizedBox(width: 10),
                const Text('Collect Payment', style: AppTypography.title),
                const Spacer(),
                Text(formatRupeesCompact(widget.totalAmount),
                  style: AppTypography.headline),
              ],
            ),
            const SizedBox(height: 20),

            // Payment mode grid
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
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedMode = mode);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // Reference field for UPI/Card
            if (needsRef) ...[
              Text('REFERENCE NUMBER',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.paper,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: AppColors.ink10),
                ),
                child: TextField(
                  controller: _refController,
                  style: AppTypography.bodyMd,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: _selectedMode == _PaymentMode.upi
                        ? 'UPI transaction ID'
                        : 'Card approval code',
                    hintStyle: AppTypography.caption,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Split payment section
            if (isSplitMode) ...[
              const Divider(color: AppColors.ink10),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.call_split_outlined,
                    color: AppColors.ink70, size: 18),
                  const SizedBox(width: 8),
                  const Text('Split Payment', style: AppTypography.bodyMd),
                  const Spacer(),
                  Text('Remaining: ${formatRupeesCompact(_remaining)}',
                    style: AppTypography.caption.copyWith(
                      color: _remaining > 0.01
                          ? AppColors.terra500
                          : AppColors.success,
                      fontWeight: FontWeight.w600,
                    )),
                ],
              ),
              const SizedBox(height: 10),

              // Split entries list
              if (_splits.isNotEmpty) ...[
                for (int i = 0; i < _splits.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.paper,
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(color: AppColors.ink10),
                      ),
                      child: Row(
                        children: [
                          Icon(_modeIcon(_splits[i].mode),
                            size: 16, color: AppColors.ink70),
                          const SizedBox(width: 8),
                          Text(_modeLabel(_splits[i].mode),
                            style: AppTypography.bodyMd),
                          if (_splits[i].reference != null) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '(${_splits[i].reference})',
                                style: AppTypography.caption,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          const Spacer(),
                          Text(formatRupeesCompact(_splits[i].amount),
                            style: AppTypography.bodyMd.copyWith(
                              fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => _removeSplit(i),
                            child: const Icon(Icons.close,
                              size: 16, color: AppColors.danger),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],

              // Add split entry row
              if (_remaining > 0.01) ...[
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: AppColors.paper,
                          borderRadius: const BorderRadius.all(AppRadii.sm),
                          border: Border.all(color: AppColors.ink10),
                        ),
                        child: TextField(
                          controller: _splitAmountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                          style: AppTypography.bodyMd,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: formatRupeesCompact(_remaining),
                            hintStyle: AppTypography.caption,
                            isDense: true,
                            prefixText: '\u20B9 ',
                            prefixStyle: AppTypography.bodyMd,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _selectedMode != null ? _addSplit : null,
                      child: Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          gradient: _selectedMode != null
                            ? const LinearGradient(
                                colors: [AppColors.terra400, AppColors.terra600])
                            : null,
                          color: _selectedMode != null ? null : AppColors.ink05,
                          borderRadius: const BorderRadius.all(AppRadii.sm),
                        ),
                        child: Icon(Icons.add,
                          color: _selectedMode != null
                            ? Colors.white
                            : AppColors.ink30,
                          size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ],

            const SizedBox(height: 12),

            // CTA buttons
            Row(
              children: [
                Expanded(
                  child: LiquidSecondaryButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LiquidPrimaryButton(
                    label: _submitting ? 'Processing...' : 'Pay',
                    fullWidth: true,
                    leadingIcon: _submitting
                        ? Icons.hourglass_top
                        : Icons.check_circle_outline,
                    onPressed: canPay ? _pay : null,
                  ),
                ),
              ],
            ),
          ],
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
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
            color: selected ? AppColors.ink : AppColors.ink10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16,
              color: selected ? Colors.white : AppColors.ink70),
            const SizedBox(width: 6),
            Text(label,
              style: AppTypography.bodyMd.copyWith(
                color: selected ? Colors.white : AppColors.ink,
                fontWeight: FontWeight.w600,
              )),
          ],
        ),
      ),
    );
  }
}
