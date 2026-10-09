/// The gate scanner's state machine: what the camera (or a typed number)
/// sends to the desk, and what the usher sees afterwards.
///
/// - **Local filter.** A scanned code that is not a ticket QR (`CDT:` + 16
///   base32 characters, [TicketConfig.matchesQr]) never reaches the desk.
/// - **Per-code cooldown.** A code acted on stays quiet while it is held in
///   view, and for [GateScanController.cooldown] after it was last seen, so
///   a guest who keeps the QR up after a green card does not then get a red
///   "already used" one.
/// - **One request in flight.** Nothing else is read while the desk is
///   answering, nor while a result card is up.
/// - **Unconfirmed.** A check-in the desk never answered is kept, with its
///   id, and the scanner stays locked until it is retried (the same request,
///   so the desk replays its answer) or dropped on purpose.
/// - **Offline.** No check-in without the desk: scanning pauses.
///
/// Tones: `valid` green, `already_used` red, everything else amber.
/// The words are built here; the desk's acks carry none.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ist_time.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import '../services/entry_ticket_service.dart';

/// The colour (and haptic) of a gate answer.
enum GateTone { green, red, amber }

/// `valid` green, `already_used` red, everything else (expired, cancelled,
/// not found, a word this app does not know) amber.
GateTone toneForOutcome(CheckInOutcome outcome) => switch (outcome) {
      CheckInOutcome.valid => GateTone.green,
      CheckInOutcome.alreadyUsed => GateTone.red,
      _ => GateTone.amber,
    };

/// The haptic for [tone].
FeedbackKind feedbackForTone(GateTone tone) => switch (tone) {
      GateTone.green => const FeedbackSuccess(),
      GateTone.red => const FeedbackError(),
      GateTone.amber => const FeedbackWarning(),
    };

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `2026-10-08` as `8 Oct`; null when unreadable.
String? dayMonthOf(String? isoDate) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(isoDate ?? '');
  if (match == null) return null;
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1) return null;
  return '$day ${_months[month - 1]}';
}

/// The big line of a check-in answer:
///
/// - `Valid entry – 2 pax`
/// - `Already used at 08:15 PM by Asha`
/// - `Expired – issued 8 Oct`
/// - `Cancelled`, `Not found`
String checkInHeadline(CheckInResult result) {
  switch (result.outcome) {
    case CheckInOutcome.valid:
      final pax = result.ticket?.pax;
      return pax == null ? 'Valid entry' : 'Valid entry – $pax pax';
    case CheckInOutcome.alreadyUsed:
      final at = result.checkedInAt;
      final by = result.checkedInByName?.trim();
      final when = at == null ? '' : ' at ${formatIstClock12(at)}';
      final who = by == null || by.isEmpty ? '' : ' by $by';
      return 'Already used$when$who';
    case CheckInOutcome.expired:
      final issued = dayMonthOf(result.ticket?.validDate);
      return issued == null ? 'Expired' : 'Expired – issued $issued';
    case CheckInOutcome.cancelled:
      return 'Cancelled';
    case CheckInOutcome.notFound:
      return 'Not found';
    case CheckInOutcome.unknown:
      return 'Not admitted — check with the desk';
  }
}

/// What a result card is about.
enum GateCardKind {
  /// The desk's answer to a check-in.
  answer,

  /// A QR that is not an entry ticket; the desk was not asked.
  notTicket,

  /// The desk refused to answer (no permission, the PIN, …).
  refused,

  /// No answer came: held for a retry.
  unconfirmed,
}

class GateScanCard {
  const GateScanCard({
    required this.kind,
    required this.tone,
    required this.headline,
    this.result,
    this.detail,
  });

  final GateCardKind kind;
  final GateTone tone;
  final String headline;

  /// For [GateCardKind.answer].
  final CheckInResult? result;

  /// A second line, when there is one.
  final String? detail;
}

/// A check-in the desk never answered, waiting for Retry or Drop.
const GateScanCard kUnconfirmedCheckInCard = GateScanCard(
  kind: GateCardKind.unconfirmed,
  tone: GateTone.amber,
  headline: 'No answer from the desk',
  detail: 'The guest may already be checked in. Retry asks the desk again '
      'without checking them in twice.',
);

class GateScanState {
  const GateScanState({
    this.online = true,
    this.inFlight = false,
    this.card,
    this.pending,
  });

  /// The desk is reachable. Scanning pauses without it.
  final bool online;

  /// A check-in is with the desk.
  final bool inFlight;

  /// The answer on screen; scanning waits while it is up.
  final GateScanCard? card;

  /// A check-in the desk never answered, kept with its id for the retry.
  final TicketCheckInRequest? pending;

  /// The camera's reads are acted on.
  bool get acceptsScans =>
      online && !inFlight && card == null && pending == null;

  /// What the screen shows: the card up, else the unanswered check-in's.
  GateScanCard? get shownCard =>
      card ?? (pending != null ? kUnconfirmedCheckInCard : null);

  GateScanState copyWith({
    bool? online,
    bool? inFlight,
    Object? card = _keep,
    Object? pending = _keep,
  }) =>
      GateScanState(
        online: online ?? this.online,
        inFlight: inFlight ?? this.inFlight,
        card: identical(card, _keep) ? this.card : card as GateScanCard?,
        pending: identical(pending, _keep)
            ? this.pending
            : pending as TicketCheckInRequest?,
      );

  static const Object _keep = Object();
}

typedef CheckInSender = Future<TicketCheckInOutcome> Function(
    TicketCheckInRequest request);

class GateScanController extends StateNotifier<GateScanState> {
  GateScanController({
    required CheckInSender checkIn,
    required TicketConfig Function() config,
    void Function(GateTone tone)? onTone,
    DateTime Function()? now,
    bool online = true,
  })  : _checkIn = checkIn,
        _config = config,
        _onTone = onTone,
        _now = now ?? DateTime.now,
        super(GateScanState(online: online));

  /// How long a code acted on stays quiet after it was last seen.
  static const Duration cooldown = Duration(seconds: 4);

  /// A green card clears itself this soon, ready for the next guest.
  static const Duration validCardFor = Duration(milliseconds: 1800);

  /// A red or amber card stays this long, unless tapped away.
  static const Duration stickyCardFor = Duration(seconds: 8);

  final CheckInSender _checkIn;
  final TicketConfig Function() _config;
  final void Function(GateTone tone)? _onTone;
  final DateTime Function() _now;

  /// Codes acted on, and when each was last seen.
  final Map<String, DateTime> _seen = <String, DateTime>{};
  Timer? _dismiss;

  /// A code the camera read.
  void onDetected(String raw) {
    final code = raw.trim();
    if (code.isEmpty) return;
    final now = _now();
    _seen.removeWhere((_, at) => now.difference(at) >= cooldown);
    if (_seen.containsKey(code)) {
      // Still in view: stays quiet until it has been away a while.
      _seen[code] = now;
      return;
    }
    // Not remembered: a code read while the gate is busy fires once it is
    // free, for the next guest in line.
    if (!state.acceptsScans) return;
    _seen[code] = now;
    if (!_config().matchesQr(code)) {
      _show(const GateScanCard(
        kind: GateCardKind.notTicket,
        tone: GateTone.amber,
        headline: 'Not an entry ticket',
        detail: 'This QR is not one of our tickets',
      ));
      return;
    }
    unawaited(_send(TicketCheckInRequest(code: code)));
  }

  /// A ticket number or code the usher typed (`ET-042`, `42`, a QR's text):
  /// sent trimmed, as typed; the desk reads it. False when it cannot go now.
  bool submitManual(String typed) {
    final code = typed.trim();
    if (code.isEmpty || !state.online || state.inFlight) return false;
    if (state.pending != null) return false;
    unawaited(_send(TicketCheckInRequest(
      code: code,
      method: CheckInMethod.manual,
    )));
    return true;
  }

  /// Sends the unanswered check-in again, exactly as it went.
  Future<void> retryPending() async {
    final pending = state.pending;
    if (pending == null || state.inFlight || !state.online) return;
    await _send(pending);
  }

  /// Drops the unanswered check-in (the screen has asked first). The guest
  /// may or may not be in; the desk knows.
  void abandonPending() {
    if (state.pending == null || state.inFlight) return;
    _dismiss?.cancel();
    state = state.copyWith(pending: null, card: null);
  }

  /// Taps the card away. An unanswered check-in cannot be tapped away: it is
  /// retried or dropped.
  void dismissCard() {
    if (state.card == null || state.pending != null) return;
    _dismiss?.cancel();
    state = state.copyWith(card: null);
  }

  void setOnline(bool online) {
    if (state.online == online) return;
    state = state.copyWith(online: online);
  }

  Future<void> _send(TicketCheckInRequest request) async {
    _dismiss?.cancel();
    state = state.copyWith(inFlight: true, card: null);
    final outcome = await _checkIn(request);
    if (!mounted) return;
    state = state.copyWith(inFlight: false);
    switch (outcome) {
      case CheckInAnswered(:final result):
        state = state.copyWith(pending: null);
        _show(GateScanCard(
          kind: GateCardKind.answer,
          tone: toneForOutcome(result.outcome),
          headline: checkInHeadline(result),
          result: result,
        ));
      case CheckInRefused(:final code, :final message):
        // The desk did not act on it: shown again, it goes again.
        _seen.remove(request.code);
        // A PIN that was not entered again says nothing about a kept try.
        if (code != 'reauth_required') state = state.copyWith(pending: null);
        _show(GateScanCard(
          kind: GateCardKind.refused,
          tone: GateTone.amber,
          headline: 'Not checked',
          detail: message,
        ));
      case CheckInUnconfirmed():
        state = state.copyWith(pending: request);
        _show(kUnconfirmedCheckInCard);
      case CheckInOffline():
        _seen.remove(request.code);
        _show(const GateScanCard(
          kind: GateCardKind.refused,
          tone: GateTone.amber,
          headline: 'Desk unreachable',
          detail: "Can't verify entries until the desk is back",
        ));
    }
  }

  void _show(GateScanCard card) {
    _dismiss?.cancel();
    state = state.copyWith(card: card);
    _onTone?.call(card.tone);
    if (card.kind == GateCardKind.unconfirmed) return;
    final hold = card.kind == GateCardKind.answer && card.tone == GateTone.green
        ? validCardFor
        : stickyCardFor;
    _dismiss = Timer(hold, () {
      if (mounted && identical(state.card, card)) {
        state = state.copyWith(card: null);
      }
    });
  }

  @override
  void dispose() {
    _dismiss?.cancel();
    super.dispose();
  }
}

/// The scan screen's controller: the desk's answers through
/// [EntryTicketService], the QR rules from the desk's ticket config, and a
/// haptic per tone.
final gateScanControllerProvider =
    StateNotifierProvider.autoDispose<GateScanController, GateScanState>(
        (ref) {
  final service = ref.read(entryTicketServiceProvider);
  final feedback = ref.read(feedbackServiceProvider);
  return GateScanController(
    checkIn: service.checkIn,
    config: () => ref.read(ticketConfigProvider),
    onTone: (tone) => feedback.fire(feedbackForTone(tone)),
  );
});
