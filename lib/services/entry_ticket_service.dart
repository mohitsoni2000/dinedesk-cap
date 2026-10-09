import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/money.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../models/wire.dart';
import '../utils/tender_allocation.dart';
import 'log.dart';
import 'socket_service.dart';

/// Entry tickets on the desk: for now, looking one up to take its cover as
/// payment. The desk is the only authority on a ticket (its balance, its day,
/// whether it was cancelled), so every answer comes from it.
///
/// Logs carry outcomes and counts only: never a ticket code, number or guest.
final Provider<EntryTicketService> entryTicketServiceProvider =
    Provider<EntryTicketService>(
        (ref) => EntryTicketService(ref.read(socketServiceProvider)));

const String _tag = '[Tickets]';

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

class EntryTicketService {
  EntryTicketService(this._socket);

  final SocketService _socket;

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
