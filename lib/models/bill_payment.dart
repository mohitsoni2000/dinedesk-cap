/// The desk's answers to `bill:payment`: what it recorded, and what the bill
/// still owes afterwards. Cover can be recorded for less than was asked (the
/// desk caps it at the ticket's balance and the bill's due), so the payment
/// sheet reads the bill back instead of assuming it is settled.
library;

import '../data/money.dart';
import '../services/log.dart';
import 'server_models.dart';
import 'wire.dart';

/// What one ticket's cover paid, as the desk recorded it.
class CoverRedemption {
  /// The ticket's QR code. Never log it.
  final String ticketCode;
  final String ticketNumber;

  /// What the ticket has left after this payment.
  final Money balanceAfter;

  const CoverRedemption({
    required this.ticketCode,
    required this.ticketNumber,
    required this.balanceAfter,
  });

  static CoverRedemption? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final code = optionalString(m, 'ticket_code');
    final number = optionalString(m, 'ticket_number');
    if (code == null && number == null) return null;
    return CoverRedemption(
      ticketCode: code ?? '',
      ticketNumber: number ?? '',
      balanceAfter: optionalMoney(m, 'cover_balance_after') ?? Money.zero,
    );
  }
}

/// The desk's result for one payment entry, in the order they were sent.
class PaymentEntryResult {
  final String? paymentId;

  /// The bill's `payment_status` right after this entry was recorded.
  final String? billPaymentStatus;

  /// Set on a cover entry.
  final CoverRedemption? cover;

  const PaymentEntryResult(
      {this.paymentId, this.billPaymentStatus, this.cover});

  factory PaymentEntryResult.fromMap(Map<String, dynamic> m) =>
      PaymentEntryResult(
        paymentId: optionalString(m, 'payment_id'),
        billPaymentStatus:
            optionalString(asMap(m['bill_status']), 'payment_status'),
        cover: CoverRedemption.tryParse(m['cover']),
      );
}

/// A `bill:payment` success ack: `{payments, bill, order, order_settled}`.
class BillPaymentAck {
  final List<PaymentEntryResult> results;

  /// The bill as the desk now has it; null when the ack carries none.
  final ServerBill? bill;

  /// What the bill's payment rows add up to (refund_due rows aside, as the
  /// desk counts them); null when the ack does not list them.
  final Money? recorded;
  final bool orderSettled;

  const BillPaymentAck({
    required this.results,
    required this.orderSettled,
    this.bill,
    this.recorded,
  });

  factory BillPaymentAck.fromAck(Map<String, dynamic> ack) {
    final rawBill = optionalMap(ack, 'bill');
    ServerBill? bill;
    Money? recorded;
    if (rawBill != null) {
      try {
        bill = ServerBill.fromMap(rawBill);
      } on WireFormatException catch (e) {
        logE('[Wire]', 'dropped the bill of a bill:payment ack', e);
      }
      final rows = rawBill['payments'];
      if (rows is List) {
        recorded = <Money>[
          for (final row in mapList(rows))
            if (optionalString(row, 'payment_mode') != 'refund_due')
              optionalMoney(row, 'amount') ?? Money.zero,
        ].sumMoney();
      }
    }
    return BillPaymentAck(
      results: <PaymentEntryResult>[
        for (final row in mapList(ack['payments']))
          PaymentEntryResult.fromMap(row),
      ],
      bill: bill,
      recorded: recorded,
      orderSettled: ack['order_settled'] == true,
    );
  }

  /// What the bill still owes: nothing once the desk calls it settled (paid
  /// or on credit), else its total less what is recorded. Null when the ack
  /// does not say: the payment went through, so the caller treats the bill
  /// as settled, as the sheet always did.
  Money? get remaining {
    final b = bill;
    if (b == null) return null;
    if (b.isPaid) return Money.zero;
    final paid = recorded;
    if (paid == null) return null;
    final left = b.totalAmount - paid;
    return left.isPositive ? left : Money.zero;
  }
}

/// A desk error ack: `{kind:'error', message, code?}`.
class AckError {
  final String? code;
  final String message;

  const AckError({required this.message, this.code});

  factory AckError.fromAck(Map<String, dynamic> ack) => AckError(
        code: optionalString(ack, 'code'),
        message: stringOr(ack, 'message', 'The desk refused this'),
      );
}
