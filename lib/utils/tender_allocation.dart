/// How the money a guest hands over is spread across an order's bills: one
/// `bill:payment` per bill, each carrying that bill's part of every tender.
/// Entry-ticket cover goes first, to the food and drink bills; the other
/// tenders then split over what each bill still owes.
library;

import 'package:collection/collection.dart';

import '../data/money.dart';
import '../models/pay_mode.dart';
import '../models/server_models.dart';

/// The bill types cover may pay, in the order it is applied: food first, then
/// beverages, liquor, and a combined bill last. A room bill is never one.
const List<String> coverBillOrder = <String>[
  'food',
  'beverages',
  'liquor',
  'combined',
];

/// Whether a guest's cover may pay [bill]: a food or drink bill still open
/// for payment. The desk refuses room, comp, credit, paid and voided bills.
bool isCoverEligible(ServerBill bill) =>
    coverBillOrder.contains(bill.billType.toLowerCase()) &&
    !bill.isPaid &&
    !bill.isVoided &&
    !bill.isComp;

/// One entry ticket's cover, applied to this payment.
class AppliedCover {
  /// The ticket itself, however it was typed or scanned (its id from the
  /// lookup), so the same ticket is never added twice.
  final String key;

  /// What `bill:payment` names the ticket by: its QR code.
  final String code;
  final String ticketNumber;
  final String typeName;

  /// What the ticket had left when it was looked up.
  final Money balance;

  /// What this payment takes from it.
  final Money amount;

  const AppliedCover({
    required this.key,
    required this.code,
    required this.ticketNumber,
    required this.typeName,
    required this.balance,
    required this.amount,
  });

  /// The tender for this cover, recorded under [coverMode]. [fill] leaves the
  /// amount to the desk (counter checkout: up to the ticket's balance and what
  /// the food and drink bills owe).
  TenderLine toLine(String coverMode, {bool fill = false}) => TenderLine(
        mode: coverMode,
        amount: fill ? null : amount,
        ticketCode: code,
      );
}

/// A bill as a payment plan sees it.
class PlanBill {
  final String id;
  final String billType;

  /// What it still owes.
  final Money due;
  final bool coverEligible;

  const PlanBill({
    required this.id,
    required this.billType,
    required this.due,
    required this.coverEligible,
  });

  int get _coverRank => coverBillOrder.indexOf(billType.toLowerCase());
}

/// One `bill:payment`: a bill and every line it carries, cover first.
class BillPaymentCall {
  final String billId;
  final List<TenderLine> lines;

  const BillPaymentCall({required this.billId, required this.lines});

  Map<String, dynamic> toPayload() => <String, dynamic>{
        'bill_id': billId,
        'payments': <Map<String, dynamic>>[
          for (final line in lines) line.toWire(),
        ],
      };
}

/// The `bill:payment` calls that take [covers] and [tenders] for [bills],
/// in the bills' order; a bill nothing lands on gets no call.
///
/// Each cover, in the order added, fills the cover-eligible bills food →
/// beverages → liquor → combined, splitting across bills when one is not
/// enough. [tenders] then split, as they always have, over what each bill
/// still owes. Throws [ArgumentError] when a cover is more than the eligible
/// bills owe: amounts are capped when a ticket is added, so that is a bug.
List<BillPaymentCall> planBillPayments({
  required List<PlanBill> bills,
  required List<AppliedCover> covers,
  required String? coverMode,
  required List<TenderLine> tenders,
}) {
  final owed = <String, Money>{for (final bill in bills) bill.id: bill.due};
  final coverLines = <String, List<TenderLine>>{
    for (final bill in bills) bill.id: <TenderLine>[],
  };
  if (covers.isNotEmpty) {
    if (coverMode == null) {
      throw ArgumentError.value(
          null, 'coverMode', 'cover without a cover mode');
    }
    final eligible = <PlanBill>[
      for (final bill in bills)
        if (bill.coverEligible && bill._coverRank >= 0) bill,
    ];
    // Stable: bills of one type keep their order.
    mergeSort<PlanBill>(eligible,
        compare: (a, b) => a._coverRank.compareTo(b._coverRank));
    for (final cover in covers) {
      var left = cover.amount;
      for (final bill in eligible) {
        if (!left.isPositive) break;
        final room = owed[bill.id]!;
        if (!room.isPositive) continue;
        final take = left < room ? left : room;
        coverLines[bill.id]!.add(TenderLine(
          mode: coverMode,
          amount: take,
          ticketCode: cover.code,
        ));
        owed[bill.id] = room - take;
        left -= take;
      }
      if (left.isPositive) {
        throw ArgumentError.value(
            cover.amount, 'covers', 'more than the bills cover may pay owe');
      }
    }
  }
  final split = allocateTenders(
    bills: <BillWeight>[
      for (final bill in bills) (billId: bill.id, weight: owed[bill.id]!),
    ],
    tenders: tenders,
  );
  return <BillPaymentCall>[
    for (final bill in bills)
      if (coverLines[bill.id]!.isNotEmpty || split[bill.id]!.isNotEmpty)
        BillPaymentCall(
          billId: bill.id,
          lines: <TenderLine>[...coverLines[bill.id]!, ...split[bill.id]!],
        ),
  ];
}

/// A bill and what it weighs in a split: its total, or what it still owes.
typedef BillWeight = ({String billId, Money weight});

/// Splits each tender across [bills] in proportion to their weights (largest
/// remainder, so a tender's shares add up to it exactly) and returns each
/// bill's lines, keyed by bill id in the order given. Every bill gets a list,
/// empty when nothing lands on it; a share that rounds to nothing is left
/// out rather than sent as ₹0.
///
/// This is the payment sheet's original split, moved here unchanged (see
/// test/payment_allocation_test.dart). Every tender needs an amount: a "fill
/// the rest" line is the desk's to place, not this function's.
Map<String, List<TenderLine>> allocateTenders({
  required List<BillWeight> bills,
  required List<TenderLine> tenders,
}) {
  final weights = <Money>[for (final bill in bills) bill.weight];
  final perBill = <String, List<TenderLine>>{
    for (final bill in bills) bill.billId: <TenderLine>[],
  };
  for (final tender in tenders) {
    final amount = tender.amount;
    if (amount == null) {
      throw ArgumentError.value(
          tender.mode, 'tenders', 'a split tender needs an amount');
    }
    final shares = allocateProportionally(amount, weights);
    for (var i = 0; i < bills.length; i++) {
      final share = shares[i];
      if (share.isZero) continue;
      perBill[bills[i].billId]!.add(tender.withAmount(share));
    }
  }
  return perBill;
}
