import 'package:flutter/material.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../models/pay_mode.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';

/// One tender added to a split: the mode as shown, and what it sends.
class TenderEntry {
  final PayMode mode;
  final TenderLine line;

  const TenderEntry(this.mode, this.line);

  Money get amount => line.amount ?? Money.zero;
}

/// What the operator has picked in a [TenderForm]: the mode, its fields and
/// any split tenders. The screen that owns it reads [lines] when it pays.
///
/// It knows no bill. The payment sheet asks for lines covering a bill's due;
/// the counter asks for a fill line (no amount: the desk charges whatever is
/// left after cover); the ticket sale hands the form fewer modes.
class TenderFormController extends ChangeNotifier {
  TenderFormController() {
    for (final field in _fields) {
      field.addListener(notifyListeners);
    }
  }

  final TextEditingController reference = TextEditingController();

  /// Comp / Company's "why", or a desk mode's reason.
  final TextEditingController reason = TextEditingController();
  final TextEditingController authorizedBy = TextEditingController();
  final TextEditingController tendered = TextEditingController();
  final TextEditingController splitAmount = TextEditingController();

  List<TextEditingController> get _fields => <TextEditingController>[
        reference,
        reason,
        authorizedBy,
        tendered,
        splitAmount,
      ];

  PayMode? _selected;
  PayMode? get selected => _selected;

  final List<TenderEntry> _splits = <TenderEntry>[];
  List<TenderEntry> get splits => List<TenderEntry>.unmodifiable(_splits);
  Money get splitTotal => _splits.map((e) => e.amount).sumMoney();

  /// The splits cover [due], short by less than ₹1 at most: the round-off a
  /// filled last tender exists to settle. A bigger shortfall must be
  /// tendered, never charged silently to the last split (₹1,000 cash on a
  /// ₹4,000 sale would record ₹4,000 cash and lose the UPI).
  bool splitsCover(Money due) => due - splitTotal < const Money.rupees(1);

  void select(PayMode mode) {
    _selected = mode;
    notifyListeners();
  }

  String? get _reference {
    final text = reference.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Comp / Company: `<reason> | Auth: <name>`, as the sheet always sent it.
  String? get _compNotes => (_selected?.asksCompReason ?? false)
      ? '${reason.text.trim()} | Auth: ${authorizedBy.text.trim()}'
      : null;

  String? get _modeReason {
    if (!(_selected?.asksModeReason ?? false)) return null;
    final text = reason.text.trim();
    return text.isEmpty ? null : text;
  }

  /// The picked mode has what it needs: a reference it insists on, and the
  /// reason a desk mode asks for. (Comp's reason was never required.)
  bool get selectedComplete {
    final mode = _selected;
    if (mode == null) return false;
    if (mode.needsReference && _reference == null) return false;
    if (mode.asksModeReason && _modeReason == null) return false;
    return true;
  }

  bool creditBlocked({required bool hasCustomer}) =>
      (_selected?.needsCustomer ?? false) && !hasCustomer;

  Money get tenderedAmount =>
      Money.fromWire(tendered.text.trim()) ?? Money.zero;

  TenderLine? _lineFor(Money? amount) {
    final mode = _selected;
    if (mode == null) return null;
    return TenderLine(
      mode: mode.code,
      amount: amount,
      reference: _reference,
      notes: _compNotes,
      reason: _modeReason,
    );
  }

  /// What to send for [due]: the splits when [splitMode] has any, else one
  /// line for the picked mode, carrying [due] — or no amount at all when
  /// [fill] (the desk fills the balance). Empty when nothing is due; null
  /// while the picked mode still needs something (or none is picked).
  List<TenderLine>? lines({
    required Money due,
    required bool splitMode,
    bool fill = false,
  }) {
    if (!due.isPositive) return const <TenderLine>[];
    if (splitMode && _splits.isNotEmpty) {
      return <TenderLine>[for (final s in _splits) s.line];
    }
    if (!selectedComplete) return null;
    return <TenderLine>[_lineFor(fill ? null : due)!];
  }

  /// Adds the typed amount, capped at [remaining], as a split tender of the
  /// picked mode, then clears the pick and its fields (not "tendered").
  /// False when there is nothing to add.
  bool addSplit({required Money remaining}) {
    if (_selected == null || !selectedComplete) return false;
    final amount = Money.fromWire(splitAmount.text.trim());
    if (amount == null || !amount.isPositive) return false;
    final capped = amount > remaining ? remaining : amount;
    if (!capped.isPositive) return false;
    _splits.add(TenderEntry(_selected!, _lineFor(capped)!));
    _selected = null;
    splitAmount.clear();
    reference.clear();
    reason.clear();
    authorizedBy.clear();
    notifyListeners();
    return true;
  }

  void removeSplitAt(int index) {
    _splits.removeAt(index);
    notifyListeners();
  }

  /// Settles a shortfall under ₹1 as cash round-off.
  void addRoundOff(Money remaining) {
    _splits.add(TenderEntry(
      PayMode.cash,
      TenderLine(
          mode: PayMode.cash.code, amount: remaining, notes: 'Round-off'),
    ));
    notifyListeners();
  }

  /// Back to nothing picked: after a payment spent what was entered.
  void reset() {
    _selected = null;
    _splits.clear();
    for (final field in _fields) {
      field.clear();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }
}

/// The payment-mode picker and its fields: reference, reason, cash tendered
/// and change, and split tenders when [allowSplit]. [due] is what the
/// tenders must cover.
class TenderForm extends StatelessWidget {
  final TenderFormController controller;
  final List<PayMode> modes;
  final Money due;
  final bool allowSplit;

  /// Credit needs a customer linked to the order.
  final bool hasCustomer;
  final bool enabled;

  const TenderForm({
    super.key,
    required this.controller,
    required this.modes,
    required this.due,
    this.allowSplit = false,
    this.hasCustomer = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => IgnorePointer(
        ignoring: !enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _children(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final c = controller;
    final selected = c.selected;
    final remaining = due - c.splitTotal;
    final change = c.tenderedAmount - due;
    return <Widget>[
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
              label: mode.label,
              icon: mode.icon,
              selected: selected?.code == mode.code,
              onTap: () => c.select(mode),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (c.creditBlocked(hasCustomer: hasCustomer))
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.all(AppRadii.sm),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
          ),
          child: const Row(children: [
            Icon(Icons.warning_amber, color: AppColors.danger, size: 16),
            SizedBox(width: 8),
            Expanded(
                child: Text('Link a customer to use Credit',
                    style: AppTypography.caption)),
          ]),
        ),
      if (selected != null && selected.showsReference) ...[
        const SizedBox(height: 12),
        Text(
            selected.needsReference
                ? 'REFERENCE NUMBER (REQUIRED)'
                : 'REFERENCE NUMBER',
            style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 8),
        _InputField(
          controller: c.reference,
          hint: switch (selected.code) {
            'upi' => 'UPI transaction ID',
            'card' => 'Card approval code',
            _ => 'Reference number',
          },
        ),
      ],
      if (selected != null && selected.asksCompReason) ...[
        const SizedBox(height: 12),
        Text('REASON', style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 8),
        _InputField(
            controller: c.reason, hint: 'Reason for comp / company bill'),
        const SizedBox(height: 8),
        _InputField(controller: c.authorizedBy, hint: 'Authorized by (name)'),
      ],
      if (selected != null && selected.asksModeReason) ...[
        const SizedBox(height: 12),
        Text('REASON (REQUIRED)',
            style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 8),
        _InputField(controller: c.reason, hint: 'Reason'),
      ],
      if ((selected?.takesCashTendered ?? false) &&
          !(allowSplit && c.splits.isNotEmpty)) ...[
        const SizedBox(height: 12),
        Text('CASH TENDERED',
            style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 8),
        _InputField(
          controller: c.tendered,
          hint: formatRupeesCompact(due),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          prefix: '₹ ',
        ),
        if (c.tenderedAmount.isPositive && change.isPositive) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.all(AppRadii.sm),
              border:
                  Border.all(color: AppColors.success.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.change_circle_outlined,
                  color: AppColors.success, size: 18),
              const SizedBox(width: 8),
              const Text('Change:', style: AppTypography.bodyMd),
              const Spacer(),
              Text(formatRupeesCompact(change),
                  style: AppTypography.title.copyWith(
                      color: AppColors.success, fontWeight: FontWeight.w700)),
            ]),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in [100, 200, 500, 1000, 2000])
              if (Money.rupees(d) >= due)
                GestureDetector(
                  onTap: () => c.tendered.text = d.toString(),
                  child: AppSurface(
                    borderRadius: const BorderRadius.all(AppRadii.pill),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shadow: const [],
                    child: Text('₹$d',
                        style: AppTypography.caption
                            .copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
          ],
        ),
      ],
      if (allowSplit) ...[
        const SizedBox(height: 12),
        Divider(color: context.palette.ink10),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.call_split_outlined,
              color: context.palette.ink70, size: 18),
          const SizedBox(width: 8),
          // The label gives way on a narrow phone; the amount never does.
          const Expanded(
            child: Text('Split Payment',
                style: AppTypography.bodyMd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Text('Remaining: ${formatRupeesCompact(remaining)}',
              style: AppTypography.caption.copyWith(
                  color: remaining.isPositive
                      ? AppColors.terra500
                      : AppColors.success,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 8),
        for (int i = 0; i < c.splits.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: AppSurface(
              borderRadius: const BorderRadius.all(AppRadii.sm),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shadow: const [],
              child: Row(children: [
                Icon(c.splits[i].mode.icon,
                    size: 16, color: context.palette.ink70),
                const SizedBox(width: 8),
                Text(c.splits[i].mode.label, style: AppTypography.bodyMd),
                const Spacer(),
                Text(formatRupeesCompact(c.splits[i].amount),
                    style: AppTypography.bodyMd
                        .copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => c.removeSplitAt(i),
                  child: const Icon(Icons.close,
                      size: 16, color: AppColors.danger),
                ),
              ]),
            ),
          ),
        if (remaining.isPositive &&
            remaining < const Money.rupees(1) &&
            c.splits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => c.addRoundOff(remaining),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.1),
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border:
                      Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.monetization_on_outlined,
                      color: AppColors.amber, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          'Settle ${formatRupeesCompact(remaining)} shortfall (round-off)',
                          style: AppTypography.caption
                              .copyWith(fontWeight: FontWeight.w600))),
                  const Icon(Icons.add_circle_outline,
                      color: AppColors.amber, size: 16),
                ]),
              ),
            ),
          ),
        if (remaining.isPositive) ...[
          Row(children: [
            Expanded(
                child: _InputField(
              controller: c.splitAmount,
              hint: formatRupeesCompact(remaining),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              prefix: '₹ ',
            )),
            const SizedBox(width: 8),
            // Live only once the picked mode has what it needs (a mandatory
            // reference, a reason): addSplit refuses before that, and a
            // button that looks ready but does nothing reads as broken.
            GestureDetector(
              key: const ValueKey<String>('tender-add-split'),
              onTap: c.selectedComplete
                  ? () => c.addSplit(remaining: remaining)
                  : null,
              child: Container(
                width: AppTouchTargets.control,
                height: AppTouchTargets.control,
                decoration: BoxDecoration(
                  color: c.selectedComplete
                      ? AppColors.terra500
                      : context.palette.ink05,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                ),
                child: Icon(Icons.add,
                    color: c.selectedComplete
                        ? Colors.white
                        : context.palette.ink30),
              ),
            ),
          ]),
        ],
      ],
    ];
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  final String? prefix;
  const _InputField({
    required this.controller,
    required this.hint,
    this.keyboardType,
    this.prefix,
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
