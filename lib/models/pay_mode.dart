import 'package:collection/collection.dart';
import 'package:flutter/material.dart' show IconData, Icons;

import '../data/money.dart';
import 'wire.dart';

/// Whether a payment mode asks for a reference (UPI txn id, card slip no.).
enum PayModeReference {
  off('off'),
  optional('optional'),
  mandatory('mandatory');

  const PayModeReference(this.wire);
  final String wire;

  static PayModeReference fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return off;
  }
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

  /// An owner-made mode (`custom_…`) rather than a built-in one.
  bool get isCustom => code.startsWith('custom_');

  bool get needsReference => reference == PayModeReference.mandatory;

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

  /// The scanned or typed ticket for a cover line.
  final String? ticketCode;

  const TenderLine({
    required this.mode,
    this.amount,
    this.reference,
    this.reason,
    this.ticketCode,
  });

  bool get isCover => ticketCode != null;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'payment_mode': mode,
        if (amount != null) 'amount': amount!.toWire(),
        if (reference != null && reference!.isNotEmpty)
          'reference_number': reference,
        if (reason != null && reason!.isNotEmpty) 'mode_reason': reason,
        if (ticketCode != null) 'ticket_code': ticketCode,
      };
}
