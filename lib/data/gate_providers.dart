/// The gate's state on the phone: the ticket sale being put together, a sale
/// still waiting for the desk's answer, and the sale just made (for the
/// result screen).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry_ticket.dart';
import '../models/parked_draft.dart';
import '../models/pay_mode.dart';
import '../services/entry_ticket_service.dart';
import '../services/parked_cart_resolver.dart';
import '../services/slip_printer.dart';
import 'money.dart';

/// Most tickets one sale may carry (the desk refuses more).
const int kMaxTicketsPerSale = 50;

/// The sale on the issue screen: how many of each ticket type, and the
/// guest if the usher takes one down.
class TicketIssueForm {
  const TicketIssueForm({
    this.quantities = const <String, int>{},
    this.guestName = '',
    this.guestPhone = '',
  });

  /// Ticket type id to how many; only counts above zero.
  final Map<String, int> quantities;
  final String guestName;
  final String guestPhone;

  bool get hasTickets => quantities.isNotEmpty;

  /// Every ticket counted, on sale or not.
  int get units => quantities.values.fold<int>(0, (sum, n) => sum + n);

  int qtyOf(String typeId) => quantities[typeId] ?? 0;

  /// The counted types still on sale ([types], in their order). A type the
  /// desk has since taken off sale is left out.
  List<({TicketType type, int qty})> linesOn(List<TicketType> types) =>
      <({TicketType type, int qty})>[
        for (final type in types)
          if (qtyOf(type.id) > 0) (type: type, qty: qtyOf(type.id)),
      ];

  /// What the sale comes to: each type's `unit_total` times its count.
  Money totalOn(List<TicketType> types) => linesOn(types)
      .map((line) => line.type.unitTotal.times(line.qty))
      .sumMoney();

  /// Tickets counted of types no longer on sale.
  int missingOn(List<TicketType> types) {
    final onSale = <String>{for (final t in types) t.id};
    var missing = 0;
    quantities.forEach((id, n) {
      if (!onSale.contains(id)) missing += n;
    });
    return missing;
  }

  TicketIssueForm copyWith({
    Map<String, int>? quantities,
    String? guestName,
    String? guestPhone,
  }) =>
      TicketIssueForm(
        quantities: quantities ?? this.quantities,
        guestName: guestName ?? this.guestName,
        guestPhone: guestPhone ?? this.guestPhone,
      );
}

/// The guest's phone as the desk takes it: digits only.
String guestPhoneDigits(String raw) => raw.replaceAll(RegExp(r'\D'), '');

/// Blank, or 6 to 20 digits.
bool isGuestPhoneValid(String raw) {
  final digits = guestPhoneDigits(raw);
  return digits.isEmpty || (digits.length >= 6 && digits.length <= 20);
}

/// "2× Couple Pass, 1× Stag Entry".
String ticketLinesSummary(List<({TicketType type, int qty})> lines) =>
    lines.map((l) => '${l.qty}× ${l.type.name}').join(', ');

final ticketIssueFormProvider =
    StateNotifierProvider<TicketIssueFormNotifier, TicketIssueForm>(
        (_) => TicketIssueFormNotifier());

class TicketIssueFormNotifier extends StateNotifier<TicketIssueForm> {
  TicketIssueFormNotifier() : super(const TicketIssueForm());

  /// Sets [typeId]'s count, kept within 0 and what the sale still has room
  /// for.
  void setQty(String typeId, int qty) {
    final others = state.units - state.qtyOf(typeId);
    final room = kMaxTicketsPerSale - others;
    final next = qty.clamp(0, room < 0 ? 0 : room);
    final quantities = Map<String, int>.of(state.quantities);
    if (next == 0) {
      quantities.remove(typeId);
    } else {
      quantities[typeId] = next;
    }
    state = state.copyWith(quantities: quantities);
  }

  void add(String typeId) => setQty(typeId, state.qtyOf(typeId) + 1);

  void remove(String typeId) => setQty(typeId, state.qtyOf(typeId) - 1);

  void setGuestName(String value) =>
      state = state.copyWith(guestName: value);

  void setGuestPhone(String value) =>
      state = state.copyWith(guestPhone: value);

  void clear() => state = const TicketIssueForm();

  /// A resumed parked sale becomes the form.
  void load(ResolvedTicketDraft draft) {
    final quantities = <String, int>{};
    var units = 0;
    for (final line in draft.lines) {
      final room = kMaxTicketsPerSale - units;
      final qty = line.qty.clamp(0, room);
      if (qty <= 0) continue;
      quantities[line.type.id] = (quantities[line.type.id] ?? 0) + qty;
      units += qty;
    }
    state = TicketIssueForm(
      quantities: quantities,
      guestName: draft.guestName ?? '',
      guestPhone: draft.guestPhone ?? '',
    );
  }
}

/// [form] as a parked sale, of the types still on sale.
TicketIssueDraft ticketDraftOf(TicketIssueForm form, List<TicketType> types) =>
    TicketIssueDraft(
      lines: <ParkedTicketLine>[
        for (final line in form.linesOn(types))
          ParkedTicketLine.of(line.type, line.qty),
      ],
      guestName: form.guestName,
      guestPhone: form.guestPhone,
    );

/// The ways a ticket can be paid for: cash, UPI, card and the desk's own
/// revenue modes, from the payment sheet's [catalog]. Never comp, credit or
/// company (a ticket is sold, not given away or put on account), never a
/// non-revenue mode, and never cover.
List<PayMode> ticketPayModes(List<PayMode> catalog, {String? coverMode}) =>
    <PayMode>[
      for (final mode in catalog)
        if (mode.code != PayMode.complimentary.code &&
            mode.code != PayMode.credit.code &&
            mode.code != PayMode.company.code &&
            mode.isRevenue &&
            mode.code != coverMode)
          mode,
    ];

/// A sale the desk never answered. It may have gone through, so it is kept:
/// the only ways on are to retry it exactly (same request, same id, so the
/// desk replays rather than sells twice) or to drop it on purpose.
class PendingTicketIssue {
  const PendingTicketIssue({
    required this.request,
    required this.summary,
    required this.form,
  });

  final TicketIssueRequest request;

  /// "2× Couple Pass", for the card.
  final String summary;

  /// The form as it was sent. A confirmed retry clears the form only if it
  /// is still this one.
  final TicketIssueForm form;
}

final pendingTicketIssueProvider =
    StateProvider<PendingTicketIssue?>((_) => null);

/// The sale the result screen shows; null when there is none.
final ticketIssueResultProvider =
    StateProvider<TicketIssueResult?>((_) => null);

/// Applies a sale the desk confirmed: the result screen's subject, the form
/// cleared if it is still [sentForm], nothing pending, and its slips handed
/// to the slip printer (printed now when auto-print is on). Works off
/// [container] so a screen that went away meanwhile cannot drop a sale the
/// desk made.
void applyTicketSale(
  ProviderContainer container,
  TicketIssueResult result, {
  required TicketIssueForm sentForm,
}) {
  container.read(ticketIssueResultProvider.notifier).state = result;
  clearTicketFormIfUnchanged(container, sentForm);
  container.read(pendingTicketIssueProvider.notifier).state = null;
  // Slips only for numbers the result screen will show.
  if (ticketSaleProblem(result) != null) return;
  unawaited(container.read(slipPrinterProvider).afterSale(<TicketSlip>[
    for (final ticket in result.tickets) TicketSlip.fromTicket(ticket),
  ]));
}

/// Empties the issue form, unless it changed since [was] was sent.
void clearTicketFormIfUnchanged(
    ProviderContainer container, TicketIssueForm was) {
  if (identical(container.read(ticketIssueFormProvider), was)) {
    container.read(ticketIssueFormProvider.notifier).clear();
  }
}

/// Sends the kept sale again, exactly as it went (same request, same id): if
/// the first one landed, the desk replays it instead of selling twice.
///
/// Only a business refusal proves it never went through, so only that drops
/// the attempt. Any other refusal (the PIN, a permission, an error with no
/// code) keeps it, as unanswered.
Future<TicketIssueOutcome> retryPendingIssue(
    ProviderContainer container, PendingTicketIssue pending) async {
  final outcome =
      await container.read(entryTicketServiceProvider).issue(pending.request);
  switch (outcome) {
    case TicketIssueOk(:final result):
      applyTicketSale(container, result, sentForm: pending.form);
    case TicketIssueUnreadable():
      // The desk has the sale; this phone only cannot show it.
      clearTicketFormIfUnchanged(container, pending.form);
      container.read(pendingTicketIssueProvider.notifier).state = null;
    case TicketIssueRejected(isBusinessRefusal: true):
      container.read(pendingTicketIssueProvider.notifier).state = null;
    case TicketIssueRejected() ||
          TicketIssueUnconfirmed() ||
          TicketIssueOffline():
      break;
  }
  return outcome;
}

/// What the usher is told when a retried sale is refused: "nothing was
/// charged" only when the refusal proves it.
String retryIssueRefusalCopy(TicketIssueRejected refused) {
  if (refused.isBusinessRefusal) {
    return '${refused.message}. Nothing was charged.';
  }
  if (refused.needsPin) return refused.message;
  return kIssueNoAnswer;
}
