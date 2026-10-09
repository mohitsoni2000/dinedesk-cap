/// Counter "Pay & Fire": one `qsr:checkout` makes the order, fires its KOT,
/// gives it its token, bills it and records the payment, in a single desk
/// transaction (spec §2.7). Crew only ever sends it as `pay_and_fire`, the
/// prepaid path; "fire now, pay at pickup" goes through `order:create` +
/// `kot:send` instead, which can queue offline. Money never queues: this
/// needs a live desk.
///
/// It is a money event: an explicit 15s ack timeout, and one
/// `client_request_id` per checkout attempt. An answer that never came may
/// still have gone through, so the attempt is kept and a retry sends exactly
/// the same request; the desk then replays its result instead of charging
/// twice.
///
/// Logs say counts, modes and outcome codes; never a guest, a ticket code or
/// what was ordered.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/money.dart';
import '../data/providers.dart';
import '../models/pay_mode.dart';
import '../models/server_models.dart';
import '../models/token.dart';
import '../models/wire.dart';
import '../utils/request_id.dart';
import 'entry_ticket_service.dart';
import 'log.dart';
import 'socket_service.dart';

final Provider<QsrCheckoutService> qsrCheckoutServiceProvider =
    Provider<QsrCheckoutService>(
        (ref) => QsrCheckoutService(ref.read(socketServiceProvider)));

const String _tag = '[QsrCheckout]';

/// How long the desk has to answer before the outcome counts as unknown.
const Duration kQsrCheckoutTimeout = Duration(seconds: 15);

/// One Pay & Fire attempt, exactly as it goes to the desk.
///
/// [clientRequestId] belongs to the attempt: an unanswered attempt is retried
/// with this same request. A new attempt (the cart changed, or the cashier
/// accepted the desk's new total) is a new request with a new id.
class QsrCheckoutRequest {
  QsrCheckoutRequest({
    required this.fulfillment,
    required this.items,
    required this.payments,
    this.notes = '',
    this.customerId,
    this.expectedTotal,
    String? clientRequestId,
  })  : clientRequestId = clientRequestId ?? newRequestId(),
        _sent = null;

  QsrCheckoutRequest._restored({
    required this.fulfillment,
    required this.items,
    required this.payments,
    required this.notes,
    required this.customerId,
    required this.expectedTotal,
    required this.clientRequestId,
    required Map<String, dynamic> sent,
  }) : _sent = sent;

  /// A kept attempt read back from the phone ([toPayload] as it was sent).
  /// Its [toPayload] is that very payload, id included, so a retry after a
  /// restart is the same request. Throws [WireFormatException] when it
  /// cannot be read.
  factory QsrCheckoutRequest.restore(Map<String, dynamic> payload) {
    const entity = 'QsrCheckoutRequest';
    final fulfillment = FulfillmentType.fromWire(payload['fulfillment_type']);
    if (fulfillment == null) {
      throw WireFormatException(
          entity: entity,
          field: 'fulfillment_type',
          reason: 'missing or unknown',
          received: payload['fulfillment_type']);
    }
    return QsrCheckoutRequest._restored(
      fulfillment: fulfillment,
      items: mapList(payload['items']),
      payments: <TenderLine>[
        for (final line in mapList(payload['payments']))
          TenderLine.fromWire(line),
      ],
      notes: stringOr(payload, 'notes', ''),
      customerId: optionalString(payload, 'customer_id'),
      expectedTotal: optionalMoney(payload, 'expected_total'),
      clientRequestId: requireString(payload, 'client_request_id', entity),
      sent: Map<String, dynamic>.from(payload),
    );
  }

  /// What a restored attempt sent; null for one made on this run.
  final Map<String, dynamic>? _sent;

  final FulfillmentType fulfillment;

  /// `order:create`'s item shape.
  final List<Map<String, dynamic>> items;

  /// Cover lines first, then the pay tenders. Cover lines and the last pay
  /// line carry no amount: the desk fills them from the real bill.
  final List<TenderLine> payments;
  final String notes;
  final String? customerId;

  /// The total the cashier was shown. The desk refuses with `price_changed`
  /// when its bill differs, so nobody is charged what they were not told.
  final Money? expectedTotal;
  final String clientRequestId;

  /// The same order at the desk's [total], which the cashier accepted: a new
  /// attempt, so a new id.
  QsrCheckoutRequest withExpectedTotal(Money total) => QsrCheckoutRequest(
        fulfillment: fulfillment,
        items: items,
        payments: payments,
        notes: notes,
        customerId: customerId,
        expectedTotal: total,
      );

  Map<String, dynamic> toPayload() => _sent != null
      ? Map<String, dynamic>.from(_sent)
      : <String, dynamic>{
          'fulfillment_type': fulfillment.wire,
          'items': items,
          if (notes.trim().isNotEmpty) 'notes': notes.trim(),
          if (customerId != null && customerId!.isNotEmpty)
            'customer_id': customerId,
          'mode': 'pay_and_fire',
          'payments': <Map<String, dynamic>>[
            for (final line in payments) line.toWire(),
          ],
          if (expectedTotal != null) 'expected_total': expectedTotal!.toWire(),
          'client_request_id': clientRequestId,
        };
}

/// The desk's success ack, read for what the counter needs: the token, the
/// order for history, the KOT number and the bills to print.
class QsrCheckoutAck {
  const QsrCheckoutAck({
    required this.raw,
    required this.token,
    required this.orderId,
    required this.kotNumber,
    required this.bills,
    required this.orderSettled,
  });

  final Map<String, dynamic> raw;
  final TokenInfo? token;
  final String? orderId;
  final String? kotNumber;
  final List<ServerBill> bills;
  final bool orderSettled;

  /// What the bills came to: the real figure, where the screen had an
  /// estimate.
  Money get total => bills.map((b) => b.totalAmount).sumMoney();

  factory QsrCheckoutAck.fromAck(Map<String, dynamic> ack) {
    final order = optionalMap(ack, 'order');
    final kot = optionalMap(ack, 'kot');
    return QsrCheckoutAck(
      raw: ack,
      token: TokenInfo.fromAck(ack),
      orderId: order == null ? null : optionalString(order, 'id'),
      kotNumber: (kot == null ? null : optionalString(kot, 'kot_number')) ??
          (order == null ? null : optionalString(order, 'kot_number')),
      bills: parseEach(mapList(ack['bills']), ServerBill.fromMap, 'ServerBill'),
      orderSettled: ack['order_settled'] == true,
    );
  }
}

/// How a Pay & Fire ended.
sealed class QsrCheckoutResult {
  const QsrCheckoutResult();
}

/// Paid, fired and tokened.
final class QsrCheckoutOk extends QsrCheckoutResult {
  const QsrCheckoutOk(this.ack);
  final QsrCheckoutAck ack;
}

/// The desk said no: nothing was made, charged or fired.
final class QsrCheckoutRejected extends QsrCheckoutResult {
  const QsrCheckoutRejected({
    required this.code,
    required this.message,
    this.newTotal,
  });

  /// The lower-cased §2.10 code (`price_changed`, `cover_empty`, …).
  final String? code;

  /// What to tell the cashier.
  final String message;

  /// For `price_changed`: the desk's total, when it said.
  final Money? newTotal;

  bool get priceChanged => code == 'price_changed';

  /// A business refusal: the desk priced the order, or checked a tender, a
  /// ticket, the menu or its counter mode, and said no before writing
  /// anything. Only these prove an attempt never went through. Anything
  /// else (`reauth_required`, an error with no code) might follow a write
  /// that did happen, so an attempt it answers is kept, not dropped.
  bool get isBusinessRefusal {
    final c = code;
    if (c == null) return false;
    return _businessRefusals.contains(c) ||
        c.startsWith('payment_') ||
        c.startsWith('cover_') ||
        c.startsWith('ticket_');
  }

  bool get needsPin => code == 'reauth_required';
}

const Set<String> _businessRefusals = <String>{
  'price_changed',
  'item_unavailable',
  'menu_blocked',
  'flow_blocked',
  'qsr_disabled',
};

/// No answer: it may have gone through. Retry the SAME request; never edit
/// it, never start a new one, until the desk has answered.
final class QsrCheckoutUnconfirmed extends QsrCheckoutResult {
  const QsrCheckoutUnconfirmed();
}

/// Not sent: the desk is not reachable, and money never queues.
final class QsrCheckoutOffline extends QsrCheckoutResult {
  const QsrCheckoutOffline();
}

/// The cashier's words for an unanswered Pay & Fire.
const String kCheckoutNoAnswer = "The desk didn't answer — it may have gone "
    'through. Retry sends exactly the same order.';

/// Staff words for a `qsr:checkout` error code (spec §2.10, lower-cased), or
/// null for one this app does not word itself: show the desk's message then.
String? qsrCheckoutErrorCopy(String? code) => switch (code) {
      'price_changed' => 'Prices changed on the desk — check the new total',
      'item_unavailable' => 'Something in the cart is no longer available — '
          'remove it and try again',
      'menu_blocked' => "Something in the cart can't be sold at the counter "
          '— remove it and try again',
      'flow_blocked' => 'The desk now takes payment at pickup here — use '
          'Fire KOT',
      'qsr_disabled' => 'The desk is no longer in counter mode',
      'permission_denied' => "You can't take payment at the counter — ask "
          'the desk',
      'reauth_required' => 'Enter your PIN again, then retry',
      _ => coverErrorCopy(code),
    };

final RegExp _rupees = RegExp(r'₹\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)');

/// The desk's new total from a `price_changed` refusal: its `total`, else the
/// rupee figure in its message (`Total is now ₹1,250`).
Money? priceChangedTotal(Map<String, dynamic> ack) {
  final direct =
      optionalMoney(ack, 'total') ?? optionalMoney(ack, 'expected_total');
  if (direct != null) return direct;
  final match = _rupees.firstMatch(optionalString(ack, 'message') ?? '');
  return match == null
      ? null
      : Money.fromWire(match.group(1)!.replaceAll(',', ''));
}

class QsrCheckoutService {
  QsrCheckoutService(this._socket);

  final SocketService _socket;

  /// Sends [request] once. Never throws.
  Future<QsrCheckoutResult> payAndFire(QsrCheckoutRequest request) async {
    final payload = request.toPayload();
    final modes = <String>{for (final p in request.payments) p.mode};
    if (_socket.state != SocketState.verified) {
      logD(_tag, 'pay & fire not sent: the desk is not reachable');
      return const QsrCheckoutOffline();
    }
    logD(
        _tag,
        'pay & fire: ${request.items.length} line(s), '
        'modes ${modes.isEmpty ? 'none' : modes.join('/')}');
    final ack = await _socket.emitAck('qsr:checkout', payload,
        timeout: kQsrCheckoutTimeout);
    if (ack['kind'] == 'success') {
      // Lenient: a malformed bill is dropped, never a reason to doubt that
      // the desk took the order.
      final parsed = QsrCheckoutAck.fromAck(ack);
      logD(
          _tag,
          'pay & fire ok: ${parsed.bills.length} bill(s), '
          'token ${parsed.token == null ? 'none' : 'given'}');
      return QsrCheckoutOk(parsed);
    }
    final code = optionalString(ack, 'code');
    if (isTransportFailure(ack) || code == AckCode.badResponse) {
      logD(_tag, 'pay & fire got no answer (${code ?? 'no code'})');
      return const QsrCheckoutUnconfirmed();
    }
    logD(_tag, 'pay & fire refused: ${code ?? 'no code'}');
    final desk = optionalString(ack, 'message');
    return QsrCheckoutRejected(
      code: code,
      message: namedTicketRefusal(code, desk,
              tickets: request.payments.where((p) => p.isCover).length) ??
          qsrCheckoutErrorCopy(code) ??
          desk ??
          "The desk couldn't take "
              'this order',
      newTotal: code == 'price_changed' ? priceChangedTotal(ack) : null,
    );
  }
}
