import 'package:collection/collection.dart';
import 'package:flutter/material.dart' show IconData, Icons;

import '../data/money.dart';
import 'feature_flags.dart';
import 'wire.dart';

/// Whether a payment mode asks for a reference (UPI txn id, card slip no.).
enum PayModeReference {
  off('off'),
  optional('optional'),
  mandatory('mandatory');

  const PayModeReference(this.wire);
  final String wire;

  static PayModeReference fromWire(Object? raw) =>
      enumFromWire(values, raw, (v) => v.wire) ?? off;
}

/// A way to pay, as the desk lists it in `payment_modes` (the sync key and
/// the `payment_modes:updated` broadcast), already filtered to what this
/// user may settle a bill with.
class PayMode {
  final String code;

  /// What the button says.
  final String label;

  /// What a printed bill says.
  final String printName;

  /// Counts in the cash drawer.
  final bool isCash;

  /// Money that came in (UPI-like); false for a given-away mode such as a
  /// staff meal.
  final bool isRevenue;
  final PayModeReference reference;

  /// The desk wants a reason with this mode (sent as `mode_reason`).
  final bool requiresReason;
  final int sortOrder;

  const PayMode({
    required this.code,
    required this.label,
    required this.printName,
    this.isCash = false,
    this.isRevenue = true,
    this.reference = PayModeReference.off,
    this.requiresReason = false,
    this.sortOrder = 0,
  });

  /// The ways to pay this app has always offered, with the labels its
  /// payment sheet has always shown.
  static const PayMode cash =
      PayMode(code: 'cash', label: 'Cash', printName: 'Cash', isCash: true);
  static const PayMode upi = PayMode(
      code: 'upi',
      label: 'UPI',
      printName: 'UPI',
      reference: PayModeReference.optional);
  static const PayMode card = PayMode(
      code: 'card',
      label: 'Card',
      printName: 'Card',
      reference: PayModeReference.optional);
  static const PayMode complimentary = PayMode(
      code: 'complimentary',
      label: 'Comp',
      printName: 'Complimentary',
      isRevenue: false);
  static const PayMode credit =
      PayMode(code: 'credit', label: 'Credit', printName: 'Credit');
  static const PayMode company =
      PayMode(code: 'company', label: 'Company', printName: 'Company');

  static const List<PayMode> builtIns = <PayMode>[
    cash,
    upi,
    card,
    complimentary,
    credit,
    company,
  ];

  /// An owner-made mode (`custom_…`) rather than a built-in one.
  bool get isCustom => code.startsWith('custom_');

  bool get isBuiltIn => builtIns.any((m) => m.code == code);

  bool get needsReference => reference == PayModeReference.mandatory;

  /// Shows a reference field (UPI txn id, card approval code, …).
  bool get showsReference => reference != PayModeReference.off;

  /// Comp and Company ask why and who allowed it, sent as the payment's
  /// notes (`<reason> | Auth: <name>`), as they always have.
  bool get asksCompReason => code == 'complimentary' || code == 'company';

  /// A desk mode that wants a reason, sent as `mode_reason`.
  bool get asksModeReason => requiresReason && !asksCompReason;

  /// Credit goes on a customer's account, so one must be linked.
  bool get needsCustomer => code == 'credit';

  /// Cash offers "tendered" and the change to give back.
  bool get takesCashTendered => code == 'cash';

  IconData get icon => switch (code) {
        'cash' => Icons.payments_outlined,
        'upi' => Icons.phone_android_outlined,
        'card' => Icons.credit_card_outlined,
        'complimentary' => Icons.card_giftcard_outlined,
        'credit' => Icons.account_balance_outlined,
        'company' => Icons.business_outlined,
        _ => isCash
            ? Icons.payments_outlined
            : Icons.account_balance_wallet_outlined,
      };

  factory PayMode.fromMap(Map<String, dynamic> m) {
    const entity = 'PayMode';
    final code = requireString(m, 'code', entity);
    final label = stringOr(m, 'name', code);
    return PayMode(
      code: code,
      label: label,
      printName: stringOr(m, 'print_name', label),
      isCash: boolOr(m, 'is_cash', false),
      isRevenue: stringOr(m, 'kind', 'revenue') != 'non_revenue',
      reference: PayModeReference.fromWire(m['reference_mode']),
      requiresReason: boolOr(m, 'require_reason', false),
      sortOrder: intOr(m, 'sort_order', 0),
    );
  }

  /// The modes in [raw] (the desk's list), in its sort order. A system mode
  /// (`is_system`) never becomes a pay mode. The cover mode is taken out
  /// where the list is read (payModesProvider): cover is only ever taken
  /// through a scanned ticket.
  static List<PayMode> listFrom(Object? raw) {
    final modes = parseEach(
      <Map<String, dynamic>>[
        for (final row in mapList(raw))
          if (!boolOr(row, 'is_system', false)) row,
      ],
      PayMode.fromMap,
      'PayMode',
    );
    // Stable: modes sharing a sort_order keep the desk's order.
    mergeSort<PayMode>(modes,
        compare: (a, b) => a.sortOrder.compareTo(b.sortOrder));
    return modes;
  }
}

/// The modes the payment sheet offers this user: the built-in ones their
/// flags allow, where they always were, then the desk's own modes in its
/// sort order. A desk row that reuses a built-in code is shown once, as the
/// built-in, so the flags still decide whether it appears; a code listed
/// twice shows once. [listed] is [payModesProvider]'s list, which has
/// already dropped the cover mode: cover is only ever taken through a
/// scanned ticket.
List<PayMode> payModeCatalog({
  required FeatureFlags flags,
  required List<PayMode> listed,
}) {
  final builtInCodes = <String>{for (final m in PayMode.builtIns) m.code};
  final seen = <String>{};
  final desk = <PayMode>[
    for (final mode in listed)
      if (!builtInCodes.contains(mode.code) && seen.add(mode.code)) mode,
  ];
  // Stable: modes sharing a sort_order keep the desk's order.
  mergeSort<PayMode>(desk,
      compare: (a, b) => a.sortOrder.compareTo(b.sortOrder));
  return <PayMode>[
    PayMode.cash,
    PayMode.upi,
    PayMode.card,
    if (flags.complimentary) PayMode.complimentary,
    if (flags.customers) PayMode.credit,
    if (flags.complimentary) PayMode.company,
    ...desk,
  ];
}

/// One tender in a payment request (`bill:payment`, `ticket:issue`,
/// `qsr:checkout`).
class TenderLine {
  /// The payment-mode code (`cash`, `upi`, `custom_…`, or the cover mode).
  final String mode;

  /// Null means "whatever is left": allowed on the last pay line only, and on
  /// a cover line (up to the ticket's balance).
  final Money? amount;
  final String? reference;
  final String? reason;

  /// Free text on the payment row: a comp / company bill's "why | who
  /// allowed it", or "Round-off".
  final String? notes;

  /// The scanned or typed ticket for a cover line.
  final String? ticketCode;

  const TenderLine({
    required this.mode,
    this.amount,
    this.reference,
    this.reason,
    this.notes,
    this.ticketCode,
  });

  /// A line as [toWire] wrote it (`ticket:issue`'s narrower shape reads the
  /// same way), for a kept attempt read back from the phone.
  factory TenderLine.fromWire(Map<String, dynamic> m) => TenderLine(
        mode: requireString(m, 'payment_mode', 'TenderLine'),
        amount: Money.fromWire(m['amount']),
        reference: optionalString(m, 'reference_number'),
        reason: optionalString(m, 'mode_reason'),
        notes: optionalString(m, 'notes'),
        ticketCode: optionalString(m, 'ticket_code'),
      );

  bool get isCover => ticketCode != null;

  /// This line for [share] of the money (one bill's part of a tender).
  TenderLine withAmount(Money? share) => TenderLine(
        mode: mode,
        amount: share,
        reference: reference,
        reason: reason,
        notes: notes,
        ticketCode: ticketCode,
      );

  Map<String, dynamic> toWire() => <String, dynamic>{
        'payment_mode': mode,
        if (amount != null) 'amount': amount!.toWire(),
        if (reference != null && reference!.isNotEmpty)
          'reference_number': reference,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
        if (reason != null && reason!.isNotEmpty) 'mode_reason': reason,
        if (ticketCode != null) 'ticket_code': ticketCode,
      };
}
