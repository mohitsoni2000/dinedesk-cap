import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/money.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../models/pay_mode.dart';
import '../models/wire.dart';
import '../utils/request_id.dart';
import '../utils/tender_allocation.dart';
import 'kot_queue_service.dart' show isReauthRequired;
import 'log.dart';
import 'qsr_checkout_service.dart' show priceChangedTotal;
import 'socket_service.dart';

/// Entry tickets on the desk: selling them at the gate (`ticket:issue`),
/// checking guests in (`ticket:check_in`), today's list (`ticket:recent`),
/// and looking one up (`ticket:lookup`, also to take its cover as payment).
/// The desk is the only authority on a ticket (its balance, its day, whether
/// it was used or cancelled), so every answer comes from it.
///
/// A sale and a check-in are money events: an explicit 15s ack, and one
/// `client_request_id` per attempt. An answer that never came may still have
/// gone through, so the attempt is kept and a retry sends exactly the same
/// request; the desk then replays its answer instead of selling twice or
/// reading its own check-in back as "already used". A `reauth_required`
/// asks for the PIN once and resends that same request.
///
/// Logs carry outcomes, counts and modes only: never a ticket code, number,
/// search text or guest.
final Provider<EntryTicketService> entryTicketServiceProvider =
    Provider<EntryTicketService>((ref) => EntryTicketService(
          ref.read(socketServiceProvider),
          reauth: () => ref.read(syncServiceProvider).handleReauthRequired(),
        ));

const String _tag = '[Tickets]';

/// How long the desk has to answer a sale or a check-in before the outcome
/// counts as unknown.
const Duration kTicketMoneyTimeout = Duration(seconds: 15);

/// Asks the operator for their PIN again; true once it was entered.
typedef ReauthPrompt = Future<bool> Function();

/// Why a ticket is being looked up. `redeem` asks whether its cover can pay
/// a bill; `peek` (the gate) reads it without that question.
enum TicketLookupPurpose {
  redeem('redeem'),
  peek('peek');

  const TicketLookupPurpose(this.wire);
  final String wire;
}

/// A `ticket:lookup` answer.
sealed class TicketLookupOutcome {
  const TicketLookupOutcome();
}

/// The desk answered. An unknown code is this too, with no ticket.
final class TicketFound extends TicketLookupOutcome {
  final LookupResult result;

  /// The desk's own words, when it gave any (used for a reason this app does
  /// not word itself).
  final String? message;

  const TicketFound(this.result, {this.message});
}

/// The lookup did not go through: refused, or the link dropped.
final class TicketLookupFailed extends TicketLookupOutcome {
  final String message;
  final String? code;

  const TicketLookupFailed(this.message, {this.code});
}

// ─── ticket:issue ───────────────────────────────────────────────────────────

/// One ticket type and how many of it, in a sale.
class TicketIssueLine {
  const TicketIssueLine({required this.ticketTypeId, required this.qty});

  final String ticketTypeId;
  final int qty;

  Map<String, dynamic> toWire() =>
      <String, dynamic>{'ticket_type_id': ticketTypeId, 'qty': qty};
}

/// One ticket sale, exactly as it goes to the desk:
///
/// ```json
/// {"lines": [{"ticket_type_id": "…", "qty": 2}],
///  "guest_name": "…", "guest_phone": "…",
///  "payments": [{"payment_mode": "cash", "amount": 1000},
///               {"payment_mode": "upi", "reference_number": "…"}],
///  "expected_total": 4000, "client_request_id": "req_…"}
/// ```
///
/// The last payment may leave `amount` out: it takes whatever is left.
/// `expected_total` is what the usher was shown (each type's `unit_total`
/// times its count); the desk refuses with `price_changed` when its own
/// total differs. See test/fixtures/crew-qsr/ticket_issue_request.json.
///
/// [clientRequestId] belongs to this attempt: an unanswered one is retried
/// as this same request. A new attempt (the usher accepted the desk's new
/// total) is a new request with a new id.
class TicketIssueRequest {
  TicketIssueRequest({
    required this.lines,
    required this.payments,
    required this.expectedTotal,
    this.guestName,
    this.guestPhone,
    String? clientRequestId,
  }) : clientRequestId = clientRequestId ?? newRequestId();

  final List<TicketIssueLine> lines;

  /// Never a cover line: cover cannot pay for tickets.
  final List<TenderLine> payments;
  final Money expectedTotal;
  final String? guestName;

  /// Digits only.
  final String? guestPhone;
  final String clientRequestId;

  /// Tickets (slips) this sale makes.
  int get units => lines.fold<int>(0, (sum, line) => sum + line.qty);

  /// The same sale at the desk's [total], which the usher accepted: a new
  /// attempt, so a new id.
  TicketIssueRequest withExpectedTotal(Money total) => TicketIssueRequest(
        lines: lines,
        payments: payments,
        expectedTotal: total,
        guestName: guestName,
        guestPhone: guestPhone,
      );

  Map<String, dynamic> toPayload() {
    final name = guestName?.trim();
    final phone = guestPhone?.trim();
    return <String, dynamic>{
      'lines': <Map<String, dynamic>>[for (final l in lines) l.toWire()],
      if (name != null && name.isNotEmpty) 'guest_name': name,
      if (phone != null && phone.isNotEmpty) 'guest_phone': phone,
      'payments': <Map<String, dynamic>>[
        for (final p in payments) ticketTenderWire(p),
      ],
      'expected_total': expectedTotal.toWire(),
      'client_request_id': clientRequestId,
    };
  }
}

/// A ticket tender as `ticket:issue` takes it: the `bill:payment` keys a
/// ticket sale has any use for, and nothing else.
Map<String, dynamic> ticketTenderWire(TenderLine line) {
  final reference = line.reference?.trim();
  final reason = line.reason?.trim();
  return <String, dynamic>{
    'payment_mode': line.mode,
    if (line.amount != null) 'amount': line.amount!.toWire(),
    if (reference != null && reference.isNotEmpty)
      'reference_number': reference,
    if (reason != null && reason.isNotEmpty) 'mode_reason': reason,
  };
}

/// How a ticket sale ended.
sealed class TicketIssueOutcome {
  const TicketIssueOutcome();
}

/// Sold: the sale and one ticket per unit, and they add up.
final class TicketIssueOk extends TicketIssueOutcome {
  const TicketIssueOk(this.result);
  final TicketIssueResult result;
}

/// The desk said no: nothing was sold or charged.
final class TicketIssueRejected extends TicketIssueOutcome {
  const TicketIssueRejected({
    required this.code,
    required this.message,
    this.newTotal,
  });

  /// The lower-cased §2.10 code (`price_changed`, `payment_short`, …).
  final String? code;

  /// What to tell the usher.
  final String message;

  /// For `price_changed`: the desk's total, when it said.
  final Money? newTotal;

  bool get priceChanged => code == 'price_changed';

  /// A business refusal: the desk priced the sale, or checked a ticket type,
  /// a tender or the sale's size, and said no before writing anything. Only
  /// these prove an attempt never went through. Anything else (the PIN, a
  /// permission, an error with no code) might follow a write that did
  /// happen, so an attempt it answers is kept, not dropped.
  bool get isBusinessRefusal {
    final c = code;
    if (c == null) return false;
    return _businessRefusals.contains(c) ||
        c.startsWith('payment_') ||
        c.startsWith('cover_') ||
        c.startsWith('ticket_');
  }

  /// The PIN lapsed and was not entered again.
  bool get needsPin => code == 'reauth_required';
}

const Set<String> _businessRefusals = <String>{
  'price_changed',
  'type_unavailable',
  'limit_exceeded',
};

/// No answer: it may have gone through. Retry the SAME request; never edit
/// it, never start a new one, until the desk has answered.
final class TicketIssueUnconfirmed extends TicketIssueOutcome {
  const TicketIssueUnconfirmed();
}

/// Not sent: the desk is not reachable, and money never queues.
final class TicketIssueOffline extends TicketIssueOutcome {
  const TicketIssueOffline();
}

/// The desk took the sale, but its answer cannot be shown as it came: the
/// payments do not add up to the total, or a slip is missing. Nothing on
/// this phone shows (or prints) those numbers; the sale is on the desk.
final class TicketIssueUnreadable extends TicketIssueOutcome {
  const TicketIssueUnreadable();
}

/// The usher's words for an unanswered sale.
const String kIssueNoAnswer = "The desk didn't answer — the sale may have "
    'gone through. Retry sends exactly the same sale.';

/// The usher's words for a sale the desk took but this phone cannot show.
const String kIssueUnreadable = 'The desk recorded this sale, but its answer '
    "doesn't add up on this phone, so it isn't shown. Don't sell it again: "
    'find the tickets in Recent, or on the desk.';

/// Staff words for a `ticket:issue` error code (spec §2.10, lower-cased), or
/// null for one this app does not word itself: show the desk's message then.
String? ticketIssueErrorCopy(String? code) => switch (code) {
      'price_changed' => 'Ticket prices changed on the desk — check the new '
          'total',
      'type_unavailable' => 'A ticket type is no longer on sale — check the '
          'tickets',
      'payment_short' => "The payments don't cover the tickets",
      'payment_over' => 'The payments are more than the tickets cost',
      'payment_invalid' => "The desk can't take that payment for tickets",
      'limit_exceeded' => 'Too many tickets in one sale — split it in two',
      'permission_denied' => "You can't sell entry tickets — ask the desk",
      'reauth_required' => 'Enter your PIN again, then retry',
      _ => coverErrorCopy(code),
    };

/// Null when [result] can be shown and printed as it came: its payments add
/// up to its total (within a paisa, as the desk checks them) and it carries
/// one ticket per unit sold ([units], when known). Otherwise why not, in
/// words fit for a log: no codes, numbers or guests.
String? ticketSaleProblem(TicketIssueResult result, {int? units}) {
  final paid = result.sale.payments.map((p) => p.amount).sumMoney();
  if ((paid - result.sale.totals.total).abs() > const Money(1)) {
    return 'its payments do not add up to its total';
  }
  if (units != null && result.tickets.length != units) {
    return 'it has ${result.tickets.length} ticket(s) for $units sold';
  }
  return null;
}

// ─── ticket:check_in ────────────────────────────────────────────────────────

/// How the code reached the phone.
enum CheckInMethod {
  scan('scan'),
  manual('manual');

  const CheckInMethod(this.wire);
  final String wire;
}

/// One check-in attempt: `{code, method, client_request_id}`. [code] is sent
/// trimmed and otherwise as read or typed (`CDT:…`, `ET-042`, `42`): the
/// desk normalises it.
class TicketCheckInRequest {
  TicketCheckInRequest({
    required String code,
    this.method = CheckInMethod.scan,
    String? clientRequestId,
  })  : code = code.trim(),
        clientRequestId = clientRequestId ?? newRequestId();

  final String code;
  final CheckInMethod method;
  final String clientRequestId;

  Map<String, dynamic> toPayload() => <String, dynamic>{
        'code': code,
        'method': method.wire,
        'client_request_id': clientRequestId,
      };
}

/// How a check-in ended.
sealed class TicketCheckInOutcome {
  const TicketCheckInOutcome();
}

/// The desk answered: valid, already used, expired, cancelled or not found.
final class CheckInAnswered extends TicketCheckInOutcome {
  const CheckInAnswered(this.result);
  final CheckInResult result;
}

/// The desk refused to answer (no permission, the PIN lapsed, a bad code).
final class CheckInRefused extends TicketCheckInOutcome {
  const CheckInRefused({required this.code, required this.message});
  final String? code;
  final String message;
}

/// No answer: the guest may already be checked in. Retry the SAME request,
/// so the desk replays its answer instead of reading its own check-in back
/// as "already used".
final class CheckInUnconfirmed extends TicketCheckInOutcome {
  const CheckInUnconfirmed();
}

/// Not sent: the desk is not reachable. There is no offline check-in.
final class CheckInOffline extends TicketCheckInOutcome {
  const CheckInOffline();
}

/// Staff words for a `ticket:check_in` error code, or null for one this app
/// does not word itself.
String? checkInErrorCopy(String? code) => switch (code) {
      'permission_denied' => "You can't check guests in — ask the desk",
      'reauth_required' => 'Enter your PIN again, then scan again',
      'ticket_not_found' => 'No ticket matches that code',
      'ticket_cancelled' => 'This ticket was cancelled',
      _ => null,
    };

// ─── ticket:recent ──────────────────────────────────────────────────────────

/// A `ticket:recent` answer.
sealed class RecentTicketsOutcome {
  const RecentTicketsOutcome();
}

final class RecentTicketsLoaded extends RecentTicketsOutcome {
  const RecentTicketsLoaded(this.recent);
  final RecentTickets recent;
}

final class RecentTicketsFailed extends RecentTicketsOutcome {
  const RecentTicketsFailed(this.message, {this.code});
  final String message;
  final String? code;
}

/// How many of today's tickets the Recent list asks for.
const int kRecentTicketsLimit = 100;

class EntryTicketService {
  EntryTicketService(this._socket, {ReauthPrompt? reauth}) : _reauth = reauth;

  final SocketService _socket;
  final ReauthPrompt? _reauth;

  bool get _deskReachable => _socket.state == SocketState.verified;

  /// Asks for the PIN when [ack] says the desk wants it; true once entered.
  Future<bool> _reauthenticated(Map<String, dynamic> ack) async {
    final prompt = _reauth;
    if (prompt == null || !isReauthRequired(ack)) return false;
    try {
      return await prompt();
    } catch (error) {
      logE(_tag, 'PIN prompt failed', error.runtimeType);
      return false;
    }
  }

  /// Sends a money event, and once more after a PIN prompt when the desk
  /// asked for one: the SAME payload, so the same id.
  Future<Map<String, dynamic>> _emitMoney(
      String event, Map<String, dynamic> payload) async {
    final ack =
        await _socket.emitAck(event, payload, timeout: kTicketMoneyTimeout);
    if (!await _reauthenticated(ack)) return ack;
    logD(_tag, '$event: PIN entered again, resending the same request');
    return _socket.emitAck(event, payload, timeout: kTicketMoneyTimeout);
  }

  /// Sells [request] once (plus one resend after a PIN prompt). Never throws.
  Future<TicketIssueOutcome> issue(TicketIssueRequest request) async {
    final modes = <String>{for (final p in request.payments) p.mode};
    if (!_deskReachable) {
      logD(_tag, 'issue not sent: the desk is not reachable');
      return const TicketIssueOffline();
    }
    logD(
        _tag,
        'issue: ${request.units} ticket(s), '
        'modes ${modes.isEmpty ? 'none' : modes.join('/')}');
    final ack = await _emitMoney('ticket:issue', request.toPayload());
    if (ack['kind'] == 'success') {
      final TicketIssueResult result;
      try {
        result = TicketIssueResult.fromAck(ack);
      } on WireFormatException catch (e) {
        logE(_tag, 'issue ok but the answer is unreadable', e.field);
        return const TicketIssueUnreadable();
      }
      final problem = ticketSaleProblem(result, units: request.units);
      if (problem != null) {
        logE(_tag, 'issue ok but not shown: $problem');
        return const TicketIssueUnreadable();
      }
      logD(_tag, 'issue ok: ${result.tickets.length} ticket(s)');
      return TicketIssueOk(result);
    }
    final code = optionalString(ack, 'code');
    if (isTransportFailure(ack) || code == AckCode.badResponse) {
      logD(_tag, 'issue got no answer (${code ?? 'no code'})');
      return const TicketIssueUnconfirmed();
    }
    logD(_tag, 'issue refused: ${code ?? 'no code'}');
    return TicketIssueRejected(
      code: code,
      message: ticketIssueErrorCopy(code) ??
          optionalString(ack, 'message') ??
          "The desk couldn't issue these tickets",
      newTotal: code == 'price_changed' ? priceChangedTotal(ack) : null,
    );
  }

  /// Checks [request]'s ticket in (plus one resend after a PIN prompt).
  /// Never throws.
  Future<TicketCheckInOutcome> checkIn(TicketCheckInRequest request) async {
    if (!_deskReachable) {
      logD(_tag, 'check-in not sent: the desk is not reachable');
      return const CheckInOffline();
    }
    logD(_tag, 'check-in (${request.method.wire})');
    final ack = await _emitMoney('ticket:check_in', request.toPayload());
    if (ack['kind'] == 'success') {
      final result = CheckInResult.fromAck(ack);
      logD(_tag, 'check-in: ${result.outcome.name}');
      return CheckInAnswered(result);
    }
    final code = optionalString(ack, 'code');
    if (isTransportFailure(ack) || code == AckCode.badResponse) {
      logD(_tag, 'check-in got no answer (${code ?? 'no code'})');
      return const CheckInUnconfirmed();
    }
    logD(_tag, 'check-in refused: ${code ?? 'no code'}');
    return CheckInRefused(
      code: code,
      message: checkInErrorCopy(code) ??
          optionalString(ack, 'message') ??
          "The desk couldn't check this ticket",
    );
  }

  /// Today's tickets, newest first, optionally matching [query] (a ticket
  /// number, a guest's name or their phone's last digits). Read-only.
  Future<RecentTicketsOutcome> recent({
    String? query,
    int limit = kRecentTicketsLimit,
  }) async {
    var q = query?.trim() ?? '';
    if (q.length > 40) q = q.substring(0, 40);
    final ack = await _socket.emitAck('ticket:recent', <String, dynamic>{
      if (q.isNotEmpty) 'q': q,
      'limit': limit.clamp(1, 100),
    });
    if (ack['kind'] == 'success') {
      final recent = RecentTickets.fromAck(ack);
      logD(_tag, 'recent: ${recent.tickets.length} row(s)');
      return RecentTicketsLoaded(recent);
    }
    final code = optionalString(ack, 'code');
    logD(_tag, 'recent failed: ${code ?? 'no code'}');
    if (isTransportFailure(ack)) {
      return RecentTicketsFailed("Couldn't reach the desk — try again",
          code: code);
    }
    return RecentTicketsFailed(
      code == 'permission_denied'
          ? "You can't see the gate's tickets — ask the desk"
          : optionalString(ack, 'message') ?? "Couldn't load today's tickets",
      code: code,
    );
  }

  /// Asks the desk about [code]: a scanned QR or a typed ticket number, sent
  /// trimmed (the desk reads `CDT:…`, `ET-042`, `et-42` and `42` alike).
  Future<TicketLookupOutcome> lookup(
    String code, {
    TicketLookupPurpose purpose = TicketLookupPurpose.redeem,
  }) async {
    final ack = await _socket.emitAck('ticket:lookup', <String, dynamic>{
      'code': code.trim(),
      'purpose': purpose.wire,
    });
    if (ack['kind'] == 'success') {
      final result = LookupResult.fromAck(ack);
      logD(
          _tag,
          'lookup ${purpose.wire}: '
          '${result.canRedeem ? 'can pay' : 'cannot pay (${result.reason?.name})'}');
      return TicketFound(result, message: optionalString(ack, 'message'));
    }
    final errorCode = optionalString(ack, 'code');
    logD(_tag, 'lookup ${purpose.wire} failed: ${errorCode ?? 'no code'}');
    if (isTransportFailure(ack)) {
      return TicketLookupFailed("Couldn't reach the desk — try again",
          code: errorCode);
    }
    return TicketLookupFailed(
      coverErrorCopy(errorCode) ??
          optionalString(ack, 'message') ??
          "Couldn't look the ticket up",
      code: errorCode,
    );
  }
}

// Staff words shared by a refused cover payment and a ticket lookup.
const String _noSuchTicket = 'No ticket matches that code';
const String _ticketCancelled = 'This ticket was cancelled';
const String _earlierDay = 'This ticket was for an earlier day';
const String _coverUsedUp = "This ticket's cover is used up";

/// Staff words for a desk error code on a cover payment or a ticket lookup
/// (spec §2.10's prefixes, lower-cased), or null for a code this app does not
/// word itself: show the desk's message then.
String? coverErrorCopy(String? code) => switch (code) {
      'cover_invalid' => "This ticket can't be used as cover",
      'cover_expired' => _earlierDay,
      'cover_empty' => _coverUsedUp,
      'cover_not_applicable' => "Cover can't pay a room, comp or credit bill",
      'ticket_not_found' => _noSuchTicket,
      'ticket_cancelled' => _ticketCancelled,
      'payment_invalid' => "The desk couldn't take these payments",
      'payment_short' => "The payments don't cover the bill",
      'payment_over' => 'The payments are more than the bill',
      _ => null,
    };

/// Why a looked-up ticket cannot pay a bill, in staff words. A reason this
/// app does not know shows the desk's [deskMessage].
String lookupRefusalCopy(LookupReason? reason, {String? deskMessage}) =>
    switch (reason) {
      LookupReason.notFound => _noSuchTicket,
      LookupReason.cancelled => _ticketCancelled,
      LookupReason.expired => _earlierDay,
      LookupReason.noCover => 'This ticket has no cover to spend',
      LookupReason.usedUp => _coverUsedUp,
      LookupReason.other ||
      null =>
        deskMessage ?? "This ticket can't pay a bill",
    };

/// What adding a looked-up ticket to a payment comes to.
sealed class CoverDecision {
  const CoverDecision();
}

final class CoverAccepted extends CoverDecision {
  final AppliedCover cover;
  const CoverAccepted(this.cover);
}

final class CoverRefused extends CoverDecision {
  final String message;
  const CoverRefused(this.message);
}

/// Adds the ticket in [lookup] (typed or scanned as [entered]) to a payment
/// that already has [existing] covers and where cover may still pay
/// [coverable]. It takes the smaller of its balance and [coverable]; the
/// same ticket is never added twice, however it was typed.
CoverDecision decideCover({
  required LookupResult lookup,
  required String entered,
  required List<AppliedCover> existing,
  required Money coverable,
  String? deskMessage,
}) {
  if (!lookup.canRedeem) {
    return CoverRefused(
        lookupRefusalCopy(lookup.reason, deskMessage: deskMessage));
  }
  final ticket = lookup.ticket;
  final typed = entered.trim();
  final key = ticket?.id ?? typed.toUpperCase();
  if (existing.any((c) => c.key == key)) {
    return const CoverRefused('This ticket is already on this payment');
  }
  final balance = lookup.coverBalance;
  if (!balance.isPositive) {
    return CoverRefused(lookupRefusalCopy(LookupReason.usedUp));
  }
  final amount = balance < coverable ? balance : coverable;
  if (!amount.isPositive) {
    return const CoverRefused('Nothing left here that cover can pay');
  }
  final qr = ticket?.qrCode ?? '';
  return CoverAccepted(AppliedCover(
    key: key,
    code: qr.isNotEmpty ? qr : typed,
    ticketNumber: ticket?.ticketNumber ?? typed,
    typeName: ticket?.typeName ?? 'Ticket',
    balance: balance,
    amount: amount,
  ));
}
